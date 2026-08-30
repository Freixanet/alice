import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.{ts,tsx}"],
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary", "lcov"],
      include: ["src/lib/**/*.{ts,tsx}"],
      exclude: ["src/lib/**/*.server.ts", "src/lib/auth/**"],
      thresholds: {
        // Ratchet the measured baseline. These only move upward as the
        // domain-by-domain reconstruction adds tests.
        statements: 20,
        branches: 65,
        functions: 60,
        lines: 20,
      },
    },
  },
});
