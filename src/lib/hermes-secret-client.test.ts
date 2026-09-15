// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { setCockpitIdentity } from "./auth/cockpit-user";
import {
  getDeviceSessionKey,
  setDeviceSessionKey,
  forgetHermesSecret,
} from "./hermes-secret-client";

describe("device Hermes session key", () => {
  beforeEach(() => {
    sessionStorage.clear();
    setCockpitIdentity({ id: null, owner: false });
    setDeviceSessionKey(null);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("connects and forgets server credentials even when storage is blocked", async () => {
    setCockpitIdentity({ id: "alice-user", owner: false });
    for (const method of ["getItem", "setItem", "removeItem"] as const) {
      vi.spyOn(Storage.prototype, method).mockImplementation(() => {
        throw new DOMException("Storage blocked", "SecurityError");
      });
    }
    const fetcher = vi.fn().mockResolvedValue(new Response("{}"));
    vi.stubGlobal("fetch", fetcher);
    expect(() => setDeviceSessionKey("device-secret")).not.toThrow();
    expect(getDeviceSessionKey()).toBe("device-secret");
    await forgetHermesSecret();
    expect(getDeviceSessionKey()).toBeNull();
    expect(fetcher).toHaveBeenCalledWith(
      "/api/hermes",
      expect.objectContaining({ body: JSON.stringify({ action: "forget" }) }),
    );
  });

  it("survives reload semantics for the same account only", () => {
    setCockpitIdentity({ id: "alice-user", owner: false });
    setDeviceSessionKey("device-secret");
    expect(getDeviceSessionKey()).toBe("device-secret");

    setCockpitIdentity({ id: "other-user", owner: false });
    expect(getDeviceSessionKey()).toBeNull();
  });

  it("discards unscoped legacy values", () => {
    setCockpitIdentity({ id: "alice-user", owner: false });
    sessionStorage.setItem("alice-device-hermes-key", "legacy-secret");
    expect(getDeviceSessionKey()).toBeNull();
    expect(sessionStorage.getItem("alice-device-hermes-key")).toBeNull();
  });
});
