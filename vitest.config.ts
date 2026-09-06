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
    include: [
      "src/**/*.test.{ts,tsx}",
      // The pairing helper's protocol logic ships as a script (docs/pairing.md),
      // but it carries secrets, so it gets the same pinned-down tests.
      "scripts/**/*.test.mjs",
    ],
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
        // Ratchet the measured baseline. These only move upward as the
        // domain-by-domain reconstruction adds tests.
        statements: 24,
        branches: 66,
        functions: 63,
        lines: 24,
      },
    },
  },
});
