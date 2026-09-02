// Keeps the phone's command list identical to the web's.
//
// The composer in `ios/Alice/Features/Chat/Composer.swift` offers the same
// slash commands as the one in `src/components/chat.tsx`, but Swift cannot
// import a TypeScript module, so the list exists twice. Two copies drift:
// somebody adds a command to the web, ships it, and the phone quietly keeps
// offering yesterday's vocabulary. This fails the build instead.
//
// When it fails, regenerate the Swift list from the TypeScript one — the
// TypeScript file is the source of truth — rather than editing either by hand.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const webPath = fileURLToPath(new URL("../src/lib/slash.ts", import.meta.url));
const swiftPath = fileURLToPath(
  new URL("../ios/Alice/Features/Chat/SlashCommands.swift", import.meta.url),
);

function parseWeb(source) {
  const start = source.indexOf("SLASH_COMMANDS: SlashCommand[] = [");
  if (start === -1) throw new Error("SLASH_COMMANDS not found in slash.ts");
  const body = source.slice(start, source.indexOf("\n];", start));
  return [
    ...body.matchAll(/\{\s*cmd:\s*"([^"]+)",\s*hint:\s*"([^"]+)"\s*\}/g),
  ].map((m) => `${m[1]}\t${m[2]}`);
}

function parseSwift(source) {
  return [...source.matchAll(/SlashCommand\("([^"]+)",\s*"([^"]+)"\)/g)].map(
    (m) => `${m[1]}\t${m[2]}`,
  );
}

const [web, swift] = await Promise.all([
  readFile(webPath, "utf8").then(parseWeb),
  readFile(swiftPath, "utf8").then(parseSwift),
]);

if (web.length === 0) {
  console.error("check-slash-parity: parsed no commands from slash.ts");
  process.exit(1);
}

const problems = [];
const webSet = new Set(web);
const swiftSet = new Set(swift);
for (const entry of web) {
  if (!swiftSet.has(entry)) problems.push(`missing from iOS:  ${entry}`);
}
for (const entry of swift) {
  if (!webSet.has(entry)) problems.push(`only on iOS:       ${entry}`);
}
if (problems.length === 0 && web.join("\n") !== swift.join("\n")) {
  problems.push("same commands, different order");
}

if (problems.length > 0) {
  console.error("check-slash-parity: the two command lists disagree\n");
  for (const problem of problems) console.error(`  ${problem}`);
  console.error(
    "\nsrc/lib/slash.ts is the source of truth; regenerate the Swift list from it.",
  );
  process.exit(1);
}

console.log(`check-slash-parity: ${web.length} commands, web and iOS agree`);
