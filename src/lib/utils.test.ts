import { describe, expect, it } from "vitest";
import { cn, relativeTime, uid } from "./utils";

describe("shared UI utilities", () => {
  it("merges Tailwind classes deterministically", () => {
    expect(cn("px-2", undefined, "px-4")).toBe("px-4");
  });

  it("formats every relative-time range", () => {
    const now = Date.UTC(2026, 7, 31, 12);
    expect(relativeTime(now - 5_000, now)).toBe("ahora");
    expect(relativeTime(now - 30_000, now)).toBe("hace 30 s");
    expect(relativeTime(now - 5 * 60_000, now)).toBe("hace 5 min");
    expect(relativeTime(now - 2 * 3_600_000, now)).toBe("hace 2 h");
    expect(relativeTime(now - 2 * 86_400_000, now)).toBe("hace 2 d");
    expect(relativeTime(now - 8 * 86_400_000, now)).toMatch(/23|ago/i);
  });

  it("generates valid unique identifiers", () => {
    const first = uid();
    const second = uid();
    expect(first).toMatch(/^[0-9a-f-]{36}$/i);
    expect(second).not.toBe(first);
  });
});
