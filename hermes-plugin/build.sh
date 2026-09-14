#!/bin/zsh
# Rebuilds dashboard/dist/index.js, the Alice tab's single-file bundle.
#
# React and the UI kit come from the dashboard's Plugin SDK at runtime; only the QR
# encoder (qrcode@1.5.4, MIT) is bundled. Install it once anywhere and point at it:
#
#   npm install --prefix /some/dir qrcode@1.5.4
#   QR_NODE_MODULES=/some/dir/node_modules hermes-plugin/build.sh
#
# Writes dist/THIRD_PARTY_LICENSES.txt for every package that ends up in the bundle.
set -euo pipefail

here=${0:A:h}
# Not `modules`: zsh reserves that name.
qr_modules=${QR_NODE_MODULES:?set QR_NODE_MODULES to a node_modules directory containing qrcode@1.5.4}
esbuild=${ESBUILD:-$here/../node_modules/.bin/esbuild}
meta=$(mktemp -t alice-plugin-meta)

NODE_PATH=$qr_modules "$esbuild" "$here/dashboard/src/index.js" \
  --bundle --format=iife --platform=browser --target=es2019 --minify \
  --legal-comments=eof --metafile="$meta" \
  --outfile="$here/dashboard/dist/index.js"

node - "$meta" "$qr_modules" "$here/dashboard/dist/THIRD_PARTY_LICENSES.txt" <<'EOF'
const fs = require("fs");
const path = require("path");
const [meta, modules, out] = process.argv.slice(2);
const inputs = Object.keys(JSON.parse(fs.readFileSync(meta, "utf8")).inputs);
const packages = new Set();
for (const input of inputs) {
  const match = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)/);
  if (match) packages.add(match[1]);
}
const sections = [...packages].sort().map((name) => {
  const dir = path.join(modules, name);
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const licenseFile = fs.readdirSync(dir).find((file) => /^licen[cs]e/i.test(file));
  const text = licenseFile ? fs.readFileSync(path.join(dir, licenseFile), "utf8").trim() : `License: ${manifest.license}`;
  return `${manifest.name}@${manifest.version} (${manifest.license})\n\n${text}`;
});
fs.writeFileSync(out, `Third-party code bundled in dist/index.js\n\n${sections.join("\n\n" + "-".repeat(72) + "\n\n")}\n`);
console.log(`bundled packages: ${[...packages].sort().join(", ")}`);
EOF
rm -f "$meta"
