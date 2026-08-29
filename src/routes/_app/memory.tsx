import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { listHermesMemory, type HermesMemoryProfile } from "@/lib/gateway";
import { dateLocale, localizeError } from "@/lib/i18n";
import { useHermes } from "@/lib/store";
import { useLocale, useT } from "@/lib/use-i18n";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_app/memory")({
  component: MemoryPage,
});

function MemoryPage() {
  const t = useT();
  const locale = useLocale();
  const gatewayOn = useHermes((s) => s.gatewayOn);
  const gatewayStatus = useHermes((s) => s.gatewayStatus);
  const live = gatewayOn && gatewayStatus === "live";
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<HermesMemoryProfile[]>([]);
  const [active, setActive] = useState("default");
  const [q, setQ] = useState("");

  useEffect(() => {
    const ctrl = new AbortController();
    setLoading(true);
    void listHermesMemory({ signal: ctrl.signal }).then((result) => {
      if (ctrl.signal.aborted) return;
      if (!result.ok) {
        setError(result.error);
        setProfiles([]);
        setLoading(false);
        return;
      }
      setError(null);
      setProfiles(result.profiles);
      setActive(result.active || result.profiles[0]?.name || "default");
      setLoading(false);
    });
    return () => ctrl.abort();
  }, [live]);

  const profile = profiles.find((p) => p.name === active) ?? profiles[0];
  const query = q.trim().toLowerCase();

  const userEntries = useMemo(() => {
    const list = profile?.user.entries ?? [];
    if (!query) return list;
    return list.filter((e) => e.toLowerCase().includes(query));
  }, [profile, query]);

  const noteEntries = useMemo(() => {
    const list = profile?.notes.entries ?? [];
    if (!query) return list;
    return list.filter((e) => e.toLowerCase().includes(query));
  }, [profile, query]);

  const soulText = profile?.soul ?? "";
  const soulMatch = !query || soulText.toLowerCase().includes(query);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("memory.kicker")}
          title={t("memory.title")}
          description={t("memory.description")}
        />

        {profiles.length > 1 ? (
          <div className="flex flex-wrap gap-1.5">
            {profiles.map((p) => (
              <button
                key={p.name}
                type="button"
                onClick={() => setActive(p.name)}
                className={cn(
                  "h-8 rounded-full px-3 text-xs font-medium",
                  p.name === profile?.name
                    ? "bg-primary text-primary-foreground"
                    : "bg-muted text-muted-foreground hover:text-foreground",
                )}
              >
                {p.name}
                {p.current ? ` · ${t("memory.current")}` : ""}
              </button>
            ))}
          </div>
        ) : null}

        <Input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder={t("memory.search")}
          className="max-w-sm"
        />

        {loading ? (
          <p className="text-sm text-muted-foreground">{t("memory.loading")}</p>
        ) : error ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            {localizeError(locale, error)}
          </div>
        ) : !profile ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            {t("memory.empty")}{" "}
            <Link to="/connect" className="text-foreground underline-offset-2 hover:underline">
              {t("memory.connectIt")}
            </Link>
            .
          </div>
        ) : (
          <Tabs defaultValue="soul">
            <TabsList>
              <TabsTrigger value="soul">{t("memory.soul")}</TabsTrigger>
              <TabsTrigger value="user">{t("memory.user")}</TabsTrigger>
              <TabsTrigger value="notes">{t("memory.notes")}</TabsTrigger>
            </TabsList>
            <TabsContent value="soul">
              {soulText && soulMatch ? (
                <article className="rounded-xl bg-card px-4 py-4 shadow-border">
                  <p className="whitespace-pre-wrap text-base leading-7 md:text-[0.9375rem]">{soulText}</p>
                </article>
              ) : (
                <EmptyStore
                  text={query ? t("memory.noSoulMatch") : t("memory.noSoul")}
                />
              )}
            </TabsContent>
            <TabsContent value="user">
              <StoreHeader
                file="USER.md"
                chars={profile.user.chars}
                limit={profile.user.limit}
                count={profile.user.entries.length}
              />
              {userEntries.length ? (
                <ul className="mt-3 flex flex-col gap-2">
                  {userEntries.map((entry, i) => (
                    <li key={`${entry.slice(0, 48)}-${i}`} className="rounded-xl bg-card px-4 py-4 text-base leading-7 shadow-border md:text-[0.9375rem]">
                      {entry}
                    </li>
                  ))}
                </ul>
              ) : (
                <EmptyStore
                  text={query ? t("memory.noUserMatch") : t("memory.noUser")}
                />
              )}
            </TabsContent>
            <TabsContent value="notes">
              <StoreHeader
                file="MEMORY.md"
                chars={profile.notes.chars}
                limit={profile.notes.limit}
                count={profile.notes.entries.length}
              />
              {noteEntries.length ? (
                <ul className="mt-3 flex flex-col gap-2">
                  {noteEntries.map((entry, i) => (
                    <li key={`${entry.slice(0, 48)}-${i}`} className="rounded-xl bg-card px-4 py-4 text-base leading-7 shadow-border md:text-[0.9375rem]">
                      {entry}
                    </li>
                  ))}
                </ul>
              ) : (
                <EmptyStore
                  text={query ? t("memory.noNotesMatch") : t("memory.noNotes")}
                />
              )}
            </TabsContent>
          </Tabs>
        )}
      </div>
    </div>
  );
}

function StoreHeader({
  file,
  chars,
  limit,
  count,
}: {
  file: string;
  chars: number;
  limit: number;
  count: number;
}) {
  const t = useT();
  const locale = useLocale();
  const pct = limit > 0 ? Math.min(100, Math.round((chars / limit) * 100)) : 0;
  return (
    <div className="flex flex-wrap items-center gap-2 text-2xs text-muted-foreground">
      <Badge variant="outline">{file}</Badge>
      <span>
        {count} {count === 1 ? t("memory.entry") : t("memory.entries")}
      </span>
      <span className="tabular-nums">
        {chars.toLocaleString(dateLocale(locale))} / {limit.toLocaleString(dateLocale(locale))} · {pct}%
      </span>
    </div>
  );
}

function EmptyStore({ text }: { text: string }) {
  return (
    <div className="mt-3 rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
      {text}
    </div>
  );
}
