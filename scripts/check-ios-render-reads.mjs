// Keeps iOS screens from depending on every chat at once.
//
// Under Observation a view is redrawn whenever anything it read changes. A
// screen that reads `store.conversations` — directly, or through
// `activeConversation`, which walks it — is redrawn by every
// token streamed into any chat, every background sync and every timestamp.
// That is how the drawer came to freeze the app for seconds at a time on the
// person's iPhone (2026-09-21).
//
// Screens read the chat on screen through `activeChat` / `shownConversation`
// / `conversation(_:)`. A screen that truly needs every chat (search, the
// Agents list) says why on the line, or up to two lines above, with
// `// reads every chat: <reason>`.
import { readdir, readFile } from "node:fs/promises";
import { extname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const featuresRoot = fileURLToPath(
  new URL("../ios/Alice/Features/", import.meta.url),
);
const repoRoot = fileURLToPath(new URL("../", import.meta.url));

const forbidden = [
  [
    "store.activeConversation",
    /\bstore\.activeConversation\b/,
    "use store.activeChat or store.shownConversation",
  ],
];
const justified = [["store.conversations", /\bstore\.conversations\b/]];
const justification = /\/\/\s*reads every chat:\s*\S/;

async function collect(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await collect(path)));
    else if (extname(entry.name) === ".swift") files.push(path);
  }
  return files;
}

const failures = [];
for (const file of await collect(featuresRoot)) {
  const lines = (await readFile(file, "utf8")).split("\n");
  lines.forEach((line, index) => {
    const code = line.replace(/\/\/.*$/, "");
    const where = `${relative(repoRoot, file)}:${index + 1}`;
    for (const [name, pattern, advice] of forbidden) {
      if (pattern.test(code))
        failures.push(`${where} reads ${name} (${advice})`);
    }
    for (const [name, pattern] of justified) {
      if (!pattern.test(code)) continue;
      const context = lines.slice(Math.max(0, index - 2), index + 1).join("\n");
      if (!justification.test(context)) {
        failures.push(
          `${where} reads ${name} without "// reads every chat: <reason>"`,
        );
      }
    }
  });
}

if (failures.length > 0) {
  console.error(
    "iOS screens that depend on every chat:\n" +
      failures.map((f) => `  ${f}`).join("\n"),
  );
  process.exit(1);
}
console.log("iOS render reads: ok");
