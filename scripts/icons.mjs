// Regenerates what the type icons ship from one pin: the Lucide name list at marfa's pinned commit, and the SVG
// of every name that Sources/MarfaIcons/LucideSymbols.swift gives no SF Symbol, taken from the `lucide-static`
// release the list names.
//
//   scripts/icons.mjs                                  # reads .build/marfa, the checkout scripts/core.sh makes
//   MARFA_MONOREPO=<checkout> scripts/icons.mjs        # a clean checkout already at the pin
//
// Writes Sources/MarfaIcons/LucidePinned.swift and Sources/MarfaIcons/Lucide.xcassets, and removes any image
// the table now covers.
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = process.env.MARFA_MONOREPO ?? join(root, ".build/marfa");
const listPath = join(source, "packages/types/generated/lucide-icons.json");
if (!existsSync(listPath)) {
  console.error(`icons.mjs: ${listPath} does not exist; run scripts/core.sh first, or set MARFA_MONOREPO`);
  process.exit(1);
}
const { lucide_version: version, icons: names } = JSON.parse(readFileSync(listPath, "utf8"));
if (!/^\d+\.\d+\.\d+$/.test(version) || !Array.isArray(names) || names.length === 0) {
  console.error("icons.mjs: the name list has no exact version or no names");
  process.exit(1);
}

const table = readFileSync(join(root, "Sources/MarfaIcons/LucideSymbols.swift"), "utf8");
const mapped = new Map([...table.matchAll(/^\s*"([a-z0-9-]+)": "([a-z0-9.]+)",$/gm)].map((m) => [m[1], m[2]]));
const known = new Set(names);
const strays = [...mapped.keys()].filter((name) => !known.has(name));
if (strays.length > 0) {
  console.error(`icons.mjs: the table names icons Lucide ${version} does not have: ${strays.join(", ")}`);
  process.exit(1);
}
const drawn = names.filter((name) => !mapped.has(name));

// SVG lets an arc's two flags run into the number after them ("a2 2 0 0020 0"), and Lucide's minifier does. Core
// SVG, which draws an asset catalog's SVG, reads that wrong, so every arc is written with its parameters spaced.
const separator = /^[\s,]*/;
const numeral = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/;
const flag = /^[01]/;
function spaceArcs(d) {
  let out = "";
  let at = 0;
  while (at < d.length) {
    const command = d[at];
    out += command;
    at += 1;
    if (command !== "a" && command !== "A") continue;
    const groups = [];
    for (;;) {
      let cursor = at;
      const group = [];
      for (const pattern of [numeral, numeral, numeral, flag, flag, numeral, numeral]) {
        cursor += d.slice(cursor).match(separator)[0].length;
        const token = d.slice(cursor).match(pattern)?.[0];
        if (token === undefined) break;
        group.push(token);
        cursor += token.length;
      }
      if (group.length !== 7) break;
      groups.push(group.join(" "));
      at = cursor;
    }
    out += groups.join(" ");
  }
  return out;
}
const spaced = (svg) => svg.replace(/\sd="([^"]*)"/g, (_, d) => ` d="${spaceArcs(d)}"`);

const scratch = mkdtempSync(join(tmpdir(), "marfa-icons-"));
try {
  const run = (command, args, cwd) => {
    const result = spawnSync(command, args, { cwd, encoding: "utf8" });
    if (result.status !== 0) {
      console.error(`icons.mjs: ${command} ${args.join(" ")} failed\n${result.stderr}`);
      process.exit(1);
    }
    return result.stdout;
  };
  const tarball = run("npm", ["pack", `lucide-static@${version}`, "--silent", "--pack-destination", scratch], scratch).trim();
  run("tar", ["-xzf", join(scratch, tarball), "-C", scratch], scratch);
  const packaged = JSON.parse(readFileSync(join(scratch, "package/package.json"), "utf8"));
  if (packaged.version !== version) {
    console.error(`icons.mjs: asked for lucide-static ${version} and got ${packaged.version}`);
    process.exit(1);
  }
  const icons = join(scratch, "package/icons");
  const missing = drawn.filter((name) => !existsSync(join(icons, `${name}.svg`)));
  if (missing.length > 0) {
    console.error(`icons.mjs: lucide-static ${version} has no SVG for: ${missing.join(", ")}`);
    process.exit(1);
  }

  const catalog = join(root, "Sources/MarfaIcons/Lucide.xcassets");
  rmSync(catalog, { recursive: true, force: true });
  mkdirSync(catalog, { recursive: true });
  writeFileSync(join(catalog, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2) + "\n");
  for (const name of drawn) {
    const folder = join(catalog, `lucide-${name}.imageset`);
    mkdirSync(folder);
    writeFileSync(join(folder, `${name}.svg`), spaced(readFileSync(join(icons, `${name}.svg`), "utf8")));
    writeFileSync(
      join(folder, "Contents.json"),
      JSON.stringify(
        {
          images: [{ filename: `${name}.svg`, idiom: "universal" }],
          info: { author: "xcode", version: 1 },
          properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" },
        },
        null,
        2,
      ) + "\n",
    );
  }

  const lines = names.map((name) => `        "${name}",`).join("\n");
  writeFileSync(
    join(root, "Sources/MarfaIcons/LucidePinned.swift"),
    `// Generated by scripts/icons.mjs from the Lucide release marfa pins. Never edited.
/// The Lucide release Marfa pins, and every icon name the server accepts at it: the names an app can offer a person
/// to choose from. `TypeIcon` draws each one.
public enum LucidePinned {
    /// The Lucide release.
    public static let version = "${version}"

    /// Every icon name the server accepts at this release, in alphabetical order.
    public static let names: [String] = [
${lines}
    ]
}
`,
  );
  console.log(`Lucide ${version}: ${names.length} names, ${mapped.size} SF Symbols, ${drawn.length} drawn from SVG`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
