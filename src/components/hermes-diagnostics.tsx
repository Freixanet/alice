import { useEffect, useId, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  readHermesDiagnostics,
  type HermesDiagnostics,
} from "@/lib/hermes-live";
import { dateLocale, localizeError } from "@/lib/i18n";
import { useLocale, useT } from "@/lib/use-i18n";

export function HermesDiagnosticsPanel() {
  const t = useT();
  const locale = useLocale();
  const panelId = useId();
  const [open, setOpen] = useState(false);
  const [diagnostics, setDiagnostics] = useState<HermesDiagnostics | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);

  useEffect(() => {
    if (!open) return;
    const controller = new AbortController();
    setError(null);
    setDiagnostics(null);
    void readHermesDiagnostics({ signal: controller.signal }).then((result) => {
      if (controller.signal.aborted) return;
      if (result.ok) setDiagnostics(result.diagnostics);
      else setError(localizeError(locale, result.error));
    });
    return () => controller.abort();
  }, [locale, open, refresh]);

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-medium">{t("connect.diagnostics")}</h2>
        <Button
          variant="outline"
          size="sm"
          className="min-h-11 md:min-h-8"
          aria-expanded={open}
          aria-controls={panelId}
          onClick={() => setOpen((current) => !current)}
        >
          {open ? t("connect.hideDiagnostics") : t("connect.showDiagnostics")}
        </Button>
      </div>
      {open ? (
        <div
          id={panelId}
          className="border-y border-border py-4"
          aria-live="polite"
        >
          {error ? (
            <p className="text-sm text-destructive" role="alert">
              {error}
            </p>
          ) : diagnostics === null ? (
            <p className="text-sm text-muted-foreground">
              {t("connect.loadingDiagnostics")}
            </p>
          ) : (
            <div className="space-y-4">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant={healthy(diagnostics.status) ? "live" : "warn"}>
                  {diagnostics.status}
                </Badge>
                {diagnostics.version ? (
                  <span className="text-xs text-muted-foreground">
                    {t("connect.diagnosticVersion", {
                      version: diagnostics.version,
                    })}
                  </span>
                ) : null}
              </div>
              <dl className="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2">
                <DiagnosticRow
                  label={t("connect.gatewayState")}
                  value={diagnostics.gatewayState || diagnostics.status}
                />
                <DiagnosticRow
                  label={t("connect.activeAgents")}
                  value={String(diagnostics.activeAgents)}
                />
                <DiagnosticRow
                  label={t("connect.gatewayBusy")}
                  value={diagnostics.busy ? t("common.yes") : t("common.no")}
                />
                <DiagnosticRow
                  label={t("connect.gatewayDrainable")}
                  value={
                    diagnostics.drainable ? t("common.yes") : t("common.no")
                  }
                />
                {diagnostics.updatedAt ? (
                  <DiagnosticRow
                    label={t("connect.diagnosticUpdated")}
                    value={formatTimestamp(locale, diagnostics.updatedAt)}
                  />
                ) : null}
              </dl>
              {diagnostics.exitReason ? (
                <p className="text-sm text-destructive">
                  {t("connect.exitReason", { reason: diagnostics.exitReason })}
                </p>
              ) : null}
              <div>
                <h3 className="text-xs font-medium uppercase tracking-[0.12em] text-muted-foreground">
                  {t("connect.diagnosticPlatforms")}
                </h3>
                {diagnostics.platforms.length ? (
                  <ul className="mt-2 divide-y divide-border border-y border-border">
                    {diagnostics.platforms.map((platform) => (
                      <li
                        key={platform.id}
                        className="flex min-h-11 items-center justify-between gap-3 py-2 text-sm"
                      >
                        <span>{platform.name}</span>
                        <Badge
                          variant={
                            healthy(platform.status) ? "live" : "outline"
                          }
                        >
                          {platform.status}
                        </Badge>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="mt-2 text-sm text-muted-foreground">
                    {t("connect.noDiagnosticPlatforms")}
                  </p>
                )}
              </div>
              <Button
                variant="ghost"
                size="sm"
                className="min-h-11 md:min-h-8"
                onClick={() => setRefresh((current) => current + 1)}
              >
                {t("connect.refreshDiagnostics")}
              </Button>
            </div>
          )}
        </div>
      ) : null}
    </section>
  );
}

function DiagnosticRow({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-0.5 break-words text-foreground">{value}</dd>
    </div>
  );
}

function healthy(status: string): boolean {
  return /^(ok|ready|running|connected|healthy|idle)$/i.test(status.trim());
}

function formatTimestamp(locale: "en" | "es", value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? value
    : date.toLocaleString(dateLocale(locale), {
        dateStyle: "medium",
        timeStyle: "short",
      });
}
