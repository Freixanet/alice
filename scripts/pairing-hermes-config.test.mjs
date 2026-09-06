import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  configActiveProfile,
  launchdGatewayProfiles,
  parseEnvFile,
  readDashboardAuth,
  readProfileGateway,
} from "./pairing-hermes-config.mjs";

const tempDirs = [];
function tempHome() {
  const dir = mkdtempSync(path.join(tmpdir(), "alice-pairing-"));
  tempDirs.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of tempDirs.splice(0))
    rmSync(dir, { recursive: true, force: true });
});

describe("parseEnvFile", () => {
  it("reads the dotenv subset Hermes writes", () => {
    expect(
      parseEnvFile(
        [
          "# comment",
          "",
          "export PLAIN=value",
          "QUOTED='single words'",
          'DOUBLE="double \\"words\\""',
          "EQ=a=b=c",
          "NOVALUE",
          "=empty-key",
        ].join("\n"),
      ),
    ).toEqual({
      PLAIN: "value",
      QUOTED: "single words",
      DOUBLE: 'double \\"words\\"',
      EQ: "a=b=c",
    });
  });
});

describe("launchdGatewayProfiles", () => {
  it("reads profile names from the gateway agents, skipping disabled ones", () => {
    const dir = tempHome();
    for (const name of [
      "ai.hermes.gateway-radar-ia.plist",
      "ai.hermes.gateway-researcher.plist",
      "ai.hermes.gateway.plist.disabled-20260806",
      "com.other.plist",
    ]) {
      writeFileSync(path.join(dir, name), "");
    }
    expect(launchdGatewayProfiles(dir)).toEqual(["radar-ia", "researcher"]);
  });

  it("survives a missing directory", () => {
    expect(launchdGatewayProfiles(path.join(tempHome(), "nope"))).toEqual([]);
  });
});

describe("configActiveProfile", () => {
  it("reads active_profile from config.yaml", () => {
    const home = tempHome();
    writeFileSync(
      path.join(home, "config.yaml"),
      "model:\n  primary: nous\nactive_profile: radar-ia\n",
    );
    expect(configActiveProfile(home)).toBe("radar-ia");
  });

  it("returns null without a config or a key", () => {
    expect(configActiveProfile(tempHome())).toBeNull();
  });
});

describe("readProfileGateway", () => {
  it("reads the key and port from the profile env", () => {
    const home = tempHome();
    mkdirSync(path.join(home, "profiles", "radar-ia"), { recursive: true });
    writeFileSync(
      path.join(home, "profiles", "radar-ia", ".env"),
      "API_SERVER_PORT=8642\nAPI_SERVER_KEY=0123456789abcdef\n",
    );
    expect(
      readProfileGateway({ hermesHome: home, profile: "radar-ia" }),
    ).toEqual({
      key: "0123456789abcdef",
      port: 8642,
    });
  });

  it("defaults the port and refuses a profile without a key", () => {
    const home = tempHome();
    mkdirSync(path.join(home, "profiles", "empty"), { recursive: true });
    writeFileSync(path.join(home, "profiles", "empty", ".env"), "OTHER=1\n");
    expect(
      readProfileGateway({ hermesHome: home, profile: "empty" }),
    ).toBeNull();
    expect(
      readProfileGateway({ hermesHome: home, profile: "missing" }),
    ).toBeNull();
  });
});

describe("readDashboardAuth", () => {
  it("reads username and password from the home env", () => {
    const home = tempHome();
    writeFileSync(
      path.join(home, ".env"),
      "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=alice\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD=secret\n",
    );
    expect(readDashboardAuth(home)).toEqual({
      username: "alice",
      password: "secret",
    });
  });

  it("treats a half-configured dashboard as absent", () => {
    const home = tempHome();
    writeFileSync(
      path.join(home, ".env"),
      "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=alice\n",
    );
    expect(readDashboardAuth(home)).toBeNull();
    expect(readDashboardAuth(path.join(tempHome(), "nope"))).toBeNull();
  });
});
