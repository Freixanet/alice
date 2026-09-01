import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Button } from "@/components/ui/button";
import {
  readHermesInsights,
  type HermesInsights,
  type HermesInsightsRow,
} from "@/lib/hermes-live";
import { localizeError } from "@/lib/i18n";
import { useHermes } from "@/lib/store";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/insights")({
  component: InsightsPage,
});

function InsightsPage() {
  const t = useT();
  const locale = useLocale();
  const connected = useHermes(
    (state) => state.gatewayOn && state.gatewayStatus === "live",
  );
  const [days, setDays] = useState(30);
  const [insights, setInsights] = useState<HermesInsights | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!connected) {
      setInsights(null);
      return;
    }
    const controller = new AbortController();
    setLoading(true);
    setError(null);
    void readHermesInsights({ days, signal: controller.signal }).then(
      (result) => {
        if (controller.signal.aborted) return;
        setLoading(false);
        if (result.ok) setInsights(result.insights);
        else {
          setInsights(null);
          setError(localizeError(locale, result.error));
        }
      },
    );
    return () => controller.abort();
  }, [connected, days, locale]);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <main className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("insights.kicker")}
          title={t("insights.title")}
          description={t("insights.description")}
          action={
            <div className="flex gap-1">
              {[7, 30, 90].map((value) => (
                <Button
                  key={value}
                  size="sm"
                  variant={days === value ? "secondary" : "ghost"}
                  aria-pressed={days === value}
                  onClick={() => setDays(value)}
                >
                  {t("insights.days", { count: value })}
                </Button>
              ))}
            </div>
          }
        />

        {loading ? (
          <p className="text-sm text-muted-foreground">
            {t("insights.loading")}
          </p>
        ) : !connected ? (
          // Three different causes used to share one message. Keep them apart:
          // only the last one means "this Hermes has no analytics".
          <div className="rounded-xl border border-border bg-card px-4 py-10 text-center text-sm text-muted-foreground">
            <p>{t("error.connectFirst")}</p>
            <Link
              to="/connect"
              className="mt-2 inline-block text-foreground underline underline-offset-4"
            >
              {t("nav.connect")}
            </Link>
          </div>
        ) : error ? (
          <p
            className="rounded-xl border border-border bg-card px-4 py-10 text-center text-sm text-muted-foreground"
            role="alert"
          >
            {error}
          </p>
        ) : !insights ? (
          <p className="rounded-xl border border-border bg-card px-4 py-10 text-center text-sm text-muted-foreground">
            {t("insights.unavailable")}
          </p>
        ) : (
          <>
            <dl className="grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-border bg-border sm:grid-cols-4">
              <Metric
                label={t("insights.sessions")}
                value={formatNumber(locale, insights.totals.sessions)}
              />
              <Metric
                label={t("insights.tokens")}
                value={formatNumber(
                  locale,
                  insights.totals.inputTokens + insights.totals.outputTokens,
                )}
              />
              <Metric
                label={t("insights.apiCalls")}
                value={formatNumber(locale, insights.totals.apiCalls)}
              />
              <Metric
                label={t("insights.cost")}
                value={new Intl.NumberFormat(locale, {
                  style: "currency",
                  currency: "USD",
                  maximumFractionDigits: 4,
                }).format(
                  insights.totals.actualCost || insights.totals.estimatedCost,
                )}
              />
            </dl>
            <InsightList
              title={t("insights.models")}
              rows={insights.models}
              locale={locale}
            />
            <div className="grid gap-6 sm:grid-cols-2">
              <InsightList
                title={t("insights.tools")}
                rows={insights.tools}
                locale={locale}
              />
              <InsightList
                title={t("insights.skills")}
                rows={insights.skills}
                locale={locale}
              />
            </div>
          </>
        )}
      </main>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-card px-4 py-4">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-1 text-xl font-medium tabular-nums">{value}</dd>
    </div>
  );
}

function InsightList({
  title,
  rows,
  locale,
}: {
  title: string;
  rows: HermesInsightsRow[];
  locale: "en" | "es";
}) {
  return (
    <section className="space-y-2">
      <h2 className="text-sm font-medium">{title}</h2>
      <ol className="overflow-hidden rounded-xl border border-border bg-card">
        {rows.length ? (
          rows.slice(0, 12).map((row) => (
            <li
              key={row.name}
              className="flex min-h-11 items-center justify-between gap-3 border-b border-border px-3 last:border-b-0"
            >
              <span className="min-w-0 truncate text-sm">{row.name}</span>
              <span className="shrink-0 text-xs tabular-nums text-muted-foreground">
                {row.tokens !== undefined
                  ? formatNumber(locale, row.tokens)
                  : formatNumber(locale, row.count)}
              </span>
            </li>
          ))
        ) : (
          <li className="px-3 py-8 text-center text-sm text-muted-foreground">
            —
          </li>
        )}
      </ol>
    </section>
  );
}

function formatNumber(locale: "en" | "es", value: number): string {
  return new Intl.NumberFormat(locale, { notation: "compact" }).format(value);
}
