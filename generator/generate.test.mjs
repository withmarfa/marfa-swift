import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { generate, prepare } from "./generate.mjs";

const nullable = {
  anyOf: [
    { $ref: "#/components/schemas/BackgroundJobReport" },
    { type: "null" },
  ],
};
const document = (schema) => ({
  openapi: "3.1.0",
  info: { title: "Fixture", version: "1" },
  paths: {},
  components: {
    schemas: { Fixture: schema, BackgroundJobReport: { type: "object" } },
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
    $ref: "#/components/schemas/MarfaNullableBackgroundJobReport",
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
      $ref: "#/components/schemas/MarfaNullableBackgroundJobReport",
      description: "clear",
    },
  );
  assert.deepEqual(
    output.paths["/rows"].post.responses[200].content["application/json"].schema
      .items,
    { $ref: "#/components/schemas/MarfaNullableBackgroundJobReport" },
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
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  },
);

test("leaves other unsupported null schemas for the diagnostic guard", () => {
  const input = document({ anyOf: [{ type: "string" }, { type: "null" }] });
  assert.deepEqual(prepare(input).document, input);
});
