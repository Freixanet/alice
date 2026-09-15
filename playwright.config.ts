import { defineConfig, devices } from "@playwright/test";
import { resolve } from "node:path";

const port = Number(process.env.ALICE_E2E_PORT ?? 8091);
if (!Number.isInteger(port) || port < 1024 || port > 65535)
  throw new Error("ALICE_E2E_PORT must be an integer between 1024 and 65535.");
const baseURL = `http://127.0.0.1:${port}`;
const hermesFixture = resolve("tests/fixtures/hermes-empty");

export default defineConfig({
  testDir: "./tests/e2e",
  snapshotPathTemplate:
    "{testDir}/{testFilePath}-snapshots/{arg}-{projectName}{ext}",
  fullyParallel: true,
  workers: 4,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? [["html", { open: "never" }], ["github"]] : "list",
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    navigationTimeout: 20_000,
  },
  webServer: {
    command: `node scripts/with-app-env.mjs vite dev --host 127.0.0.1 --port ${port} --strictPort`,
    url: baseURL,
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      ...process.env,
      ALICE_PGLITE_MEMORY: "1",
      HERMES_HOME: hermesFixture,
      VITE_AUTH_ENABLED: "false",
    },
  },
  projects: [
    {
      name: "chromium",
      testIgnore: /visual\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        ...(process.env.CI ? {} : { channel: "chrome" }),
      },
    },
    {
      name: "firefox",
      testIgnore: /visual\.spec\.ts/,
      use: { ...devices["Desktop Firefox"] },
    },
    {
      name: "webkit",
      testIgnore: /visual\.spec\.ts/,
      use: { ...devices["Desktop Safari"] },
    },
    {
      name: "mobile-webkit",
      testIgnore: /visual\.spec\.ts/,
      use: { ...devices["iPhone 13"], viewport: { width: 390, height: 844 } },
    },
    {
      name: "visual-chromium",
      testMatch: /visual\.spec\.ts/,
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
