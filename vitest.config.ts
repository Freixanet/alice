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
    // Six suites are property-based (fast-check). Their runtime varies with the
    // cases generated, and v8 coverage instrumentation on a loaded machine has
    // pushed one past the 5s default — a red CI run that says nothing about the
    // code. Give them room; a genuine hang still fails, just later.
    testTimeout: 30_000,
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary", "lcov"],
      include: ["src/lib/**/*.{ts,tsx}"],
      exclude: ["src/lib/**/*.server.ts", "src/lib/auth/**"],
      thresholds: {
        // Ratchet the measured baseline. Vitest 4 switched V8 coverage to
        // stricter AST-aware remapping, so the v3 branch/function percentages
        // are not comparable. These floors match the first v4 baseline and
        // should only move upward from here.
        statements: 46,
        branches: 40,
        functions: 52,
        lines: 48,
      },
    },
  },
});
