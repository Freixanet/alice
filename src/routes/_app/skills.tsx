import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { LearnSkillButton } from "@/components/learn-skill";
import { mutateHermes } from "@/lib/hermes-live";
import { useHermesLive } from "@/lib/use-hermes-live";

export const Route = createFileRoute("/_app/skills")({
  component: SkillsPage,
});

function SkillsPage() {
  const { data, error, loading, setData } = useHermesLive();
  const rows = data?.skills ?? [];
  const groups = [...new Map(rows.map((s) => [s.group, s.groupLabel])).entries()].map(
    ([id, label]) => ({ id, label }),
  );

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      {loading ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">Leyendo las skills de Hermes…</p>
      ) : error ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">{error}</p>
      ) : (
        <CatalogPage
          kicker="Skills"
          title="Habilidades"
          description={
            data?.writable
              ? "Las skills instaladas en tu Hermes. El interruptor las activa o las deja fuera del contexto."
              : "Las skills instaladas en tu Hermes. Conecta el agente para activarlas o apagarlas desde aquí."
          }
          action={<LearnSkillButton />}
          groups={groups}
          empty="Hermes no tiene skills en este perfil."
          rows={rows.map((s) => ({
            id: s.id,
            title: s.title,
            name: s.name,
            description: s.description,
            group: s.group,
            groupLabel: s.groupLabel,
            meta: s.provenance,
            enabled: s.enabled,
          }))}
          onToggle={
            data?.writable
              ? (id) => {
                  const row = rows.find((s) => s.id === id);
                  if (!row || !data) return;
                  const enabled = !row.enabled;
                  setData({
                    ...data,
                    skills: data.skills.map((s) => (s.id === id ? { ...s, enabled } : s)),
                  });
                  void mutateHermes({ action: "toggle-skill", name: row.name, enabled }).then((r) => {
                    if (r.ok) return;
                    setData({
                      ...data,
                      skills: data.skills.map((s) => (s.id === id ? { ...s, enabled: row.enabled } : s)),
                    });
                  });
                }
              : undefined
          }
          chatPrompt={(row) => `Usa la skill ${row.name} para `}
        />
      )}
    </div>
  );
}
