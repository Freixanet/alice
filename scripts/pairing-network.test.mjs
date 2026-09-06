import { describe, expect, it } from "vitest";

import {
  advertisedHost,
  claimOriginAllowed,
  isLoopback,
  isTailnet,
  normalizedRemote,
} from "./pairing-network.mjs";

describe("pairing network boundary", () => {
  it("normalizes IPv4-mapped socket addresses", () => {
    expect(normalizedRemote("::ffff:100.64.1.2")).toBe("100.64.1.2");
    expect(normalizedRemote("::FFFF:100.64.1.2")).toBe("100.64.1.2");
  });

  it("accepts loopback and only the Tailscale IPv4 CGNAT range", () => {
    expect(isLoopback("127.0.0.1")).toBe(true);
    expect(isLoopback("::1")).toBe(true);
    expect(isTailnet("100.64.0.1")).toBe(true);
    expect(isTailnet("100.127.255.254")).toBe(true);
    expect(isTailnet("::ffff:100.100.10.20")).toBe(true);

    expect(isTailnet("100.63.255.255")).toBe(false);
    expect(isTailnet("100.128.0.1")).toBe(false);
    expect(isTailnet("100.64.0.999")).toBe(false);
    expect(isTailnet("192.168.1.10")).toBe(false);
  });

  it("never expands claim access merely because an address is private", () => {
    for (const address of [
      "10.0.0.2",
      "172.16.0.2",
      "192.168.1.2",
      "8.8.8.8",
      "2001:db8::1",
    ]) {
      expect(claimOriginAllowed(address)).toBe(false);
    }
    expect(claimOriginAllowed("127.0.0.1")).toBe(true);
    expect(claimOriginAllowed("100.90.1.2")).toBe(true);
  });

  it("accepts a plain IPv4 or hostname and rejects URL-shaped input", () => {
    expect(advertisedHost("100.67.213.42")).toBe("100.67.213.42");
    expect(advertisedHost("alice-mac.tailnet.ts.net")).toBe(
      "alice-mac.tailnet.ts.net",
    );
    expect(advertisedHost("Alice-Mac.Example")).toBe("Alice-Mac.Example");

    for (const invalid of [
      "",
      "http://100.67.213.42",
      "100.67.213.42:8642",
      "host/path",
      "two words",
      "::1",
    ]) {
      expect(advertisedHost(invalid)).toBeNull();
    }
  });
});
