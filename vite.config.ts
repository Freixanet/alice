import { readdirSync } from "node:fs";
import { join } from "node:path";
import type { Plugin } from "vite";
import { defineConfig } from "vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import viteReact from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { nitro } from "nitro/vite";
// @ts-expect-error JS plugin alongside the TS vite config
import { pwaPlugin } from "./scripts/pwa-plugin.mjs";
// @ts-expect-error JS plugin alongside the TS vite config
import { appEnvPlugin } from "./scripts/app-env-plugin.mjs";
import { isMigrationFile } from "./scripts/migration-plan.mjs";

function hasGlobbedMigrations(root: string): boolean {
  try {
    return readdirSync(join(root, "migrations")).some(isMigrationFile);
  } catch {
    return false;
  }
}

function pgliteBootstrapPlugin(): Plugin {
  let closeDb: (() => Promise<void>) | undefined;

  return {
    name: "app-builder:pglite-bootstrap",
    apply: "serve",
    async configureServer(server) {
      if (!hasGlobbedMigrations(server.config.root)) return;
      try {
        const mod = (await server.ssrLoadModule("/src/lib/db.ts")) as {
          ensureDbReady?: () => Promise<void>;
          closeDb?: () => Promise<void>;
        };
        if (typeof mod.ensureDbReady === "function") {
          await mod.ensureDbReady();
        }
        if (typeof mod.closeDb === "function") {
          closeDb = mod.closeDb;
        }
      } catch (err) {
        console.error("[app-builder] DB bootstrap failed:", err);
        throw err;
      }
    },
    async closeBundle() {
      const close = closeDb;
      closeDb = undefined;
      if (!close) return;
      try {
        await close();
      } catch (err) {
        console.error("[app-builder] DB shutdown failed:", err);
      }
    },
  };
}

export default defineConfig(({ command, isPreview }) => ({
  server: {
    host: "0.0.0.0",
    port: 8080,
    strictPort: true,
    // Transform the entry route before the first browser requests it. Cold
    // on-demand transforms otherwise serialize the initial hydration graph.
    warmup: {
      clientFiles: [
        "./src/routes/__root.tsx",
        "./src/routes/_app.tsx",
        "./src/routes/_app/index.tsx",
      ],
    },
    watch: {
      ignored: [
        "**/coverage/**",
        "**/test-results/**",
        "**/playwright-report/**",
      ],
    },
    // MagicDNS / Tailscale Serve send Host: *.ts.net. Vite 6+ blocks unknown
    // hosts unless listed (DNS rebinding guard).
    allowedHosts: [".ts.net", "localhost", "127.0.0.1"],
  },
  preview: {
    host: "127.0.0.1",
    port: 8081,
    strictPort: true,
  },
  resolve: { tsconfigPaths: true },
  plugins: [
    pgliteBootstrapPlugin(),
    appEnvPlugin(),
    pwaPlugin(),
    tailwindcss(),
    tanstackStart(),
    ...(command === "build" || isPreview
      ? [
          nitro({
            preset: "vercel",
            serverDir: "./server",
          }),
        ]
      : []),
    viteReact(),
  ],
}));
