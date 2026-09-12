import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(packageRoot, "../..");

test("package metadata declares support, provenance, and zero runtime dependencies", async () => {
  const manifest = JSON.parse(await readFile(resolve(packageRoot, "package.json"), "utf8"));
  assert.equal(manifest.type, "module");
  assert.equal(manifest.engines.node, ">=22");
  assert.equal(manifest.license, "MIT");
  assert.equal(manifest.publishConfig.access, "public");
  assert.equal(manifest.publishConfig.provenance, true);
  assert.equal(manifest.dependencies, undefined);
  assert.deepEqual(manifest.exports["."], {
    types: "./dist/index.d.ts",
    import: "./dist/index.js",
  });
});

test("pack contents match the exact runtime allowlist", () => {
  const packed = spawnSync(
    "npm",
    ["pack", "--dry-run", "--json", "--ignore-scripts"],
    { cwd: packageRoot, encoding: "utf8" },
  );
  assert.equal(packed.status, 0, packed.stderr);
  const report = JSON.parse(packed.stdout);
  const files = report[0].files.map((file) => file.path).sort();
  const expected = [
    "LICENSE",
    "README.md",
    "bin/headless.mjs",
    "bin/headless-mcp.mjs",
    "dist/client.d.ts",
    "dist/client.js",
    "dist/errors.d.ts",
    "dist/errors.js",
    "dist/generated.d.ts",
    "dist/generated.js",
    "dist/index.d.ts",
    "dist/index.js",
    "dist/lifecycle.d.ts",
    "dist/lifecycle.js",
    "dist/protocol.d.ts",
    "dist/protocol.js",
    "dist/transport.d.ts",
    "dist/transport.js",
    "lib/installer.d.mts",
    "lib/installer.mjs",
    "lib/launcher.mjs",
    "package.json",
  ].sort();
  assert.deepEqual(files, expected);
});

test("published license matches the repository license", async () => {
  const [packaged, repository] = await Promise.all([
    readFile(resolve(packageRoot, "LICENSE"), "utf8"),
    readFile(resolve(repositoryRoot, "LICENSE"), "utf8"),
  ]);
  assert.equal(packaged, repository);
});
