import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { cronScheduleFields, cronScheduleFor } from "./cron";

describe("cron schedule editing", () => {
  it.each([
    ["daily", "09:05", "5 9 * * *"],
    ["weekdays", "18:30", "30 18 * * 1-5"],
    ["weekly", "07:00", "0 7 * * 1"],
    ["hourly", "12:34", "0 * * * *"],
  ] as const)("builds %s schedules", (frequency, time, expected) => {
    expect(cronScheduleFor(frequency, time, "")).toBe(expected);
    const fields = cronScheduleFields(expected);
    expect(cronScheduleFor(fields.frequency, fields.time, fields.custom)).toBe(
      expected,
    );
  });

  it("preserves every custom schedule verbatim except surrounding space", () => {
    fc.assert(
      fc.property(
        fc.string({ minLength: 1 }).filter((value) => value.trim().length > 0),
        (value) => {
          const fields = cronScheduleFields(value);
          if (fields.frequency !== "custom") return;
          expect(
            cronScheduleFor(fields.frequency, fields.time, fields.custom),
          ).toBe(value.trim());
        },
      ),
      { numRuns: 10_000 },
    );
  });

  it("never emits invalid hours or minutes from malformed time input", () => {
    expect(cronScheduleFor("daily", "99:99", "")).toBe("0 9 * * *");
    expect(cronScheduleFor("daily", "nope", "")).toBe("0 9 * * *");
  });
});
