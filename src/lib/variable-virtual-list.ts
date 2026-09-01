export type VirtualLayoutItem = {
  id: string;
  index: number;
  start: number;
  size: number;
  end: number;
};

export type VirtualLayout = {
  items: VirtualLayoutItem[];
  totalSize: number;
};

export function buildVirtualLayout<T extends { id: string }>(
  items: readonly T[],
  measuredSizes: ReadonlyMap<string, number>,
  estimateSize: (item: T, index: number) => number,
): VirtualLayout {
  let start = 0;
  const layoutItems = items.map((item, index) => {
    const measured = measuredSizes.get(item.id);
    const estimated = estimateSize(item, index);
    const size = validSize(measured) ? measured : Math.max(1, estimated);
    const row = { id: item.id, index, start, size, end: start + size };
    start = row.end;
    return row;
  });
  return { items: layoutItems, totalSize: start };
}

export function selectVirtualWindow(
  layout: VirtualLayout,
  viewportStart: number,
  viewportSize: number,
  overscan: number,
): VirtualLayoutItem[] {
  if (layout.items.length === 0) return [];
  const start = Math.max(0, viewportStart - Math.max(0, overscan));
  const end = Math.min(
    layout.totalSize,
    Math.max(start, viewportStart + Math.max(0, viewportSize) + overscan),
  );
  const first = firstItemEndingAfter(layout.items, start);
  const selected: VirtualLayoutItem[] = [];
  for (let index = first; index < layout.items.length; index += 1) {
    const item = layout.items[index];
    if (!item || item.start >= end) break;
    selected.push(item);
  }
  return selected;
}

function firstItemEndingAfter(
  items: readonly VirtualLayoutItem[],
  offset: number,
): number {
  let low = 0;
  let high = items.length;
  while (low < high) {
    const middle = low + Math.floor((high - low) / 2);
    if ((items[middle]?.end ?? 0) <= offset) low = middle + 1;
    else high = middle;
  }
  return low;
}

function validSize(value: number | undefined): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}
