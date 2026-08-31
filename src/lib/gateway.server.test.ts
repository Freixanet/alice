import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  managementBases,
  matchStoredEndpoint,
  modelsFromEndpoints,
  openGate,
  readOrCreateDevelopmentGateKey,
  sealGate,
  upsertStoredEndpoint,
} from "./gateway.server";

afterEach(() => vi.unstubAllEnvs());

describe("Hermes credential encryption", () => {
  it("versions and authenticates sealed credentials", () => {
    vi.stubEnv("HERMES_COOKIE_KEYS", "current:test-secret-current");
    const token = sealGate({
      k: "hermes-key",
      u: "https://hermes.example",
      p: "cloud",
      uid: "user-1",
    });
    expect(token).toMatch(/^v1\.current\./);
    expect(openGate(token)).toEqual({
      k: "hermes-key",
      u: "https://hermes.example",
      p: "cloud",
      uid: "user-1",
    });
    const [version, keyId, payload = ""] = token.split(".");
    const tampered = `${version}.${keyId}.${
      payload[0] === "A" ? "B" : "A"
    }${payload.slice(1)}`;
    expect(openGate(tampered)).toBeNull();
  });

  it("can decrypt with a retained rotation key", () => {
    vi.stubEnv("HERMES_COOKIE_KEYS", "old:test-secret-old");
    const oldToken = sealGate({
      k: "hermes-key",
      u: "https://hermes.example",
      p: "cloud",
    });
    vi.stubEnv(
      "HERMES_COOKIE_KEYS",
      "current:test-secret-current,old:test-secret-old",
    );
    expect(openGate(oldToken)?.k).toBe("hermes-key");
  });

  it("fails closed in production without a persistent key", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("HERMES_COOKIE_KEYS", "");
    vi.stubEnv("HERMES_COOKIE_SECRET", "");
    vi.stubEnv("BETTER_AUTH_SECRET", "");
    expect(() =>
      sealGate({ k: "key", u: "https://hermes.example", p: "cloud" }),
    ).toThrow("Persistent Hermes credential encryption key is missing");
  });

  it("persists the development key across server-module lifetimes", () => {
    const directory = mkdtempSync(join(tmpdir(), "alice-gate-key-"));
    try {
      const path = join(directory, "hermes.key");
      const first = readOrCreateDevelopmentGateKey(path);
      expect(readFileSync(path, "utf8").trim()).toHaveLength(43);

      const otherPath = join(directory, "other.key");
      writeFileSync(otherPath, "x".repeat(48), { mode: 0o600 });
      readOrCreateDevelopmentGateKey(otherPath);

      expect(readOrCreateDevelopmentGateKey(path)).toEqual(first);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});

describe("stored custom endpoint isolation", () => {
  const defaultEndpoint = {
    n: "Default local",
    s: "local",
    u: "https://default.example/v1",
    k: "key-default",
    m: "model-default",
  };
  const researchEndpoint = {
    n: "Research local",
    s: "local",
    u: "https://research.example/v1",
    k: "key-research",
    m: "model-research",
    p: "research",
  };

  it("keeps equal provider slugs separate across profiles", () => {
    const endpoints = upsertStoredEndpoint(
      upsertStoredEndpoint([], defaultEndpoint),
      researchEndpoint,
    );
    expect(endpoints).toHaveLength(2);
    expect(modelsFromEndpoints(endpoints, "default")).toMatchObject([
      { id: "model-default", provider: "local" },
    ]);
    expect(modelsFromEndpoints(endpoints, "research")).toMatchObject([
      { id: "model-research", provider: "local" },
    ]);
  });

  it("never routes a stored endpoint from another profile", () => {
    expect(
      matchStoredEndpoint(
        [defaultEndpoint, researchEndpoint],
        "model-research",
        "local",
        "default",
      ),
    ).toEqual(defaultEndpoint);
    expect(
      matchStoredEndpoint(
        [defaultEndpoint, researchEndpoint],
        "model-research",
        "local",
        "research",
      ),
    ).toEqual(researchEndpoint);
  });
});

describe("Hermes management routing", () => {
  it("never probes the local dashboard port behind default HTTPS", () => {
    expect(
      managementBases("https://hermes.tailnet-name.ts.net", "mac"),
    ).toEqual(["https://hermes.tailnet-name.ts.net"]);
  });

  it("retains the dashboard fallback for a local HTTP gateway", () => {
    expect(managementBases("http://127.0.0.1:8644", "mac")).toEqual([
      "http://127.0.0.1:8644",
      "http://127.0.0.1:9119",
    ]);
  });
});
