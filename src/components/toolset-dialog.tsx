import { ExternalLink } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import {
  mutateHermes,
  readHermesToolsetDetails,
  type HermesToolsetDetails,
  type HermesToolsetRow,
} from "@/lib/hermes-live";
import { localizeError } from "@/lib/i18n";
import { useLocale, useT } from "@/lib/use-i18n";

export function ToolsetDialog({
  toolset,
  open,
  onOpenChange,
  onChanged,
}: {
  toolset: HermesToolsetRow | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onChanged: () => Promise<void>;
}) {
  const t = useT();
  const locale = useLocale();
  const [details, setDetails] = useState<HermesToolsetDetails | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [setupKey, setSetupKey] = useState("");
  const toolsetName = toolset?.name;

  const load = useCallback(
    async (signal?: AbortSignal) => {
      if (!toolsetName) return;
      setError(null);
      const result = await readHermesToolsetDetails({
        name: toolsetName,
        signal,
      });
      if (signal?.aborted) return;
      if (result.ok) setDetails(result.details);
      else setError(localizeError(locale, result.error));
    },
    [locale, toolsetName],
  );

  useEffect(() => {
    if (!open || !toolsetName) return;
    const controller = new AbortController();
    setDetails(null);
    setSetupKey("");
    void load(controller.signal);
    return () => controller.abort();
  }, [load, open, toolsetName]);

  async function apply(
    key: string,
    mutation:
      | {
          action: "toolset-provider";
          name: string;
          provider: string;
          capability?: "search" | "extract";
        }
      | {
          action: "toolset-model";
          name: string;
          model: string;
          provider?: string;
        }
      | {
          action: "toolset-post-setup";
          name: string;
          key: string;
        },
  ) {
    if (busy) return;
    setBusy(key);
    setError(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setError(localizeError(locale, result.error));
      setBusy(null);
      return;
    }
    setSetupKey("");
    await Promise.all([load(), onChanged()]);
    setBusy(null);
  }

  return (
    <Dialog open={open} onOpenChange={(next) => !busy && onOpenChange(next)}>
      <DialogContent className="max-h-[min(760px,calc(100dvh-2rem))] max-w-2xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{toolset?.label ?? t("tools.inspect")}</DialogTitle>
          <DialogDescription>
            {toolset?.description || t("tools.inspectDescription")}
          </DialogDescription>
        </DialogHeader>

        <section className="space-y-2" aria-labelledby="toolset-tools-heading">
          <h3 id="toolset-tools-heading" className="text-sm font-medium">
            {t("tools.included")}
          </h3>
          <div className="flex flex-wrap gap-1.5">
            {toolset?.tools.length ? (
              toolset.tools.map((name) => (
                <span
                  key={name}
                  className="rounded-md bg-muted px-2 py-1 text-xs text-muted-foreground"
                >
                  {name}
                </span>
              ))
            ) : (
              <p className="text-sm text-muted-foreground">
                {t("tools.noListedTools")}
              </p>
            )}
          </div>
        </section>

        {!details && !error ? (
          <p className="text-sm text-muted-foreground">
            {t("tools.loadingConfig")}
          </p>
        ) : null}

        {details?.providers.length ? (
          <section
            className="space-y-3"
            aria-labelledby="toolset-providers-heading"
          >
            <h3 id="toolset-providers-heading" className="text-sm font-medium">
              {t("tools.providers")}
            </h3>
            <div className="divide-y rounded-lg border">
              {details.providers.map((provider) => {
                const missing = provider.envVars.filter((item) => !item.isSet);
                const genericActive =
                  provider.active || details.activeProvider === provider.name;
                return (
                  <div key={provider.name} className="space-y-2 p-3">
                    <div className="flex flex-wrap items-start justify-between gap-2">
                      <div>
                        <p className="text-sm font-medium">
                          {provider.badge || provider.name}
                        </p>
                        <p className="text-xs text-muted-foreground">
                          {provider.tag || provider.status || provider.name}
                        </p>
                      </div>
                      <div className="flex flex-wrap justify-end gap-1.5">
                        {provider.capabilities.length ? (
                          provider.capabilities.map((capability) => {
                            const active =
                              capability === "search"
                                ? details.activeSearchProvider === provider.name
                                : details.activeExtractProvider ===
                                  provider.name;
                            return (
                              <Button
                                key={capability}
                                size="sm"
                                variant={active ? "secondary" : "outline"}
                                disabled={Boolean(busy) || active}
                                onClick={() =>
                                  void apply(`${provider.name}:${capability}`, {
                                    action: "toolset-provider",
                                    name: toolset!.name,
                                    provider: provider.name,
                                    capability,
                                  })
                                }
                              >
                                {active
                                  ? t("tools.activeFor", { capability })
                                  : t("tools.useFor", { capability })}
                              </Button>
                            );
                          })
                        ) : (
                          <Button
                            size="sm"
                            variant={genericActive ? "secondary" : "outline"}
                            disabled={Boolean(busy) || genericActive}
                            onClick={() =>
                              void apply(provider.name, {
                                action: "toolset-provider",
                                name: toolset!.name,
                                provider: provider.name,
                              })
                            }
                          >
                            {genericActive
                              ? t("tools.active")
                              : t("tools.useProvider")}
                          </Button>
                        )}
                      </div>
                    </div>
                    {missing.length ? (
                      <p className="text-xs text-muted-foreground">
                        {t("tools.missingKeys", {
                          keys: missing.map((item) => item.key).join(", "),
                        })}
                        {missing[0]?.url ? (
                          <a
                            className="ml-1 inline-flex items-center gap-0.5 underline underline-offset-2"
                            href={missing[0].url}
                            target="_blank"
                            rel="noreferrer"
                          >
                            {t("tools.openSetup")}
                            <ExternalLink className="size-3" />
                          </a>
                        ) : null}
                      </p>
                    ) : null}
                    {provider.postSetup ? (
                      <div className="flex flex-col gap-2 sm:flex-row">
                        <Input
                          value={setupKey}
                          onChange={(event) => setSetupKey(event.target.value)}
                          type="password"
                          autoComplete="off"
                          placeholder={t("tools.setupKey")}
                          aria-label={t("tools.setupKey")}
                        />
                        <Button
                          variant="outline"
                          disabled={Boolean(busy) || !setupKey.trim()}
                          onClick={() =>
                            void apply(`setup:${provider.name}`, {
                              action: "toolset-post-setup",
                              name: toolset!.name,
                              key: setupKey.trim(),
                            })
                          }
                        >
                          {t("tools.finishSetup")}
                        </Button>
                      </div>
                    ) : null}
                  </div>
                );
              })}
            </div>
          </section>
        ) : null}

        {details?.models.length ? (
          <section
            className="space-y-3"
            aria-labelledby="toolset-models-heading"
          >
            <h3 id="toolset-models-heading" className="text-sm font-medium">
              {t("tools.models")}
            </h3>
            <div className="divide-y rounded-lg border">
              {details.models.map((model) => {
                const active = model.id === details.currentModel;
                return (
                  <div
                    key={model.id}
                    className="flex flex-col gap-2 p-3 sm:flex-row sm:items-center"
                  >
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium">{model.display}</p>
                      <p className="text-xs text-muted-foreground">
                        {[model.speed, model.strengths, model.price]
                          .filter(Boolean)
                          .join(" · ")}
                      </p>
                    </div>
                    <Button
                      size="sm"
                      variant={active ? "secondary" : "outline"}
                      disabled={Boolean(busy) || active}
                      onClick={() =>
                        void apply(`model:${model.id}`, {
                          action: "toolset-model",
                          name: toolset!.name,
                          model: model.id,
                          provider: details.activeProvider,
                        })
                      }
                    >
                      {active ? t("tools.active") : t("tools.useModel")}
                    </Button>
                  </div>
                );
              })}
            </div>
          </section>
        ) : null}

        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}
