import { readdir, readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const forbidden = /(?:\bas\s+any\b|:\s*any\b|<any>|\bts-(?:ignore|nocheck)\b)/;

async function sourceFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await sourceFiles(path));
    else if ([".ts", ".mjs"].includes(extname(entry.name))) files.push(path);
  }
  return files;
}

for (const file of await sourceFiles(join(root, "src"))) {
  const contents = await readFile(file, "utf8");
  if (forbidden.test(contents)) {
    throw new Error(`${file} contains a forbidden type escape`);
  }
  if (contents.includes("\r")) throw new Error(`${file} contains CRLF line endings`);
}
