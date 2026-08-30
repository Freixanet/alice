export type HybridTimestamp = {
  wallTime: number;
  counter: number;
  deviceId: string;
};

export type SyncRecord<T> = {
  id: string;
  clock: HybridTimestamp;
  tombstone: boolean;
  value: T | null;
};

export function compareHybridTimestamp(a: HybridTimestamp, b: HybridTimestamp) {
  if (a.wallTime !== b.wallTime) return a.wallTime < b.wallTime ? -1 : 1;
  if (a.counter !== b.counter) return a.counter < b.counter ? -1 : 1;
  return a.deviceId.localeCompare(b.deviceId);
}

export function mergeSyncRecords<T>(
  left: SyncRecord<T>,
  right: SyncRecord<T>,
): SyncRecord<T> {
  if (left.id !== right.id) throw new Error("Cannot merge different records");
  const order = compareHybridTimestamp(left.clock, right.clock);
  if (order < 0) return right;
  if (order > 0) return left;
  if (left.tombstone !== right.tombstone) return left.tombstone ? left : right;
  return stableValue(left) <= stableValue(right) ? left : right;
}

export function advanceHybridTimestamp(
  local: HybridTimestamp,
  observed: HybridTimestamp | null,
  now: number,
): HybridTimestamp {
  const wallTime = Math.max(now, local.wallTime, observed?.wallTime ?? 0);
  let counter = 0;
  if (wallTime === local.wallTime)
    counter = Math.max(counter, local.counter + 1);
  if (observed && wallTime === observed.wallTime) {
    counter = Math.max(counter, observed.counter + 1);
  }
  return { wallTime, counter, deviceId: local.deviceId };
}

function stableValue<T>(record: SyncRecord<T>) {
  return JSON.stringify(record.value);
}
