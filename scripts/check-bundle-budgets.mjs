import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const assetDir = join(process.cwd(), ".vercel", "output", "static", "assets");
const initialBudget = 100 * 1024;
const routeBudget = 25 * 1024;
const routePrefixes = new Set([
  "_app",
  "addons",
  "agents",
  "artifacts",
  "complete",
  "connect",
  "cron",
  "insights",
  "login",
  "memory",
  "projects",
  "settings",
  "settings-panel",
  "skills",
  "tools",
]);

function gzipBytes(file) {
  return gzipSync(readFileSync(join(assetDir, file)), { level: 9 }).byteLength;
}

function kib(bytes) {
  return `${(bytes / 1024).toFixed(2)} KiB`;
}

const javascript = readdirSync(assetDir).filter((file) => file.endsWith(".js"));
const initial = javascript.filter((file) => file.startsWith("index-"));

if (initial.length !== 1) {
  throw new Error(
    `Expected one initial index chunk in ${assetDir}; found ${initial.length}.`,
  );
}

const violations = [];
const initialBytes = gzipBytes(initial[0]);
if (initialBytes > initialBudget) {
  violations.push(
    `${initial[0]} is ${kib(initialBytes)} gzip (budget ${kib(initialBudget)}).`,
  );
}

const routeChunks = javascript
  .filter((file) =>
    [...routePrefixes].some((prefix) => file.startsWith(`${prefix}-`)),
  )
  .map((file) => ({ file, bytes: gzipBytes(file) }))
  .sort((left, right) => right.bytes - left.bytes);

for (const chunk of routeChunks) {
  if (chunk.bytes > routeBudget) {
    violations.push(
      `${chunk.file} is ${kib(chunk.bytes)} gzip (budget ${kib(routeBudget)}).`,
    );
  }
}

console.log(
  `Initial JavaScript: ${kib(initialBytes)} / ${kib(initialBudget)} gzip`,
);
console.log(
  `Largest route chunk: ${routeChunks[0]?.file ?? "none"} ` +
    `(${kib(routeChunks[0]?.bytes ?? 0)} / ${kib(routeBudget)} gzip)`,
);

if (violations.length > 0) {
  throw new Error(`Bundle budget exceeded:\n- ${violations.join("\n- ")}`);
}
