/**
 * Single source of truth for Alice's head chrome (PWA manifest, share-card
 * meta), shared by the Vite plugin. Plain ESM so `node --test` and the Nitro
 * bundler can both consume it.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_APP_NAME = "Alice";
export const SITE_REL_PATH = "src/lib/og/site.json";
export const PWA_BASE = "/__pwa";

const SHARE_META_KEYS = new Set([
  "og:title",
  "og:description",
  "og:image",
  "og:image:width",
  "og:image:height",
  "og:type",
  "og:url",
  "og:site_name",
  "twitter:card",
  "twitter:title",
  "twitter:image",
  "twitter:description",
]);

export function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Hostname suitable for absolute og:image URLs. */
export function publicAppHost(hostHeader) {
  const host = String(hostHeader ?? "")
    .split(",")[0]
    .trim()
    .split(":")[0]
    .toLowerCase();
  if (!host || !/^[a-z0-9.-]+$/.test(host) || !host.includes(".")) return "";
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(host)) return "";
  return host;
}

/** Paths that can carry an app document (vs assets / API / internals). */
export function isDocumentPath(pathname) {
  const path = String(pathname ?? "");
  return (
    !path.startsWith(`${PWA_BASE}/`) &&
    !path.startsWith("/api/") &&
    !path.startsWith("/@") &&
    !path.startsWith("/node_modules") &&
    !/\.[a-z0-9]+$/i.test(path)
  );
}

export function acceptsHtml(accept) {
  const value = String(accept ?? "");
  return value === "" || value.includes("text/html") || value.includes("*/*");
}

function insertBeforeHeadClose(html, snippet) {
  if (/<\/head>/i.test(html))
    return html.replace(/<\/head>/i, `${snippet}</head>`);
  return insertAfterHeadOpen(html, snippet);
}

export function renderWebManifest() {
  return JSON.stringify(
    {
      name: DEFAULT_APP_NAME,
      short_name: DEFAULT_APP_NAME,
      id: "/",
      start_url: "/",
      scope: "/",
      display: "standalone",
      background_color: "#000000",
      theme_color: "#000000",
      icons: [
        {
          src: "/favicon.svg",
          sizes: "any",
          type: "image/svg+xml",
        },
        {
          src: "/icon-180.png",
          sizes: "180x180",
          type: "image/png",
        },
      ],
    },
    null,
    2,
  );
}

export function pwaHeadTags(appName = DEFAULT_APP_NAME) {
  return [
    // Standalone display comes from the manifest ("display": "standalone");
    // the legacy *-web-app-capable metas it replaces are deliberately absent.
    [
      "manifest",
      `<link rel="manifest" href="${PWA_BASE}/manifest.webmanifest">`,
    ],
    ["apple-touch-icon", '<link rel="apple-touch-icon" href="/icon-180.png">'],
    [
      "apple-mobile-web-app-title",
      `<meta name="apple-mobile-web-app-title" content="${escapeHtml(appName)}">`,
    ],
    [
      "apple-mobile-web-app-status-bar-style",
      '<meta name="apple-mobile-web-app-status-bar-style" content="black">',
    ],
    ["theme-color", '<meta name="theme-color" content="#000000">'],
  ];
}

export function readSite(cwd = process.cwd()) {
  try {
    const raw = readFileSync(join(cwd, SITE_REL_PATH), "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch {
    return {};
  }
}

function customOgAssetPath(cwd = process.cwd()) {
  if (existsSync(join(cwd, "public/og.png"))) return "/og.png";
  if (existsSync(join(cwd, "public/og.jpg"))) return "/og.jpg";
  return "";
}

/**
 * Static share-card tags. og:image is emitted only for a real asset under
 * `public/` — there is no remote card service to fall back to.
 */
export function ogHeadTags({
  host = "",
  site = {},
  documentTitle = "",
  cwd = process.cwd(),
} = {}) {
  const title =
    String(site.title ?? "").trim() ||
    String(documentTitle ?? "").trim() ||
    DEFAULT_APP_NAME;
  const publicHost = publicAppHost(host);
  const tags = [
    `<meta name="twitter:card" content="summary_large_image">`,
    `<meta property="og:title" content="${escapeHtml(title)}">`,
  ];
  const description = String(site.description ?? "").trim();
  if (description) {
    tags.push(
      `<meta property="og:description" content="${escapeHtml(description)}">`,
    );
  }
  const asset = customOgAssetPath(cwd);
  if (publicHost && asset) {
    tags.push(
      `<meta property="og:image" content="${escapeHtml(`https://${publicHost}${asset}`)}">`,
    );
    tags.push(`<meta property="og:image:width" content="1200">`);
    tags.push(`<meta property="og:image:height" content="630">`);
  }
  return tags;
}

export function stripShareMetaTags(html) {
  return String(html).replace(/<meta\b[^>]*>/gi, (tag) => {
    const attrs = [
      ...tag.matchAll(/\b(?:property|name)\s*=\s*["']([^"']+)["']/gi),
    ];
    for (const match of attrs) {
      if (SHARE_META_KEYS.has(String(match[1]).toLowerCase())) return "";
    }
    return tag;
  });
}

function insertAfterHeadOpen(html, snippet) {
  if (/<head\b[^>]*>/i.test(html)) {
    return html.replace(/<head\b[^>]*>/i, (open) => `${open}${snippet}`);
  }
  if (/<html\b[^>]*>/i.test(html)) {
    return html.replace(
      /<html\b[^>]*>/i,
      (open) => `${open}<head>${snippet}</head>`,
    );
  }
  return `<!doctype html><html><head>${snippet}</head>${html}`;
}

function titleFromDocument(html) {
  const match = String(html).match(/<title[^>]*>([^<]*)<\/title>/i);
  return match ? match[1].trim() : "";
}

export function normalizeHeadContext(ctx = {}) {
  const cwd = ctx.cwd ?? process.cwd();
  const site = ctx.site !== undefined ? ctx.site : readSite(cwd);
  const appName =
    String(site.title ?? "").trim() || ctx.appName || DEFAULT_APP_NAME;
  return {
    appName,
    host: ctx.host ?? "",
    cwd,
    site,
  };
}

export function injectPwaHead(html, ctx = {}) {
  if (typeof html !== "string") return html;
  const { site, appName, host, cwd } = normalizeHeadContext(ctx);
  const documentTitle = titleFromDocument(html);
  let next = stripShareMetaTags(html);

  const missing = pwaHeadTags(appName)
    .filter(([key]) => {
      if (key === "manifest")
        return !next.includes(`href="${PWA_BASE}/manifest.webmanifest"`);
      if (key === "apple-touch-icon")
        return !next.includes('href="/icon-180.png"');
      return !next.includes(`name="${key}"`);
    })
    .map(([, tag]) => tag);

  next = insertAfterHeadOpen(
    next,
    ogHeadTags({ host, appName, site, documentTitle, cwd }).join(""),
  );

  if (missing.length === 0) return next;
  return insertBeforeHeadClose(next, missing.join(""));
}

function findHeadClose(buf) {
  const at = buf.toString("latin1").search(/<\/head>/i);
  return at;
}

/**
 * Streaming head injector: buffers only until `</head>` (ASCII marker; never
 * appears inside a UTF-8 continuation byte), overwrites share-card metas,
 * then passes later chunks through so streaming SSR keeps streaming.
 */
export function createHeadInjector(ctx = {}) {
  const normalized = normalizeHeadContext(ctx);

  /** @type {Buffer[]} */
  let pending = [];
  let done = false;

  const apply = (html) =>
    injectPwaHead(html, {
      appName: normalized.appName,
      host: normalized.host,
      cwd: normalized.cwd,
      site: normalized.site,
    });

  return {
    /** @param {Uint8Array | string} chunk @returns {Buffer[]} chunks ready to emit */
    push(chunk) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      if (done) return [buf];
      pending.push(buf);
      const joined = Buffer.concat(pending);
      const at = findHeadClose(joined);
      if (at === -1) return [];
      done = true;
      pending = [];
      const closeLen = joined
        .toString("latin1", at)
        .match(/^<\/head>/i)[0].length;
      const head = apply(joined.subarray(0, at + closeLen).toString("utf8"));
      return [
        Buffer.concat([
          Buffer.from(head, "utf8"),
          joined.subarray(at + closeLen),
        ]),
      ];
    },
    /** @returns {Buffer[]} whatever is still buffered (no `</head>` seen) */
    flush() {
      if (done || pending.length === 0) return [];
      const rest = Buffer.concat(pending);
      pending = [];
      done = true;
      return [Buffer.from(apply(rest.toString("utf8")), "utf8")];
    },
  };
}
