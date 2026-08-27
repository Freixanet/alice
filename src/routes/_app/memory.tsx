import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { listHermesMemory, type HermesMemoryProfile } from "@/lib/gateway";
import { useHermes } from "@/lib/store";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_app/memory")({
  component: MemoryPage,
});

function MemoryPage() {
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
          kicker="Hermes"
          title="Memoria"
          description="Soul, perfil de usuario y notas que tu agente guarda entre sesiones. Lo lee de SOUL.md, USER.md y MEMORY.md."
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
                {p.current ? " · actual" : ""}
              </button>
            ))}
          </div>
        ) : null}

        <Input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Buscar en soul, perfil y notas…"
          className="max-w-sm"
        />

        {loading ? (
          <p className="text-sm text-muted-foreground">Leyendo a Hermes…</p>
        ) : error ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            {error}
          </div>
        ) : !profile ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            No hay memoria de Hermes en este Mac.{" "}
            <Link to="/connect" className="text-foreground underline-offset-2 hover:underline">
              Conéctalo
            </Link>
            .
          </div>
        ) : (
          <Tabs defaultValue="soul">
            <TabsList>
              <TabsTrigger value="soul">Soul</TabsTrigger>
              <TabsTrigger value="user">Perfil</TabsTrigger>
              <TabsTrigger value="notes">Notas</TabsTrigger>
            </TabsList>
            <TabsContent value="soul">
              {soulText && soulMatch ? (
                <article className="rounded-xl bg-card px-4 py-4 shadow-border">
                  <p className="whitespace-pre-wrap text-sm leading-relaxed">{soulText}</p>
                </article>
              ) : (
                <EmptyStore
                  text={
                    query
                      ? "Nada coincide en el soul."
                      : "Este perfil no tiene SOUL.md."
                  }
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
                    <li key={`${entry.slice(0, 48)}-${i}`} className="rounded-xl bg-card px-4 py-4 text-sm leading-relaxed shadow-border">
                      {entry}
                    </li>
                  ))}
                </ul>
              ) : (
                <EmptyStore
                  text={
                    query
                      ? "Nada coincide en el perfil."
                      : "Hermes aún no ha guardado un perfil de usuario."
                  }
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
                    <li key={`${entry.slice(0, 48)}-${i}`} className="rounded-xl bg-card px-4 py-4 text-sm leading-relaxed shadow-border">
                      {entry}
                    </li>
                  ))}
                </ul>
              ) : (
                <EmptyStore
                  text={
                    query
                      ? "Nada coincide en las notas."
                      : "Hermes aún no ha guardado notas."
                  }
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
  const pct = limit > 0 ? Math.min(100, Math.round((chars / limit) * 100)) : 0;
  return (
    <div className="flex flex-wrap items-center gap-2 text-2xs text-muted-foreground">
      <Badge variant="outline">{file}</Badge>
      <span>
        {count} {count === 1 ? "entrada" : "entradas"}
      </span>
      <span className="tabular-nums">
        {chars.toLocaleString("es")} / {limit.toLocaleString("es")} · {pct}%
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
