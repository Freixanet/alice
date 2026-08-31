import { afterEach, describe, expect, it, vi } from "vitest";
import {
  gatewayRestoreDelay,
  readHermesGateStatus,
  savedGatewayFromStatus,
} from "./hermes-connection";

afterEach(() => vi.unstubAllGlobals());

describe("Hermes connection recovery", () => {
  it("reads only a valid saved connection from the account-scoped status", async () => {
    const request = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          owner: 1,
          local: false,
          hasKey: true,
          url: "https://hermes.example",
          place: "device",
          key: "must-not-be-read",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
    vi.stubGlobal("fetch", request);

    const status = await readHermesGateStatus();
    expect(savedGatewayFromStatus(status)).toEqual({
      url: "https://hermes.example",
      place: "device",
    });
    expect(status).not.toHaveProperty("key");
    expect(request).toHaveBeenCalledWith(
      "/api/hermes",
      expect.objectContaining({ cache: "no-store" }),
    );
  });

  it("refuses partial status and caps retry backoff", () => {
    expect(
      savedGatewayFromStatus({
        owner: false,
        local: false,
        hasKey: true,
        url: "https://hermes.example",
      }),
    ).toBeUndefined();
    expect(gatewayRestoreDelay(0)).toBe(1_000);
    expect(gatewayRestoreDelay(2)).toBe(4_000);
    expect(gatewayRestoreDelay(99)).toBe(15_000);
    expect(gatewayRestoreDelay(Number.NaN)).toBe(1_000);
  });
});
