import { useCallback, useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  mutateHermes,
  readHermesSystemTools,
  type HermesSystemTools,
} from "@/lib/hermes-live";
import { useT } from "@/lib/use-i18n";

export function HermesSystemToolsPanel({ writable }: { writable: boolean }) {
  const t = useT();
  const [tools, setTools] = useState<HermesSystemTools | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async (signal?: AbortSignal) => {
    const result = await readHermesSystemTools({ signal });
    if (signal?.aborted) return;
    setLoading(false);
    if (result.ok) {
      setTools(result.tools);
      setError(null);
    } else {
      setError(result.error);
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void reload(controller.signal);
    return () => controller.abort();
  }, [reload]);

  async function chooseBackend(backend: string) {
    if (!tools || busy) return;
    const previous = tools;
    setBusy(`terminal:${backend}`);
    setError(null);
    setTools({
      ...tools,
      terminal: {
        ...tools.terminal,
        active: backend,
        backends: tools.terminal.backends.map((row) => ({
          ...row,
          active: row.name === backend,
        })),
      },
    });
    const result = await mutateHermes({ action: "terminal-backend", backend });
    if (!result.ok) {
      setTools(previous);
      setError(result.error);
    } else {
      await reload();
    }
    setBusy(null);
  }

  async function grantComputerUse() {
    if (busy) return;
    setBusy("computer-use");
    setError(null);
    const result = await mutateHermes({ action: "computer-use-grant" });
    if (!result.ok) setError(result.error);
    else window.setTimeout(() => void reload(), 1_500);
    setBusy(null);
  }

  if (loading) {
    return (
      <p className="text-sm text-muted-foreground">
        {t("tools.systemLoading")}
      </p>
    );
  }
  if (!tools) return null;

  const computerUse = tools.computerUse;
  return (
    <section className="alice-record-list grid gap-2 md:grid-cols-2">
      <article className="alice-record rounded-xl bg-card p-4 shadow-border">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="font-medium">{t("tools.terminal")}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t("tools.terminalDescription")}
            </p>
          </div>
          {tools.terminal.active ? (
            <Badge variant="live">{tools.terminal.active}</Badge>
          ) : null}
        </div>
        {tools.terminal.supported ? (
          <div className="mt-4 flex flex-col gap-2">
            {tools.terminal.backends.map((backend) => (
              <button
                key={backend.name}
                type="button"
                aria-pressed={backend.active}
                disabled={
                  !writable || busy !== null || backend.status === "unavailable"
                }
                onClick={() => void chooseBackend(backend.name)}
                className="min-h-11 rounded-lg px-3 py-2 text-left shadow-border transition-colors hover:bg-accent disabled:opacity-45"
              >
                <span className="flex items-center justify-between gap-3 text-sm font-medium">
                  {backend.label}
                  <Badge
                    variant={
                      backend.active
                        ? "live"
                        : backend.status === "ready"
                          ? "mute"
                          : "warn"
                    }
                  >
                    {backend.active
                      ? t("tools.active")
                      : backend.status === "ready"
                        ? t("tools.ready")
                        : backend.status === "needs_setup"
                          ? t("tools.needsSetup")
                          : t("tools.unavailable")}
                  </Badge>
                </span>
                <span className="mt-0.5 block text-xs text-muted-foreground">
                  {backend.detail || backend.description}
                </span>
              </button>
            ))}
          </div>
        ) : (
          <p className="mt-4 text-sm text-muted-foreground">
            {t("tools.notSupported")}
          </p>
        )}
      </article>

      <article className="alice-record rounded-xl bg-card p-4 shadow-border">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="font-medium">{t("tools.computerUse")}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t("tools.computerUseDescription")}
            </p>
          </div>
          {computerUse.supported ? (
            <Badge variant={computerUse.ready ? "live" : "warn"}>
              {computerUse.ready
                ? t("tools.permissionReady")
                : t("tools.permissionNeeded")}
            </Badge>
          ) : null}
        </div>
        {computerUse.supported ? (
          <div className="mt-4 space-y-3">
            <dl className="space-y-1 text-xs text-muted-foreground">
              {computerUse.platform ? (
                <div className="flex justify-between gap-3">
                  <dt>Platform</dt>
                  <dd className="text-foreground">{computerUse.platform}</dd>
                </div>
              ) : null}
              {computerUse.version ? (
                <div className="flex justify-between gap-3">
                  <dt>Driver</dt>
                  <dd className="text-foreground">{computerUse.version}</dd>
                </div>
              ) : null}
              {computerUse.checks.map((check) => (
                <div key={check.name} className="flex justify-between gap-3">
                  <dt>{check.name}</dt>
                  <dd className={check.ok ? "text-live" : "text-warn"}>
                    {check.status}
                  </dd>
                </div>
              ))}
            </dl>
            {computerUse.error ? (
              <p className="text-xs text-warn">{computerUse.error}</p>
            ) : null}
            {!computerUse.ready && computerUse.canGrant && writable ? (
              <Button
                variant="outline"
                size="sm"
                disabled={busy !== null}
                onClick={() => void grantComputerUse()}
              >
                {busy === "computer-use"
                  ? t("tools.requestingPermissions")
                  : t("tools.grantPermissions")}
              </Button>
            ) : null}
          </div>
        ) : (
          <p className="mt-4 text-sm text-muted-foreground">
            {t("tools.notSupported")}
          </p>
        )}
      </article>
      {error ? (
        <p className="text-sm text-destructive md:col-span-2">{error}</p>
      ) : null}
    </section>
  );
}
