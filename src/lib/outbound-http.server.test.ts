import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  isBlockedNetworkAddress,
  resolvePinnedTarget,
  UnsafeOutboundUrlError,
} from "./outbound-http.server";

describe("outbound network isolation", () => {
  it.each([
    "0.0.0.0",
    "10.2.3.4",
    "100.64.0.1",
    "127.0.0.1",
    "169.254.169.254",
    "172.31.255.255",
    "192.168.1.1",
    "198.18.0.1",
    "224.0.0.1",
    "255.255.255.255",
    "::",
    "::1",
    "fc00::1",
    "fd00::1",
    "fe80::1",
    "ff02::1",
    "::ffff:127.0.0.1",
    "::ffff:7f00:1",
    "::ffff:a00:1",
    "64:ff9b:1::1",
    "100::1",
    "2001:db8::1",
    "2002::1",
  ])("blocks reserved address %s", (address) => {
    expect(isBlockedNetworkAddress(address)).toBe(true);
  });

  it.each(["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"])(
    "accepts public address %s",
    (address) => {
      expect(isBlockedNetworkAddress(address)).toBe(false);
    },
  );

  it("rejects the whole hostname when any DNS answer is private", async () => {
    await expect(
      resolvePinnedTarget("https://hermes.example/v1/models", {
        lookup: async () => [
          { address: "203.0.114.4", family: 4 },
          { address: "127.0.0.1", family: 4 },
        ],
      }),
    ).rejects.toEqual(new UnsafeOutboundUrlError("private"));
  });

  it("returns the validated address that must be used for the socket", async () => {
    const target = await resolvePinnedTarget("https://hermes.example:9443/a", {
      lookup: async (hostname) => {
        expect(hostname).toBe("hermes.example");
        return [{ address: "203.0.114.8", family: 4 }];
      },
    });
    expect(target).toMatchObject({
      address: "203.0.114.8",
      family: 4,
    });
    expect(target.url.origin).toBe("https://hermes.example:9443");
  });

  it.each([
    "file:///etc/passwd",
    "ftp://hermes.example",
    "https://user:password@hermes.example",
  ])("rejects non-HTTP or credential-bearing URL %s", async (url) => {
    await expect(resolvePinnedTarget(url)).rejects.toMatchObject({
      reason: "invalid",
    });
  });

  it("blocks every address in the private 10/8 range", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0, max: 255 }),
        fc.integer({ min: 0, max: 255 }),
        fc.integer({ min: 0, max: 255 }),
        (b, c, d) => isBlockedNetworkAddress(`10.${b}.${c}.${d}`),
      ),
      { numRuns: 10_000 },
    );
  });
});
