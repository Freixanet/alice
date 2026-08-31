import { readdir, readFile } from "node:fs/promises";
import { extname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const sourceRoot = fileURLToPath(new URL("../src/", import.meta.url));
const checkedExtensions = new Set([".css", ".ts", ".tsx"]);
const circleAllowlist = new Set([
  "components/catalog-page.tsx",
  "components/chat.tsx",
  "components/hermes-profiles-settings.tsx",
  "components/settings-panel.tsx",
  "components/shell.tsx",
  "components/ui/badge.tsx",
  "components/ui/scroll-area.tsx",
  "components/ui/switch.test.tsx",
  "components/ui/switch.tsx",
  "lib/auth/gates.tsx",
  "routes/_app/memory.tsx",
  "styles.css",
]);

const forbidden = [
  ["!important", /!important/],
  ["box shadow", /\bbox-shadow\b|\bshadow-[\w[]/],
  ["gradient", /\b(?:linear|radial|conic)-gradient\b|\bbg-gradient-/],
  ["backdrop filter", /\bbackdrop-(?:filter|blur)\b/],
];

async function collect(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await collect(path)));
    else if (checkedExtensions.has(extname(entry.name))) files.push(path);
  }
  return files;
}

const failures = [];
const files = await collect(sourceRoot);
for (const file of files) {
  const contents = await readFile(file, "utf8");
  const name = relative(sourceRoot, file);
  for (const [label, pattern] of forbidden) {
    if (pattern.test(contents)) failures.push(`${name}: contains ${label}`);
  }
  if (contents.includes("rounded-full") && !circleAllowlist.has(name)) {
    failures.push(`${name}: uses rounded-full outside an approved exception`);
  }
}

const styles = await readFile(
  new URL("../src/styles.css", import.meta.url),
  "utf8",
);
for (const token of ["sm", "md", "lg", "xl", "2xl"]) {
  if (!styles.includes(`--radius-${token}: 0.5rem;`)) {
    failures.push(`styles.css: --radius-${token} must remain 8px`);
  }
}

const primitives = {
  "button.tsx": ["rounded-md", "border border-border"],
  "dialog.tsx": ["rounded-none", "md:rounded-xl", "md:border md:border-border"],
  "dropdown-menu.tsx": ["rounded-lg", "border border-border"],
  "input.tsx": ["rounded-md", "border border-border"],
};
for (const [file, invariants] of Object.entries(primitives)) {
  const contents = await readFile(
    new URL(`../src/components/ui/${file}`, import.meta.url),
    "utf8",
  );
  for (const invariant of invariants) {
    if (!contents.includes(invariant)) {
      failures.push(`components/ui/${file}: missing ${invariant}`);
    }
  }
}

if (failures.length > 0) {
  console.error("Alice design-system invariants failed:\n");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log(
    `Alice design-system invariants passed (${files.length} source files).`,
  );
}
