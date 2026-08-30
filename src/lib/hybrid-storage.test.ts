import { describe, expect, it } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import { createHybridStorage } from "./hybrid-storage";

class MemoryStorage implements Storage {
  private values = new Map<string, string>();
  get length() {
    return this.values.size;
  }
  clear() {
    this.values.clear();
  }
  getItem(key: string) {
    return this.values.get(key) ?? null;
  }
  key(index: number) {
    return [...this.values.keys()][index] ?? null;
  }
  removeItem(key: string) {
    this.values.delete(key);
  }
  setItem(key: string, value: string) {
    this.values.set(key, value);
  }
}

function envelope(title: string) {
  return JSON.stringify({
    version: 7,
    state: {
      theme: "light",
      conversations: [{ id: "c1", title, messages: [] }],
      activeId: "c1",
    },
  });
}

describe("hybrid account storage", () => {
  it("keeps conversations out of localStorage", async () => {
    const local = new MemoryStorage();
    const storage = createHybridStorage({
      userId: () => "user-a",
      isLegacyOwner: () => false,
      local,
      indexedDb: new IDBFactory(),
    });
    await storage.setItem("alice", envelope("Private chat"));
    const localValue = local.getItem("alice:preferences:user-a") ?? "";
    expect(localValue).toContain('"theme":"light"');
    expect(localValue).not.toContain("Private chat");
    expect(await storage.getItem("alice")).toContain("Private chat");
  });

  it("migrates legacy per-user data only after durable persistence", async () => {
    const local = new MemoryStorage();
    local.setItem("alice:user-a", envelope("Legacy chat"));
    const storage = createHybridStorage({
      userId: () => "user-a",
      isLegacyOwner: () => false,
      local,
      indexedDb: new IDBFactory(),
    });
    expect(await storage.getItem("alice")).toContain("Legacy chat");
    expect(local.getItem("alice:user-a")).toBeNull();
    expect(local.getItem("alice:preferences:user-a")).not.toContain(
      "Legacy chat",
    );
  });

  it("isolates durable records between accounts", async () => {
    const local = new MemoryStorage();
    const indexedDb = new IDBFactory();
    let user = "user-a";
    const storage = createHybridStorage({
      userId: () => user,
      isLegacyOwner: () => false,
      local,
      indexedDb,
    });
    await storage.setItem("alice", envelope("Alice A"));
    user = "user-b";
    await storage.setItem("alice", envelope("Alice B"));
    expect(await storage.getItem("alice")).toContain("Alice B");
    expect(await storage.getItem("alice")).not.toContain("Alice A");
  });

  it("discards a read if the active account changes in flight", async () => {
    const local = new MemoryStorage();
    const indexedDb = new IDBFactory();
    let user = "user-a";
    const storage = createHybridStorage({
      userId: () => user,
      isLegacyOwner: () => false,
      local,
      indexedDb,
    });
    await storage.setItem("alice", envelope("Alice A"));
    const pending = storage.getItem("alice");
    user = "user-b";
    await expect(pending).resolves.toBeNull();
  });
});
