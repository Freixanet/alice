import type { HermesInsights, HermesInsightsRow } from "./hermes-live-types";

export function insightsFromApi(raw: unknown): HermesInsights | null {
  const root = record(raw);
  if (!root) return null;
  const totals = record(root.totals);
  if (!totals) return null;
  const skills = record(root.skills);

  return {
    periodDays: boundedNumber(root.period_days, 1, 365, 30),
    totals: {
      sessions: number(totals.total_sessions),
      inputTokens: number(totals.total_input),
      outputTokens: number(totals.total_output),
      cacheReadTokens: number(totals.total_cache_read),
      reasoningTokens: number(totals.total_reasoning),
      apiCalls: number(totals.total_api_calls),
      estimatedCost: number(totals.total_estimated_cost),
      actualCost: number(totals.total_actual_cost),
    },
    models: list(root.by_model)
      .map((value) => {
        const row = record(value);
        return insightRow(
          text(row?.model) || "unknown",
          number(row?.sessions),
          number(row?.input_tokens) + number(row?.output_tokens),
          number(row?.estimated_cost),
        );
      })
      .filter(isRow)
      .slice(0, 100),
    tools: list(root.tools)
      .map((value) => {
        const row = record(value);
        return insightRow(text(row?.tool), number(row?.count));
      })
      .filter(isRow)
      .slice(0, 100),
    skills: list(skills?.top_skills)
      .map((value) => {
        const row = record(value);
        return insightRow(text(row?.skill), number(row?.total_count));
      })
      .filter(isRow)
      .slice(0, 100),
  };
}

function insightRow(
  name: string,
  count: number,
  tokens?: number,
  cost?: number,
): HermesInsightsRow | null {
  if (!name) return null;
  return {
    name: name.slice(0, 256),
    count,
    ...(tokens !== undefined ? { tokens } : {}),
    ...(cost !== undefined ? { cost } : {}),
  };
}

function isRow(value: HermesInsightsRow | null): value is HermesInsightsRow {
  return value !== null;
}

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function number(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(0, value)
    : 0;
}

function boundedNumber(
  value: unknown,
  minimum: number,
  maximum: number,
  fallback: number,
): number {
  const parsed = number(value);
  return parsed >= minimum && parsed <= maximum ? parsed : fallback;
}
