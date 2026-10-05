import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const nullName = "MarfaNull";
const nullRef = `#/components/schemas/${nullName}`;

export function prepare(document) {
  let usesNull = false;
  const nullable = new Map();
  const schemaMaps = new Set([
    "properties",
    "patternProperties",
    "$defs",
    "definitions",
    "dependentSchemas",
  ]);
  const schemaArrays = new Set(["allOf", "anyOf", "oneOf", "prefixItems"]);
  const schemaValues = new Set([
    "items",
    "additionalProperties",
    "contains",
    "propertyNames",
    "unevaluatedProperties",
    "not",
    "if",
    "then",
    "else",
  ]);
  function schema(value) {
    if (!value || typeof value !== "object" || Array.isArray(value))
      return value;
    const result = {};
    for (const [key, child] of Object.entries(value)) {
      if (schemaMaps.has(key)) {
        result[key] = Object.fromEntries(
          Object.entries(child).map(([name, entry]) => [name, schema(entry)]),
        );
      } else if (schemaArrays.has(key)) {
        result[key] = child.map(schema);
      } else {
        result[key] = schemaValues.has(key) ? schema(child) : child;
      }
    }
    if (Array.isArray(result.allOf) && result.allOf.length >= 2) {
      // A reference with only a description beside it is the reference: the generator would make a pair of
      // values of it, the second an untyped container.
      const refs = result.allOf.filter(
        (member) =>
          typeof member.$ref === "string" && Object.keys(member).length === 1,
      );
      const rest = result.allOf.filter((member) => !refs.includes(member));
      if (
        refs.length === 1 &&
        rest.every((member) =>
          Object.keys(member).every((key) => key === "description"),
        )
      ) {
        const { allOf, ...others } = result;
        return { ...others, ...refs[0], ...Object.assign({}, ...rest) };
      }
    }
    if (Array.isArray(result.allOf)) {
      // The generator skips, with a warning, a name one member requires and another member defines.
      const defines = (member, name) => {
        const target = member.$ref?.replace(/^#\/components\/schemas\//, "");
        const properties = target
          ? document.components?.schemas?.[target]?.properties
          : member.properties;
        return properties !== undefined && name in properties;
      };
      for (const member of result.allOf) {
        if (!Array.isArray(member.required)) continue;
        member.required = member.required.filter(
          (name) =>
            defines(member, name) ||
            !result.allOf.some(
              (other) => other !== member && defines(other, name),
            ),
        );
      }
    }
    const unionKey = Array.isArray(result.oneOf) ? "oneOf" : "anyOf";
    const union = result[unionKey];
    if (Array.isArray(union) && union.length === 2) {
      const nulls = union.filter(
        (entry) => entry.type === "null" && Object.keys(entry).length === 1,
      );
      const values = union.filter((entry) => entry.type !== "null");
      if (
        nulls.length === 1 &&
        values.length === 1 &&
        typeof values[0].$ref === "string" &&
        Object.keys(values[0]).length === 1
      ) {
        const target = values[0].$ref.replace(/^#\/components\/schemas\//, "");
        if (!/^[A-Z][A-Za-z0-9_]*$/.test(target))
          throw new Error(`unsupported nullable reference: ${values[0].$ref}`);
        const name = `MarfaNullable${target}`;
        usesNull = true;
        nullable.set(name, {
          target,
          schema: { anyOf: [values[0], { $ref: nullRef }] },
        });
        delete result[unionKey];
        result.$ref = `#/components/schemas/${name}`;
      }
    }
    return result;
  }
  function walk(value) {
    if (Array.isArray(value)) return value.map(walk);
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => {
        if (key === "schema") return [key, schema(child)];
        if (
          ["example", "examples", "default", "enum", "const"].includes(key) ||
          key.startsWith("x-")
        )
          return [key, child];
        return [key, walk(child)];
      }),
    );
  }
  const result = walk(document);
  if (document.components?.schemas) {
    result.components.schemas = Object.fromEntries(
      Object.entries(document.components.schemas).map(([name, value]) => [
        name,
        schema(value),
      ]),
    );
  }
  if (usesNull) {
    result.components ??= {};
    result.components.schemas ??= {};
    if (nullName in result.components.schemas)
      throw new Error(`the API document already defines ${nullName}`);
    // An enum containing only null is equivalent to type:null. The generator
    // accepts this schema, and its configured Swift type admits only null.
    result.components.schemas[nullName] = { enum: [null] };
  }
  for (const [name, entry] of nullable) {
    if (name in result.components.schemas)
      throw new Error(`the API document already defines ${name}`);
    result.components.schemas[name] = entry.schema;
  }
  return { document: result, nullable };
}

export function generate(binary, source, destination) {
  const document = JSON.parse(readFileSync(source, "utf8"));
  const contract = String(document.info?.version);
  if (!/^(0|[1-9][0-9]*)$/.test(contract))
    throw new Error("the API document must name a whole-number contract");
  const scratch = mkdtempSync(join(tmpdir(), "marfa-types-"));
  try {
    const prepared = join(scratch, "openapi.json");
    const diagnostics = join(scratch, "diagnostics.yaml");
    const output = join(scratch, "types");
    const preparedDocument = prepare(document);
    writeFileSync(prepared, JSON.stringify(preparedDocument.document, null, 2));
    const config = join(scratch, "config.yaml");
    const overrides = [...preparedDocument.nullable]
      .map(
        ([name, { target }]) =>
          `    ${name}: MarfaNullable<Components.Schemas.${target}>\n`,
      )
      .join("");
    writeFileSync(
      config,
      readFileSync(join(here, "openapi-generator-config.yaml"), "utf8") +
        (preparedDocument.nullable.size
          ? "    MarfaNull: MarfaNullValue\n"
          : "") +
        overrides,
    );
    mkdirSync(output);
    const result = spawnSync(
      binary,
      [
        "generate",
        "--config",
        config,
        "--diagnostics-output-path",
        diagnostics,
        "--output-directory",
        output,
        prepared,
      ],
      { encoding: "utf8" },
    );
    if (result.error) throw result.error;
    if (result.status !== 0)
      throw new Error(
        `wire generation failed: ${result.stderr || result.stdout}`,
      );
    const report = readFileSync(diagnostics, "utf8").trim();
    if (report !== "diagnostics: []\nuniqueMessages: []")
      throw new Error(`wire generation reported diagnostics:\n${report}`);
    copyFileSync(
      join(here, "MarfaNullValue.swift"),
      join(output, "MarfaNullValue.swift"),
    );
    copyFileSync(
      join(here, "MarfaNullable.swift"),
      join(output, "MarfaNullable.swift"),
    );
    writeFileSync(
      join(output, "Contract.swift"),
      `// Generated from the pinned openapi.json by scripts/core.sh; do not edit.\n\n/// The contract version these types describe: the document's \`info.version\`,\n/// which an instance's root answers as \`contract\`.\npublic let marfaContractVersion = ${contract}\n`,
    );
    // Publish only a complete generation, so a skipped schema leaves the
    // last good output available for inspection.
    rmSync(destination, { recursive: true, force: true });
    mkdirSync(destination, { recursive: true });
    for (const name of readdirSync(output))
      copyFileSync(join(output, name), join(destination, name));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  const [, , binary, source, destination] = process.argv;
  if (!binary || !source || !destination)
    throw new Error(
      "usage: node generator/generate.mjs <generator> <openapi.json> <output-directory>",
    );
  generate(binary, source, destination);
}
