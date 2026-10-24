import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { clientOperations, generate, prepare } from "./generate.mjs";

const nullable = {
  anyOf: [
    { $ref: "#/components/schemas/HousekeepingReport" },
    { type: "null" },
  ],
};
const document = (schema) => ({
  openapi: "3.1.0",
  info: { title: "Fixture", version: "1" },
  paths: {},
  components: {
    schemas: { Fixture: schema, HousekeepingReport: { type: "object" } },
  },
});

test("normalizes null schemas without changing examples or the source", () => {
  const example = { schema: { type: "null" }, type: "null" };
  const input = document({
    type: "object",
    properties: { result: nullable },
    example,
  });
  const before = JSON.stringify(input);
  const { document: output } = prepare(input);
  assert.deepEqual(output.components.schemas.Fixture.properties.result, {
    $ref: "#/components/schemas/MarfaNullableHousekeepingReport",
  });
  assert.deepEqual(output.components.schemas.MarfaNull, { enum: [null] });
  assert.deepEqual(output.components.schemas.Fixture.example, example);
  assert.equal(JSON.stringify(input), before);
});

test("visits inline request and response schemas and preserves constraints", () => {
  const input = document({ type: "string" });
  input.paths["/rows"] = {
    post: {
      requestBody: {
        content: {
          "application/json": {
            schema: {
              type: "object",
              properties: {
                value: { ...nullable, description: "clear" },
              },
            },
          },
        },
      },
      responses: {
        200: {
          description: "ok",
          content: {
            "application/json": {
              schema: { type: "array", items: nullable },
            },
          },
        },
      },
    },
  };
  const { document: output } = prepare(input);
  assert.deepEqual(
    output.paths["/rows"].post.requestBody.content["application/json"].schema
      .properties.value,
    {
      $ref: "#/components/schemas/MarfaNullableHousekeepingReport",
      description: "clear",
    },
  );
  assert.deepEqual(
    output.paths["/rows"].post.responses[200].content["application/json"].schema
      .items,
    { $ref: "#/components/schemas/MarfaNullableHousekeepingReport" },
  );
});

test("refuses a reserved schema collision", () => {
  const input = document(nullable);
  input.components.schemas.MarfaNull = { type: "string" };
  assert.throws(() => prepare(input), /already defines/);
});

test(
  "a real skipped-schema diagnostic fails without replacing good output",
  {
    skip:
      !process.env.MARFA_GENERATOR_BIN &&
      "the core generation step supplies the generator binary",
  },
  () => {
    const scratch = mkdtempSync(join(tmpdir(), "marfa-generator-test-"));
    try {
      const source = join(scratch, "input.json");
      const output = join(scratch, "output");
      mkdirSync(output);
      const retained = join(output, "last-good.swift");
      writeFileSync(retained, "last good");
      writeFileSync(
        source,
        JSON.stringify(
          document({
            type: "object",
            properties: { omitted: { not: { type: "string" } } },
          }),
        ),
      );
      assert.throws(
        () => generate(process.env.MARFA_GENERATOR_BIN, source, output),
        /reported diagnostics:[\s\S]*skipping/,
      );
      assert.equal(readFileSync(retained, "utf8"), "last good");
      writeFileSync(source, JSON.stringify(document(nullable)));
      generate(process.env.MARFA_GENERATOR_BIN, source, output);
      assert.match(
        readFileSync(join(output, "Types+Components+Schemas.swift"), "utf8"),
        /MarfaNull/,
      );
      writeFileSync(source, JSON.stringify(document({
        type: "object",
        properties: {
          next_cursor: { type: "null" },
          optional: { type: "null" },
        },
        required: ["next_cursor"],
      })));
      generate(process.env.MARFA_GENERATOR_BIN, source, output);
      const nullFields = readFileSync(join(output, "Types+Components+Schemas.swift"), "utf8");
      assert.match(nullFields, /nextCursor: Components\.Schemas\.MarfaNull[^?]/);
      assert.match(nullFields, /optional: Components\.Schemas\.MarfaNull\?/);
      writeFileSync(source, JSON.stringify(document({
        type: "object",
        properties: {
          actor: {
            anyOf: [
              { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
              { type: "object", properties: { kind: { type: "string", enum: ["server"] } }, required: ["kind"] },
              { type: "null" },
            ],
          },
          label: { oneOf: [{ type: "string" }, { type: "null" }] },
        },
        required: ["actor", "label"],
      })));
      generate(process.env.MARFA_GENERATOR_BIN, source, output);
      const unions = readFileSync(join(output, "Types+Components+Schemas.swift"), "utf8");
      assert.match(unions, /actor: Components\.Schemas\.MarfaNullableMarfaInline[0-9a-f]{16}[^?]/);
      assert.match(unions, /label: Components\.Schemas\.MarfaNullableMarfaInline[0-9a-f]{16}[^?]/);
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  },
);

test("leaves a union of only null for the diagnostic guard", () => {
  const input = document({ anyOf: [{ type: "null" }] });
  assert.deepEqual(prepare(input).document, input);
});

test("reads an anyOf or oneOf of one inline schema and null as that schema or null", () => {
  for (const key of ["anyOf", "oneOf"]) {
    const input = document({
      type: "object",
      properties: {
        label: { [key]: [{ type: "string", maxLength: 8 }, { type: "null" }], description: "kept" },
      },
    });
    const before = JSON.stringify(input);
    const { document: output, nullable } = prepare(input);
    const field = output.components.schemas.Fixture.properties.label;
    assert.equal(field.description, "kept");
    assert.ok(!(key in field));
    const name = field.$ref.split("/").at(-1);
    assert.deepEqual(output.components.schemas[name], {
      anyOf: [{ $ref: `#/components/schemas/${nullable.get(name).target}` }, { $ref: "#/components/schemas/MarfaNull" }],
    });
    assert.deepEqual(output.components.schemas[nullable.get(name).target], { type: "string", maxLength: 8 });
    assert.equal(JSON.stringify(input), before);
  }
});

test("reads a union of several schemas and null as that union or null", () => {
  for (const key of ["anyOf", "oneOf"]) {
    const members = [
      { type: "object", properties: { kind: { type: "string" } }, required: ["kind"] },
      { type: "number" },
    ];
    const input = document({
      type: "object",
      properties: { actor: { [key]: [...members, { type: "null" }] } },
      required: ["actor"],
    });
    const { document: output, nullable } = prepare(input);
    const name = output.components.schemas.Fixture.properties.actor.$ref.split("/").at(-1);
    assert.deepEqual(output.components.schemas[nullable.get(name).target], { [key]: members });
    assert.deepEqual(prepare(input).document, output);
  }
});

test("reads null inside a nested union member's own properties", () => {
  const input = document({
    type: "object",
    properties: {
      actor: {
        anyOf: [
          { type: "object", properties: { id: { anyOf: [{ type: "string" }, { type: "null" }] } } },
          { type: "number" },
          { type: "null" },
        ],
      },
    },
  });
  const { document: output, nullable } = prepare(input);
  const name = output.components.schemas.Fixture.properties.actor.$ref.split("/").at(-1);
  const union = output.components.schemas[nullable.get(name).target].anyOf;
  assert.match(union[0].properties.id.$ref, /MarfaNullableMarfaInline/);
});

test("leaves a union under additionalProperties as it was, because the generator reads no type from it", () => {
  const input = document({
    type: "object",
    additionalProperties: { anyOf: [{ type: "number" }, { type: "string" }, { type: "null" }] },
  });
  assert.deepEqual(prepare(input).document.components.schemas.Fixture, input.components.schemas.Fixture);
});

test("treats a oneOf of a reference and null as nullable", () => {
  const input = document({
    type: "object",
    properties: {
      result: {
        oneOf: [
          { $ref: "#/components/schemas/HousekeepingReport" },
          { type: "null" },
        ],
        description: "kept",
      },
    },
  });
  const { document: output } = prepare(input);
  assert.deepEqual(output.components.schemas.Fixture.properties.result, {
    $ref: "#/components/schemas/MarfaNullableHousekeepingReport",
    description: "kept",
  });
});

test("reads a reference with only a description beside it as the reference", () => {
  const input = document({
    type: "object",
    properties: {
      report: {
        allOf: [
          { $ref: "#/components/schemas/HousekeepingReport" },
          { description: "what the run reports" },
        ],
      },
    },
  });
  const { document: output } = prepare(input);
  assert.deepEqual(output.components.schemas.Fixture.properties.report, {
    $ref: "#/components/schemas/HousekeepingReport",
    description: "what the run reports",
  });
});

test("leaves an allOf that adds more than a description to a reference", () => {
  const joined = {
    allOf: [
      { $ref: "#/components/schemas/HousekeepingReport" },
      { type: "object", properties: { extra: { type: "string" } } },
    ],
  };
  assert.deepEqual(prepare(document(joined)).document, document(joined));
});

test("drops a requirement one member makes of a name another defines, and keeps one nobody defines", () => {
  const input = document({
    allOf: [
      { $ref: "#/components/schemas/Frame" },
      {
        type: "object",
        properties: { id: { type: "string" } },
        required: ["id", "metadata", "typo"],
      },
    ],
  });
  input.components.schemas.Frame = {
    type: "object",
    properties: { metadata: { type: "string" } },
  };
  const { document: output } = prepare(input);
  assert.deepEqual(output.components.schemas.Fixture.allOf[1].required, [
    "id",
    "typo",
  ]);
});


test("normalizes null-only properties, array items, and references without changing required fields", () => {
  const input = document({
    type: "object",
    properties: {
      next_cursor: { type: "null", description: "Always null" },
      optional: { type: "null" },
      values: { type: "array", items: { type: "null" } },
      named: { $ref: "#/components/schemas/OnlyNull" },
    },
    required: ["next_cursor"],
  });
  input.components.schemas.OnlyNull = { type: "null" };
  const before = JSON.stringify(input);
  const { document: output, usesNull } = prepare(input);
  assert.equal(usesNull, true);
  assert.deepEqual(output.components.schemas.Fixture.properties, {
    next_cursor: { $ref: "#/components/schemas/MarfaNull", description: "Always null" },
    optional: { $ref: "#/components/schemas/MarfaNull" },
    values: { type: "array", items: { $ref: "#/components/schemas/MarfaNull" } },
    named: { $ref: "#/components/schemas/OnlyNull" },
  });
  assert.deepEqual(output.components.schemas.OnlyNull, { $ref: "#/components/schemas/MarfaNull" });
  assert.deepEqual(output.components.schemas.MarfaNull, { enum: [null] });
  assert.deepEqual(output.components.schemas.Fixture.required, ["next_cursor"]);
  assert.equal(JSON.stringify(input), before);
});

test("optional nullable type arrays keep presence, constraints, and annotations", () => {
  const field = {
    type: ["string", "null"],
    format: "uri",
    maxLength: 2048,
    description: "null clears the value",
    example: { type: ["string", "null"] },
    "x-fixture": { type: ["string", "null"] },
  };
  const input = document({
    type: "object",
    properties: {
      optional: field,
      required: field,
      choice: { type: ["null", "string"], enum: [null, "a", "b"] },
    },
    required: ["required"],
  });
  const before = JSON.stringify(input);
  const result = prepare(input);
  const fields = result.document.components.schemas.Fixture.properties;
  assert.ok(fields.optional.$ref);
  assert.deepEqual(fields.required, field);
  assert.equal(result.nullable.size, 2);
  const name = fields.optional.$ref.split("/").at(-1);
  const target = result.nullable.get(name).target;
  assert.deepEqual(result.document.components.schemas[target], {
    type: "string", format: "uri", maxLength: 2048,
  });
  assert.equal(fields.optional.description, field.description);
  assert.deepEqual(fields.optional.example, field.example);
  assert.deepEqual(fields.optional["x-fixture"], field["x-fixture"]);
  const choiceName = fields.choice.$ref.split("/").at(-1);
  const choice = result.document.components.schemas[result.nullable.get(choiceName).target];
  assert.deepEqual(choice, { type: "string", enum: ["a", "b"] });
  assert.deepEqual(prepare(input).document, result.document);
  assert.equal(JSON.stringify(input), before);
  const reordered = structuredClone(input);
  reordered.components.schemas.Fixture.properties.optional = Object.fromEntries(Object.entries(field).reverse());
  assert.equal(prepare(reordered).document.components.schemas.Fixture.properties.optional.$ref, fields.optional.$ref);
  for (const reserved of [name, target]) {
    const collision = structuredClone(input);
    collision.components.schemas[reserved] = { type: "string" };
    assert.throws(() => prepare(collision), /already defines/);
  }
});

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

test("the client keeps what an app's credential calls on the server and a working copy does not do", () => {
  const operation = (operationId, tags, security = [{ bearerAuth: [] }]) => ({
    operationId, tags, security, responses: {},
  });
  const input = {
    openapi: "3.1.0",
    info: { title: "Fixture", version: "1" },
    paths: {
      "/types": { post: operation("registerType", ["Types"]) },
      "/items": { post: operation("createItem", ["Items"]) },
      "/items/{id}/versions": { get: operation("listItemVersions", ["Items"]) },
      "/items/new": { get: operation("aNewItemsOperation", ["Items"]) },
      "/items/bulk-actions": { post: operation("applyBulkAction", ["Bulk actions"]) },
      "/connectors": { post: operation("registerConnector", ["Connectors"]) },
      "/owner": { get: operation("getOwner", ["Owner"], [{ ownerSession: [] }]) },
      "/": { get: operation("getInstance", ["Instance"], []) },
      "/blobs": { post: operation("uploadBlob", ["Blobs"]) },
      "/blobs/stores": { get: operation("listBlobStores", ["Blobs"]) },
      "/new": { get: operation("aNewServerOperation", ["Something new"]) },
    },
  };
  assert.deepEqual(clientOperations(input), [
    "aNewServerOperation", "listBlobStores", "listItemVersions", "registerType",
  ]);
});

test("the committed client makes what the rule keeps from the pinned document", () => {
  const generated = (file) => [
    ...readFileSync(join(root, file), "utf8").matchAll(/- Remark: Generated from `#\/paths\/[^`]*\((\w+)\)`/g),
  ].map((match) => match[1]);
  const client = new Set(generated("Sources/MarfaAPI/Generated/Client.swift"));
  // The wire types describe every operation, so each absence below is the client's own.
  const wire = new Set(generated("Sources/MarfaTypes/Types.swift"));
  for (const kept of ["registerType", "getCurrentKey", "listItemVersions"]) assert.ok(client.has(kept), kept);
  for (const left of ["createItem", "applyBulkAction", "registerConnector", "getOwner", "getInstance"]) {
    assert.ok(wire.has(left), left);
    assert.ok(!client.has(left), left);
  }
  const openapi = join(root, ".build/marfa/openapi.json");
  try {
    assert.deepEqual([...client].sort(), clientOperations(JSON.parse(readFileSync(openapi, "utf8"))));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
});
