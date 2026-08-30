import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { mergeSyncRecords, type SyncRecord } from "./sync-merge";

const record = fc.record({
  id: fc.constant("record"),
  clock: fc.record({
    wallTime: fc.nat(),
    counter: fc.nat(),
    deviceId: fc.string({ minLength: 1, maxLength: 16 }),
  }),
  tombstone: fc.boolean(),
  value: fc.option(fc.jsonValue(), { nil: null }),
});

describe("deterministic sync convergence", () => {
  it("is commutative, associative and idempotent", () => {
    fc.assert(
      fc.property(record, record, record, (a, b, c) => {
        const left = a as SyncRecord<unknown>;
        const middle = b as SyncRecord<unknown>;
        const right = c as SyncRecord<unknown>;
        expect(mergeSyncRecords(left, middle)).toEqual(
          mergeSyncRecords(middle, left),
        );
        expect(mergeSyncRecords(left, left)).toEqual(left);
        expect(mergeSyncRecords(mergeSyncRecords(left, middle), right)).toEqual(
          mergeSyncRecords(left, mergeSyncRecords(middle, right)),
        );
      }),
      { numRuns: 10_000 },
    );
  }, 15_000);
});
