import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
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
const primitiveTypes = new Set(["string", "number", "integer", "boolean"]);

export function prepare(document) {
  let usesNull = false;
  const nullable = new Map();
  const inline = new Map();
  const canonical = (value) => {
    if (Array.isArray(value)) return value.map(canonical);
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonical(value[key])]),
    );
  };
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
  // A schema with no name of its own becomes a component named by its content.
  const inlineSchema = (target) => {
    const hash = createHash("sha256")
      .update(JSON.stringify(canonical(target)))
      .digest("hex")
      .slice(0, 16);
    const name = `MarfaInline${hash}`;
    inline.set(name, target);
    return name;
  };
  const nullableOf = (target) => {
    const name = `MarfaNullable${target}`;
    nullable.set(name, {
      target,
      schema: {
        anyOf: [{ $ref: `#/components/schemas/${target}` }, { $ref: nullRef }],
      },
    });
    usesNull = true;
    return name;
  };
  // Swift omits a nil optional. A required primitive-or-null member encodes null only in a schema reached
  // from a request body and from no response. A shared component keeps the response shape; a request that
  // needs the null uses a copy.
  const httpMethods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"];
  const schemaRef = (value) =>
    typeof value?.$ref === "string" && value.$ref.startsWith("#/components/schemas/")
      ? value.$ref.slice("#/components/schemas/".length)
      : null;
  const skipWalk = (key) =>
    ["example", "examples", "default", "enum", "const"].includes(key) || key.startsWith("x-");
  const reachable = (root) => {
    const found = new Set();
    const visit = (value, seen) => {
      if (!value || typeof value !== "object") return;
      if (seen.has(value)) return;
      seen.add(value);
      if (Array.isArray(value)) {
        for (const entry of value) visit(entry, seen);
        return;
      }
      const name = schemaRef(value);
      if (name && !found.has(name)) {
        found.add(name);
        visit(document.components?.schemas?.[name], seen);
      }
      for (const [key, child] of Object.entries(value)) {
        if (key === "$ref" || skipWalk(key)) continue;
        visit(child, seen);
      }
    };
    visit(root, new Set());
    return found;
  };
  const reachedFrom = (part) => {
    const names = new Set();
    for (const item of Object.values(document.paths ?? {})) {
      for (const method of httpMethods) {
        const operation = item?.[method];
        if (!operation) continue;
        const contents =
          part === "request"
            ? Object.values(operation.requestBody?.content ?? {})
            : Object.values(operation.responses ?? {}).flatMap((response) =>
                Object.values(response?.content ?? {}),
              );
        for (const content of contents) {
          for (const name of reachable(content?.schema)) names.add(name);
        }
      }
    }
    return names;
  };
  const isRequiredNullablePrimitive = (schema) => {
    const types = Array.isArray(schema?.type) ? schema.type : null;
    if (!types || types.length !== 2 || !types.includes("null")) return false;
    if (Array.isArray(schema.enum) && !schema.enum.includes(null)) return false;
    if ("const" in schema) return false;
    return primitiveTypes.has(types.find((type) => type !== "null"));
  };
  const requestReached = reachedFrom("request");
  const responseReached = reachedFrom("response");
  const requestOnly = new Set(
    [...requestReached].filter((name) => !responseReached.has(name)),
  );
  const diverges = (schema, seen) => {
    if (!schema || typeof schema !== "object") return false;
    const name = schemaRef(schema);
    if (name) {
      if (requestOnly.has(name) || seen.has(name) || !responseReached.has(name)) return false;
      seen.add(name);
      return diverges(document.components?.schemas?.[name], seen);
    }
    if (Array.isArray(schema)) return schema.some((entry) => diverges(entry, seen));
    const required = new Set(schema.required ?? []);
    for (const [property, child] of Object.entries(schema.properties ?? {})) {
      if (required.has(property) && isRequiredNullablePrimitive(child)) return true;
      if (diverges(child, seen)) return true;
    }
    for (const [key, child] of Object.entries(schema)) {
      if (key === "properties" || key === "required" || skipWalk(key)) continue;
      if (diverges(child, seen)) return true;
    }
    return false;
  };
  const requestCopies = new Set(
    [...requestReached].filter((name) => {
      if (requestOnly.has(name)) return false;
      return diverges(document.components?.schemas?.[name], new Set([name]));
    }),
  );
  const requestCopyName = (name) => `MarfaRequest${name}`;
  const requestRef = (ref) => {
    const name = ref.startsWith("#/components/schemas/")
      ? ref.slice("#/components/schemas/".length)
      : null;
    return name && requestCopies.has(name)
      ? `#/components/schemas/${requestCopyName(name)}`
      : ref;
  };
  function schema(value, inUnion = false, property = false, mapValue = false, encodeRequiredNull = false) {
    if (!value || typeof value !== "object" || Array.isArray(value))
      return value;
    if (value.type === "null" && !inUnion) {
      usesNull = true;
      const { type, ...rest } = value;
      return { ...rest, $ref: nullRef };
    }
    const result = {};
    for (const [key, child] of Object.entries(value)) {
      if (key === "$ref" && encodeRequiredNull && typeof child === "string") {
        result[key] = requestRef(child);
      } else if (schemaMaps.has(key)) {
        result[key] = Object.fromEntries(
          Object.entries(child).map(([name, entry]) => [
            name,
            schema(
              entry,
              false,
              key === "properties"
                ? value.required?.includes(name)
                  ? "required"
                  : "optional"
                : false,
              false,
              encodeRequiredNull,
            ),
          ]),
        );
      } else if (schemaArrays.has(key)) {
        result[key] = child.map((member) =>
          schema(member, key === "oneOf" || key === "anyOf", false, false, encodeRequiredNull),
        );
      } else {
        result[key] = schemaValues.has(key)
          ? schema(child, false, false, key === "additionalProperties", encodeRequiredNull)
          : child;
      }
    }
    const types = Array.isArray(result.type) ? result.type : null;
    const otherType = types?.find((type) => type !== "null");
    // An optional nullable property has three states; Swift Optional alone loses explicit null.
    // A required nullable primitive in a request schema has two, so the wrapper stays required and null is written.
    if (
      types?.length === 2 &&
      types.includes("null") &&
      (!Array.isArray(result.enum) || result.enum.includes(null)) &&
      !("const" in result) &&
      (property === "optional" ||
        (property === "required" && encodeRequiredNull && primitiveTypes.has(otherType)))
    ) {
      const annotation = (key) =>
        ["description", "title", "example", "examples", "default", "deprecated", "readOnly", "writeOnly"].includes(key) ||
        key.startsWith("x-");
      const annotations = Object.fromEntries(
        Object.entries(result).filter(([key]) => annotation(key)),
      );
      const targetSchema = {
        ...Object.fromEntries(Object.entries(result).filter(([key]) => !annotation(key))),
        type: result.type.find((type) => type !== "null"),
      };
      if (Array.isArray(targetSchema.enum))
        targetSchema.enum = targetSchema.enum.filter((value) => value !== null);
      const name = nullableOf(inlineSchema(targetSchema));
      return { ...annotations, $ref: `#/components/schemas/${name}` };
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
    if (Array.isArray(union)) {
      const isNull = (entry) =>
        entry.type === "null" && Object.keys(entry).length === 1;
      const nulls = union.filter(isNull);
      const values = union.filter((entry) => !isNull(entry));
      if (
        nulls.length === 1 &&
        values.length === 1 &&
        typeof values[0].$ref === "string" &&
        Object.keys(values[0]).length === 1
      ) {
        const target = values[0].$ref.replace(/^#\/components\/schemas\//, "");
        if (!/^[A-Z][A-Za-z0-9_]*$/.test(target))
          throw new Error(`unsupported nullable reference: ${values[0].$ref}`);
        delete result[unionKey];
        result.$ref = `#/components/schemas/${nullableOf(target)}`;
      } else if (!mapValue && nulls.length > 0 && values.length > 0) {
        // Members without a name of their own go into a component, so the generator's own type for
        // one member, or its anyOf or oneOf type for several, sits inside the nullable. The generator
        // reads no type from a union under additionalProperties and makes a container of the object,
        // so a component there would be unused.
        const target = inlineSchema(
          values.length === 1 ? values[0] : { [unionKey]: values },
        );
        delete result[unionKey];
        result.$ref = `#/components/schemas/${nullableOf(target)}`;
      }
    }
    return result;
  }
  function walk(value, encodeRequiredNull = false) {
    if (Array.isArray(value)) return value.map((entry) => walk(entry, encodeRequiredNull));
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => {
        if (key === "schema") return [key, schema(child, false, false, false, encodeRequiredNull)];
        if (skipWalk(key)) return [key, child];
        const nested =
          key === "requestBody" ? true : key === "responses" ? false : encodeRequiredNull;
        return [key, walk(child, nested)];
      }),
    );
  }
  const result = walk(document);
  if (document.components?.schemas) {
    result.components.schemas = Object.fromEntries(
      Object.entries(document.components.schemas).map(([name, value]) => [
        name,
        schema(value, false, false, false, requestOnly.has(name)),
      ]),
    );
    for (const name of [...requestCopies].sort()) {
      const copy = requestCopyName(name);
      if (copy in result.components.schemas)
        throw new Error(`the API document already defines ${copy}`);
      result.components.schemas[copy] = schema(
        document.components.schemas[name],
        false,
        false,
        false,
        true,
      );
    }
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
  for (const [name, value] of inline) {
    if (name in result.components.schemas)
      throw new Error(`the API document already defines ${name}`);
    result.components.schemas[name] = value;
  }
  for (const [name, entry] of nullable) {
    if (name in result.components.schemas)
      throw new Error(`the API document already defines ${name}`);
    result.components.schemas[name] = entry.schema;
  }
  return { document: result, nullable, usesNull };
}

// A connector calls these with a key of its own, through the TypeScript SDK or HTTP. The owner's side of them stays in
// the client: today those are exactly the ones the server's own socket takes, which it marks `x-marfa-local-command`.
const connectorTags = new Set(["Connectors", "Connector state", "Inbound webhooks"]);
// A working copy reads and writes these itself, offline, so the client leaves them out.
const copyTags = new Set([
  "Items",
  "Metadata",
  "Extensions",
  "Edges",
  "Search",
  "Event stream",
  "Folders",
  "Views",
]);
// What the server answers from those areas and a copy does not hold.
const serverOnly = new Set([
  "getItemStats",
  "listOccurrences",
  "getItemMetadata",
  "listTags",
  "getItemExtension",
  "listItemExtensions",
  "getFolderStatus",
  "countItemLinks",
]);
// A copy uploads a blob's bytes and fetches them itself.
const copyBlobs = new Set(["uploadBlob", "downloadBlob"]);
// `Server` in the Marfa module makes these itself, so an app has one way to call each.
const serverCalls = new Set([
  "listItemVersions", "setTypeIcon", "clearTypeIcon", "listSources", "getSource", "updateSource", "getItemStats",
  "countItemLinks",
]);
const methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"];

function* operations(document) {
  for (const [path, item] of Object.entries(document.paths ?? {}))
    for (const method of methods)
      if (item[method]?.operationId) yield { path, method, operation: item[method] };
}

// The operations the client makes: those an app's key or access token may call, less what a connector calls with
// its own key, what a working copy does and what `Server` calls.
export function clientOperations(document) {
  const kept = [];
  for (const { operation } of operations(document)) {
    const security = operation.security ?? document.security ?? [];
    if (!security.some((requirement) => "bearerAuth" in requirement)) continue;
    const tags = operation.tags ?? [];
    if (tags.some((tag) => connectorTags.has(tag)) && !operation["x-marfa-local-command"]) continue;
    if (tags.some((tag) => copyTags.has(tag)) && !serverOnly.has(operation.operationId)) continue;
    if (copyBlobs.has(operation.operationId)) continue;
    if (serverCalls.has(operation.operationId)) continue;
    kept.push(operation.operationId);
  }
  return kept.sort();
}

// The document with only `kept` operations, each answering only its successes: the client throws a refusal
// before it would read one.
function clientDocument(document, kept) {
  const result = structuredClone(document);
  for (const [path, item] of Object.entries(result.paths ?? {})) {
    for (const method of methods) {
      const operation = item[method];
      if (!operation?.operationId) continue;
      if (!kept.has(operation.operationId)) {
        delete item[method];
        continue;
      }
      for (const status of Object.keys(operation.responses ?? {}))
        if (!/^[123]/.test(status)) delete operation.responses[status];
    }
    if (!methods.some((method) => item[method])) delete result.paths[path];
  }
  return result;
}

function replaceOnce(text, pattern, replacement, file) {
  const matches = text.match(new RegExp(pattern.source, `${pattern.flags.replace("g", "")}g`)) ?? [];
  if (matches.length !== 1)
    throw new Error(`${file}: expected one match of ${pattern}, found ${matches.length}`);
  return text.replace(pattern, replacement);
}

function run(binary, scratch, name, document, config) {
  const prepared = join(scratch, `${name}.json`);
  const diagnostics = join(scratch, `${name}-diagnostics.yaml`);
  const configFile = join(scratch, `${name}-config.yaml`);
  const output = join(scratch, name);
  writeFileSync(prepared, JSON.stringify(document, null, 2));
  writeFileSync(configFile, config);
  mkdirSync(output);
  const result = spawnSync(
    binary,
    [
      "generate",
      "--config",
      configFile,
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
    throw new Error(`${name} generation failed: ${result.stderr || result.stdout}`);
  const report = readFileSync(diagnostics, "utf8").trim();
  if (report !== "diagnostics: []\nuniqueMessages: []")
    throw new Error(`${name} generation reported diagnostics:\n${report}`);
  return output;
}

// Publish only a complete generation, so a skipped schema leaves the last good output available for
// inspection.
function publish(output, destination) {
  rmSync(destination, { recursive: true, force: true });
  mkdirSync(destination, { recursive: true });
  for (const name of readdirSync(output))
    copyFileSync(join(output, name), join(destination, name));
}

const clientSummary = `/// The server's own operations, for what only the server can do.
///
/// Make one with \`Client(_:)\` from a \`Server\`. A working copy answers items, edges, search, folders and
/// views, offline, and \`Server\` reads an item's versions, names sources and sets a type's icon; this client calls
/// the server for the rest, such as registering a type, managing keys or looking after the instance as its owner
/// (updates, settings, backups, passkeys, sign-ins, app grants, the profile, the trash and what needs attention),
/// and needs a connection for each call. Every call throws \`MarfaError\`.
`;

export function generate(binary, source, destination, clientDestination) {
  const document = JSON.parse(readFileSync(source, "utf8"));
  const contract = String(document.info?.version);
  if (!/^(0|[1-9][0-9]*)$/.test(contract))
    throw new Error("the API document must name a whole-number contract");
  const scratch = mkdtempSync(join(tmpdir(), "marfa-types-"));
  try {
    const preparedDocument = prepare(document);
    const overrides =
      (preparedDocument.usesNull ? "    MarfaNull: MarfaNullValue\n" : "") +
      [...preparedDocument.nullable]
        .map(
          ([name, { target }]) =>
            `    ${name}: MarfaNullable<Components.Schemas.${target}>\n`,
        )
        .join("");
    const base = readFileSync(join(here, "openapi-generator-config.yaml"), "utf8") + overrides;
    const output = run(binary, scratch, "types", preparedDocument.document, base);
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
    let client;
    if (clientDestination) {
      const filtered = clientDocument(
        preparedDocument.document,
        new Set(clientOperations(document)),
      );
      // The wire types are MarfaTypes'; of each run only the client and its protocol are kept.
      const imports = "additionalImports:\n  - MarfaTypes\n";
      const made = run(
        binary, scratch, "client", filtered,
        base.replace("  - types\n", "  - client\n") + imports,
      );
      const surface = run(binary, scratch, "surface", filtered, base + imports);
      client = join(scratch, "published-client");
      mkdirSync(client);
      let code = readFileSync(join(made, "Client.swift"), "utf8");
      code = replaceOnce(
        code,
        /(public import MarfaTypes\n)(?:\/\/\/.*\n)+public struct Client: APIProtocol \{\n/,
        `$1${clientSummary}public struct Client: ClientProtocol {\n`,
        "Client.swift",
      );
      code = replaceOnce(code, /private let client: UniversalClient\n/, "private let client: Sender\n", "Client.swift");
      code = replaceOnce(code, /\n    public init\(\n        serverURL:/, "\n    init(\n        serverURL:", "Client.swift");
      writeFileSync(join(client, "Client.swift"), code);
      let protocol = readFileSync(join(surface, "Types.swift"), "utf8");
      protocol = replaceOnce(protocol, /public protocol APIProtocol: Sendable \{/, "public protocol ClientProtocol: Sendable {", "Types.swift");
      protocol = replaceOnce(protocol, /\nextension APIProtocol \{/, "\nextension ClientProtocol {", "Types.swift");
      protocol = replaceOnce(protocol, /\n\/\/\/ Server URLs defined in the OpenAPI document\.\npublic enum Servers \{[\s\S]*$/, "\n", "Types.swift");
      writeFileSync(join(client, "ClientProtocol.swift"), protocol);
    }
    publish(output, destination);
    if (client) publish(client, clientDestination);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  const [, , binary, source, destination, clientDestination] = process.argv;
  if (!binary || !source || !destination || !clientDestination)
    throw new Error(
      "usage: node generator/generate.mjs <generator> <openapi.json> <types-directory> <client-directory>",
    );
  generate(binary, source, destination, clientDestination);
}
