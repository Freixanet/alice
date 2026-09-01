import { describe, expect, it } from "vitest";
import {
  buildVirtualLayout,
  selectVirtualWindow,
} from "./variable-virtual-list";

const items = (count: number) =>
  Array.from({ length: count }, (_, index) => ({ id: `message-${index}` }));

describe("variable virtual list", () => {
  it("keeps the rendered window bounded for very large conversations", () => {
    const layout = buildVirtualLayout(items(10_000), new Map(), () => 160);
    const visible = selectVirtualWindow(layout, 800_000, 844, 640);
    expect(layout.totalSize).toBe(1_600_000);
    expect(visible.length).toBeLessThanOrEqual(15);
    expect(visible[0]?.index).toBeGreaterThan(4_990);
    expect(visible.at(-1)?.index).toBeLessThan(5_010);
  });

  it("uses measured variable heights without gaps or overlap", () => {
    const measured = new Map([
      ["message-0", 80],
      ["message-1", 240],
    ]);
    const layout = buildVirtualLayout(items(3), measured, () => 100);
    expect(layout.items).toEqual([
      { id: "message-0", index: 0, start: 0, size: 80, end: 80 },
      { id: "message-1", index: 1, start: 80, size: 240, end: 320 },
      { id: "message-2", index: 2, start: 320, size: 100, end: 420 },
    ]);
    expect(layout.totalSize).toBe(420);
  });

  it("selects correct windows at both boundaries", () => {
    const layout = buildVirtualLayout(items(100), new Map(), () => 100);
    expect(
      selectVirtualWindow(layout, 0, 200, 0).map((row) => row.index),
    ).toEqual([0, 1]);
    expect(
      selectVirtualWindow(layout, 9_800, 200, 0).map((row) => row.index),
    ).toEqual([98, 99]);
    expect(selectVirtualWindow(layout, 0, 0, 0)).toEqual([]);
  });

  it("ignores invalid remote measurements", () => {
    const measured = new Map([
      ["message-0", Number.NaN],
      ["message-1", -20],
    ]);
    const layout = buildVirtualLayout(items(2), measured, () => 120);
    expect(layout.totalSize).toBe(240);
  });
});
