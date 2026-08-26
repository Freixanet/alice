import { createFileRoute } from "@tanstack/react-router";
import { Pin, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useHermes } from "@/lib/store";
import type { MemoryKind } from "@/lib/types";
import { relativeTime } from "@/lib/utils";

export const Route = createFileRoute("/_app/memory")({
  component: MemoryPage,
});

const KINDS: { id: MemoryKind | "all"; label: string }[] = [
  { id: "all", label: "Todas" },
  { id: "preference", label: "Preferencias" },
  { id: "project", label: "Proyectos" },
  { id: "procedure", label: "Procedimientos" },
  { id: "person", label: "Personas" },
  { id: "fact", label: "Hechos" },
];

const KIND_LABEL: Record<MemoryKind, string> = {
  preference: "Preferencia",
  project: "Proyecto",
  procedure: "Procedimiento",
  person: "Persona",
  fact: "Hecho",
};

function MemoryPage() {
  const memories = useHermes((s) => s.memories);
  const removeMemory = useHermes((s) => s.removeMemory);
  const [q, setQ] = useState("");
  const [kind, setKind] = useState<MemoryKind | "all">("all");

  const filtered = useMemo(() => {
    const n = q.trim().toLowerCase();
    return memories.filter((m) => {
      if (kind !== "all" && m.kind !== kind) return false;
      if (!n) return true;
      return (m.title + " " + m.body).toLowerCase().includes(n);
    });
  }, [memories, q, kind]);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker="Persistent memory"
          title="Memoria"
          description="Lo que Hermes retiene entre sesiones. Poco, preciso, fácil de borrar."
        />
        <div className="flex flex-col gap-3">
          <Input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Buscar en memoria…"
            className="max-w-sm"
          />
          <div className="flex flex-wrap gap-1.5">
            {KINDS.map((k) => (
              <button
                key={k.id}
                type="button"
                onClick={() => setKind(k.id)}
                className={
                  kind === k.id
                    ? "h-8 rounded-full bg-primary px-3 text-xs font-medium text-primary-foreground"
                    : "h-8 rounded-full bg-muted px-3 text-xs font-medium text-muted-foreground hover:text-foreground"
                }
              >
                {k.label}
              </button>
            ))}
          </div>
        </div>
        <ul className="flex flex-col gap-2">
          {filtered.length === 0 ? (
            <li className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
              No hay recuerdos con ese filtro.
            </li>
          ) : (
            filtered.map((m) => (
              <li
                key={m.id}
                className="rounded-xl bg-card px-4 py-4 shadow-border"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="font-medium">{m.title}</h2>
                      <Badge variant="outline">{KIND_LABEL[m.kind]}</Badge>
                      {m.pinned ? (
                        <Pin className="size-3 text-muted-foreground" />
                      ) : null}
                    </div>
                    <p className="mt-1 text-sm text-muted-foreground">{m.body}</p>
                    <p className="mt-2 text-2xs tabular-nums text-muted-foreground">
                      {relativeTime(m.updatedAt)}
                    </p>
                  </div>
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    aria-label="Olvidar"
                    onClick={() => removeMemory(m.id)}
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              </li>
            ))
          )}
        </ul>
      </div>
    </div>
  );
}
