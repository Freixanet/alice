/**
 * Dev/preview (Vite) half of Alice's PWA chrome: serves the app manifest and
 * injects missing PWA head tags into app documents.
 */
import {
  createHeadInjector,
  injectPwaHead,
  isDocumentPath,
  renderWebManifest,
  PWA_BASE,
} from "./pwa-shared.mjs";

function requestHost(req) {
  const forwarded = req.headers["x-forwarded-host"];
  const host = forwarded ?? req.headers.host ?? req.headers[":authority"];
  return Array.isArray(host) ? host[0] : host;
}

function servePwa(middlewares) {
  middlewares.use((req, res, next) => {
    const rawUrl = req.url ?? "";
    const pathOnly = rawUrl.split("?", 1)[0] ?? "";
    const method = (req.method ?? "GET").toUpperCase();
    if (method !== "GET") {
      next();
      return;
    }

    if (
      pathOnly === `${PWA_BASE}/manifest.webmanifest` ||
      pathOnly === `${PWA_BASE}/manifest.json`
    ) {
      const body = Buffer.from(renderWebManifest(), "utf8");
      res.statusCode = 200;
      res.setHeader("content-type", "application/manifest+json; charset=utf-8");
      res.setHeader("cache-control", "no-cache");
      res.setHeader("content-length", String(body.byteLength));
      res.end(body);
      return;
    }

    next();
  });
}

/**
 * Wrap res.write/res.end on app-document requests to inject missing PWA head
 * tags at the `</head>` boundary as chunks stream through (no full-document
 * buffering, so streaming SSR keeps its early flush). Skips anything already
 * content-encoded: under `vite preview` the compression middleware can hand
 * this wrapper gzipped bytes, which must pass through untouched.
 */
function wrapHtmlResponses(middlewares) {
  middlewares.use((req, res, next) => {
    const rawUrl = req.url ?? "";
    const pathOnly = rawUrl.split("?", 1)[0] ?? "";
    const method = (req.method ?? "GET").toUpperCase();
    const looksLikeDocument =
      method === "GET" &&
      String(req.headers.accept ?? "").includes("text/html") &&
      isDocumentPath(pathOnly);
    if (!looksLikeDocument) {
      next();
      return;
    }

    const originalWrite = res.write.bind(res);
    const originalEnd = res.end.bind(res);
    const host = requestHost(req);
    const injector = createHeadInjector({
      host,
    });
    let mode = null; // null = undecided, "inject" | "passthrough"

    const decideMode = () => {
      if (mode) return mode;
      const isHtml = String(res.getHeader("content-type") ?? "").includes(
        "text/html",
      );
      const encoded = Boolean(res.getHeader("content-encoding"));
      mode = isHtml && !encoded ? "inject" : "passthrough";
      // Streaming SSR flushes headers before the first body chunk, so the
      // header may no longer be removable — chunked responses don't carry one.
      if (mode === "inject" && !res.headersSent)
        res.removeHeader("content-length");
      return mode;
    };

    const toBuffer = (chunk, encoding) => {
      if (Buffer.isBuffer(chunk)) return chunk;
      if (typeof chunk === "string") {
        return Buffer.from(
          chunk,
          typeof encoding === "string" ? encoding : "utf8",
        );
      }
      return Buffer.from(chunk);
    };

    res.write = (chunk, encoding, cb) => {
      if (decideMode() === "passthrough")
        return originalWrite(chunk, encoding, cb);
      const done = typeof encoding === "function" ? encoding : cb;
      if (chunk) {
        for (const out of injector.push(toBuffer(chunk, encoding)))
          originalWrite(out);
      }
      if (typeof done === "function") done();
      return true;
    };

    res.end = (chunk, encoding, cb) => {
      const done = typeof encoding === "function" ? encoding : cb;
      if (decideMode() === "passthrough")
        return originalEnd(chunk, encoding, cb);
      if (chunk) {
        for (const out of injector.push(toBuffer(chunk, encoding)))
          originalWrite(out);
      }
      for (const out of injector.flush()) originalWrite(out);
      return originalEnd(undefined, undefined, done);
    };

    next();
  });
}

export function pwaPlugin() {
  return {
    name: "alice:pwa",
    transformIndexHtml(html) {
      return injectPwaHead(html, {
        host: process.env.VITE_PUBLIC_HOSTNAME ?? "",
      });
    },
    configureServer(server) {
      // Registered directly (not in a returned post-hook) so it runs BEFORE
      // TanStack Start's SSR middleware.
      servePwa(server.middlewares);
      wrapHtmlResponses(server.middlewares);
    },
    configurePreviewServer(server) {
      servePwa(server.middlewares);
      // Post-hook: preview registers compression between the direct hooks and
      // the post-hooks, and the injector must wrap AFTER compression so it
      // sees plaintext HTML (compression then compresses the injected output).
      return () => {
        wrapHtmlResponses(server.middlewares);
      };
    },
  };
}
