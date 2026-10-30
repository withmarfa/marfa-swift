// Regenerates what the type icons ship from one pin: for each Iconify set marfa accepts, the icon list at marfa's
// pinned commit, and the SVG of every icon the package draws itself, taken from the `@iconify-json` package at the
// version that list names.
//
//   scripts/icons.mjs                                  # reads .build/marfa, the checkout scripts/core.sh makes
//   MARFA_MONOREPO=<checkout> scripts/icons.mjs        # a clean checkout already at the pin
//
// Lucide: Sources/MarfaIcons/LucideIconSet.swift and Sources/MarfaIcons/Lucide.xcassets, with an image only for an
// icon that Sources/MarfaIcons/LucideSymbols.swift gives no SF Symbol.
// Simple Icons: Sources/MarfaBrandIcons/SimpleIconsIconSet.swift and Sources/MarfaBrandIcons/SimpleIcons.xcassets,
// with an image for every icon.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = process.env.MARFA_MONOREPO ?? join(root, ".build/marfa");

const sets = [
  {
    prefix: "lucide",
    title: "Lucide",
    enumName: "LucideIconSet",
    target: "MarfaIcons",
    catalog: "Lucide.xcassets",
    summary: "General-purpose icons.",
    symbols: true,
  },
  {
    prefix: "simple-icons",
    title: "Simple Icons",
    enumName: "SimpleIconsIconSet",
    target: "MarfaBrandIcons",
    catalog: "SimpleIcons.xcassets",
    summary: "Brand marks.",
    symbols: false,
  },
];

const fail = (message) => {
  console.error(`icons.mjs: ${message}`);
  process.exit(1);
};

// SVG lets an arc's two flags run into the number after them ("a2 2 0 0020 0"). Core SVG, which draws an asset
// catalog's SVG, reads that wrong, so every arc is written with its parameters spaced.
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
const run = (command, args, cwd) => {
  const result = spawnSync(command, args, { cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (result.status !== 0) fail(`${command} ${args.join(" ")} failed\n${result.stderr}`);
  return result.stdout;
};

try {
  for (const set of sets) {
    const listPath = join(source, `packages/types/generated/icon-set-${set.prefix}.json`);
    if (!existsSync(listPath)) fail(`${listPath} does not exist; run scripts/core.sh first, or set MARFA_MONOREPO`);
    const list = JSON.parse(readFileSync(listPath, "utf8"));
    const { version, icons: names } = list;
    const pkg = `@iconify-json/${set.prefix}`;
    if (list.prefix !== set.prefix || list.package !== pkg) fail(`${listPath} is not the list for ${pkg}`);
    if (!/^\d+\.\d+\.\d+$/.test(version) || !Array.isArray(names) || names.length === 0) {
      fail(`the ${set.prefix} list has no exact version or no names`);
    }
    const bad = names.filter((name) => !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(name));
    if (bad.length > 0) fail(`the ${set.prefix} list has names that are not kebab case: ${bad.join(", ")}`);
    const known = new Set(names);
    const idOf = (name) => `${set.prefix}:${name}`;

    let mapped = new Map();
    if (set.symbols) {
      const table = readFileSync(join(root, "Sources/MarfaIcons/LucideSymbols.swift"), "utf8");
      mapped = new Map([...table.matchAll(/^\s*"([a-z0-9-]+):([a-z0-9-]+)": "([a-z0-9.]+)",$/gm)].map((m) => [`${m[1]}:${m[2]}`, m[3]]));
      const bareOrForeign = table.match(new RegExp(`^\\s*"(?!${set.prefix}:)[^"]*": "`, "m"));
      if (bareOrForeign) fail(`the table has a key that is not a ${set.prefix} ID: ${bareOrForeign[0].trim()}`);
      const strays = [...mapped.keys()].filter((id) => !known.has(id.slice(set.prefix.length + 1)));
      if (strays.length > 0) fail(`the table names icons ${pkg} ${version} does not have: ${strays.join(", ")}`);
    }
    const drawn = names.filter((name) => !mapped.has(idOf(name)));

    const dir = join(scratch, set.prefix);
    mkdirSync(dir);
    const tarball = run("npm", ["pack", `${pkg}@${version}`, "--silent", "--pack-destination", dir], dir).trim();
    run("tar", ["-xzf", join(dir, tarball), "-C", dir], dir);
    const packaged = JSON.parse(readFileSync(join(dir, "package/package.json"), "utf8"));
    if (packaged.name !== pkg || packaged.version !== version) {
      fail(`asked for ${pkg} ${version} and got ${packaged.name} ${packaged.version}`);
    }
    const data = JSON.parse(readFileSync(join(dir, "package/icons.json"), "utf8"));
    if (data.prefix !== set.prefix) fail(`${pkg} holds the set "${data.prefix}"`);
    const missing = drawn.filter((name) => data.icons[name]?.body === undefined);
    if (missing.length > 0) fail(`${pkg} ${version} has no artwork for: ${missing.join(", ")}`);

    const svgOf = (name) => {
      const icon = data.icons[name];
      const width = icon.width ?? data.width;
      const height = icon.height ?? data.height;
      return (
        `<!-- ${pkg}@${version} -->\n` +
        `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">` +
        `${spaced(icon.body)}</svg>\n`
      );
    };

    const sources = join(root, "Sources", set.target);
    const catalog = join(sources, set.catalog);
    rmSync(catalog, { recursive: true, force: true });
    mkdirSync(catalog, { recursive: true });
    writeFileSync(join(catalog, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2) + "\n");
    for (const name of drawn) {
      const folder = join(catalog, `${set.prefix}-${name}.imageset`);
      mkdirSync(folder);
      writeFileSync(join(folder, `${name}.svg`), svgOf(name));
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

    const lines = names.map((name) => `        "${idOf(name)}",`).join("\n");
    writeFileSync(
      join(sources, `${set.enumName}.swift`),
      `// Generated by scripts/icons.mjs from the ${set.title} release marfa pins. Never edited.
/// The ${set.title} release Marfa pins, and every icon ID the server accepts from it: the IDs an app can offer a
/// person to choose from, each \`${set.prefix}:<name>\`.
public enum ${set.enumName} {
    /// The release of \`${pkg}\`.
    public static let version = "${version}"

    /// Every icon ID the server accepts from this release, in alphabetical order.
    public static let ids: [String] = [
${lines}
    ]
}
`,
    );
    console.log(`${set.title} ${version}: ${names.length} icons, ${mapped.size} SF Symbols, ${drawn.length} drawn from SVG`);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
