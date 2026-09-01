import { access } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const entry = resolve(".vercel/output/functions/__server.func/index.mjs");

await access(entry);
await import(pathToFileURL(entry).href);

console.log("Server bundle initialized successfully.");
