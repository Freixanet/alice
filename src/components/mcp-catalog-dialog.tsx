import { ExternalLink, Search } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import type { HermesMcpCatalogRow } from "@/lib/hermes-live-types";
import { useT } from "@/lib/use-i18n";

export function McpCatalogDialog({
  open,
  entries,
  diagnostics,
  loading,
  error,
  busyName,
  onOpenChange,
  onInstall,
}: {
  open: boolean;
  entries: HermesMcpCatalogRow[];
  diagnostics: Array<{ name: string; kind: string; message: string }>;
  loading: boolean;
  error: string | null;
  busyName: string | null;
  onOpenChange: (open: boolean) => void;
  onInstall: (
    entry: HermesMcpCatalogRow,
    env: Record<string, string>,
  ) => Promise<boolean>;
}) {
  const t = useT();
  const [query, setQuery] = useState("");
  const [selectedName, setSelectedName] = useState("");
  const [env, setEnv] = useState<Record<string, string>>({});

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return entries;
    return entries.filter((entry) =>
      `${entry.name} ${entry.description} ${entry.transport} ${entry.authType}`
        .toLowerCase()
        .includes(needle),
    );
  }, [entries, query]);
  const selected =
    filtered.find((entry) => entry.name === selectedName) ?? filtered[0];

  useEffect(() => {
    if (open) return;
    setQuery("");
    setSelectedName("");
    setEnv({});
  }, [open]);

  const requiredComplete =
    selected?.requiredEnv
      .filter((item) => item.required)
      .every((item) => Boolean(env[item.name]?.trim())) ?? false;

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => !busyName && onOpenChange(next)}
    >
      <DialogContent className="flex max-h-[calc(100dvh-2rem)] max-w-4xl flex-col overflow-hidden p-0">
        <DialogHeader className="px-6 pt-6 pr-14">
          <DialogTitle>{t("addons.catalogTitle")}</DialogTitle>
          <DialogDescription>
            {t("addons.catalogDescription")}
          </DialogDescription>
        </DialogHeader>

        <div className="relative mx-6">
          <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("addons.catalogSearch")}
            className="pl-9"
          />
        </div>

        {loading ? (
          <p className="px-6 pb-6 text-sm text-muted-foreground">
            {t("addons.catalogLoading")}
          </p>
        ) : error ? (
          <p className="px-6 pb-6 text-sm text-destructive">{error}</p>
        ) : (
          <div className="grid min-h-0 flex-1 border-t border-border md:grid-cols-[minmax(14rem,0.8fr)_minmax(18rem,1.2fr)]">
            <div className="max-h-64 overflow-y-auto border-b border-border md:max-h-none md:border-r md:border-b-0">
              {filtered.length ? (
                <ul className="divide-y divide-border">
                  {filtered.map((entry) => (
                    <li key={entry.name}>
                      <button
                        type="button"
                        onClick={() => {
                          setSelectedName(entry.name);
                          setEnv({});
                        }}
                        className={`flex min-h-14 w-full flex-col items-start gap-1 px-4 py-3 text-left transition-colors hover:bg-accent ${
                          selected?.name === entry.name ? "bg-accent" : ""
                        }`}
                      >
                        <span className="flex w-full items-center justify-between gap-2">
                          <span className="truncate text-sm font-medium">
                            {entry.name}
                          </span>
                          {entry.installed ? (
                            <Badge variant="live">
                              {t("addons.catalogInstalled")}
                            </Badge>
                          ) : null}
                        </span>
                        <span className="line-clamp-2 text-xs text-muted-foreground">
                          {entry.description}
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="p-4 text-sm text-muted-foreground">
                  {t("addons.catalogEmpty")}
                </p>
              )}
            </div>

            <div className="min-h-0 overflow-y-auto p-5">
              {selected ? (
                <div className="flex flex-col gap-5">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="text-lg font-medium">{selected.name}</h3>
                      <Badge variant="outline">
                        {selected.transport.toUpperCase()}
                      </Badge>
                      {selected.authType !== "none" ? (
                        <Badge variant="mute">
                          {selected.authType.toUpperCase()}
                        </Badge>
                      ) : null}
                    </div>
                    <p className="mt-2 text-sm text-muted-foreground">
                      {selected.description}
                    </p>
                  </div>

                  <dl className="grid gap-2 text-xs text-muted-foreground">
                    {selected.url ? (
                      <div>
                        <dt className="font-medium text-foreground">
                          {t("addons.catalogEndpoint")}
                        </dt>
                        <dd className="break-all">{selected.url}</dd>
                      </div>
                    ) : null}
                    {selected.command ? (
                      <div>
                        <dt className="font-medium text-foreground">
                          {t("addons.catalogCommand")}
                        </dt>
                        <dd className="break-all">
                          {[selected.command, ...selected.args].join(" ")}
                        </dd>
                      </div>
                    ) : null}
                    {selected.source ? (
                      <div>
                        <dt className="font-medium text-foreground">
                          {t("addons.catalogSource")}
                        </dt>
                        <dd>
                          <a
                            href={selected.source}
                            target="_blank"
                            rel="noreferrer"
                            className="inline-flex min-h-10 items-center gap-1 underline underline-offset-4"
                          >
                            {t("addons.catalogInspect")}
                            <ExternalLink className="size-3.5" />
                          </a>
                        </dd>
                      </div>
                    ) : null}
                  </dl>

                  {selected.requiredEnv.length ? (
                    <fieldset className="flex flex-col gap-3">
                      <legend className="mb-1 text-sm font-medium">
                        {t("addons.catalogCredentials")}
                      </legend>
                      {selected.requiredEnv.map((item) => (
                        <label
                          key={item.name}
                          className="flex flex-col gap-1.5 text-sm"
                        >
                          <span>
                            {item.prompt || item.name}
                            {item.required ? " *" : ""}
                          </span>
                          <Input
                            type="password"
                            value={env[item.name] ?? ""}
                            onChange={(event) =>
                              setEnv((current) => ({
                                ...current,
                                [item.name]: event.target.value,
                              }))
                            }
                            autoComplete="new-password"
                          />
                        </label>
                      ))}
                      <p className="text-xs text-muted-foreground">
                        {t("addons.catalogCredentialsHint")}
                      </p>
                    </fieldset>
                  ) : null}

                  {selected.postInstall ? (
                    <p className="text-xs text-muted-foreground">
                      {selected.postInstall}
                    </p>
                  ) : null}

                  <div className="flex justify-end gap-2">
                    <Button
                      variant="ghost"
                      disabled={Boolean(busyName)}
                      onClick={() => onOpenChange(false)}
                    >
                      {t("projects.cancel")}
                    </Button>
                    <Button
                      disabled={
                        Boolean(busyName) ||
                        selected.installed ||
                        !requiredComplete
                      }
                      onClick={() =>
                        void onInstall(selected, env).then((ok) => {
                          if (ok) setEnv({});
                        })
                      }
                    >
                      {busyName === selected.name
                        ? t("addons.catalogInstalling")
                        : selected.installed
                          ? t("addons.catalogInstalled")
                          : t("addons.catalogInstall")}
                    </Button>
                  </div>
                </div>
              ) : null}
            </div>
          </div>
        )}

        {diagnostics.length ? (
          <p className="border-t border-border px-6 py-3 text-xs text-warn">
            {diagnostics[0]?.message}
          </p>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}
