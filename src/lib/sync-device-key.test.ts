import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { generateMasterSecret } from "./sync-crypto";
import {
  forgetMasterSecretForDevice,
  loadMasterSecretForDevice,
  saveMasterSecretForDevice,
} from "./sync-device-key";

describe("device-wrapped sync master secret", () => {
  it("restores only the right account and can be forgotten", async () => {
    const userId = crypto.randomUUID();
    const master = generateMasterSecret();
    await saveMasterSecretForDevice(userId, master);
    expect(await loadMasterSecretForDevice(userId)).toEqual(master);
    expect(await loadMasterSecretForDevice(`${userId}-other`)).toBeNull();
    await forgetMasterSecretForDevice(userId);
    expect(await loadMasterSecretForDevice(userId)).toBeNull();
  });
});
