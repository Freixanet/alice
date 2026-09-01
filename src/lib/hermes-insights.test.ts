import { describe, expect, it } from "vitest";
import { insightsFromApi } from "./hermes-insights";

describe("insightsFromApi", () => {
  it("normalizes the Pantheon usage contract", () => {
    expect(
      insightsFromApi({
        period_days: 7,
        totals: {
          total_sessions: 4,
          total_input: 100,
          total_output: 50,
          total_api_calls: 6,
          total_estimated_cost: 0.25,
        },
        by_model: [
          {
            model: "test/model",
            sessions: 4,
            input_tokens: 100,
            output_tokens: 50,
          },
        ],
        tools: [{ tool: "browser", count: 3 }],
        skills: { top_skills: [{ skill: "research", total_count: 2 }] },
      }),
    ).toEqual(
      expect.objectContaining({
        periodDays: 7,
        models: [expect.objectContaining({ name: "test/model", tokens: 150 })],
        tools: [expect.objectContaining({ name: "browser", count: 3 })],
        skills: [expect.objectContaining({ name: "research", count: 2 })],
      }),
    );
  });

  it("rejects bodies without totals", () => {
    expect(insightsFromApi({ error: "no" })).toBeNull();
  });
});
