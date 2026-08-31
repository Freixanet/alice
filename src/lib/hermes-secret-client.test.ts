// @vitest-environment jsdom

import { beforeEach, describe, expect, it } from "vitest";
import { setCockpitIdentity } from "./auth/cockpit-user";
import {
  getDeviceSessionKey,
  setDeviceSessionKey,
} from "./hermes-secret-client";

describe("device Hermes session key", () => {
  beforeEach(() => {
    sessionStorage.clear();
    setCockpitIdentity({ id: null, owner: false });
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
