import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { mutateHermes } from "@/lib/hermes-live";
import { useHermesLive } from "@/lib/use-hermes-live";

export const Route = createFileRoute("/_app/tools")({
  component: ToolsPage,
});

function ToolsPage() {
  const { data, error, loading, setData } = useHermesLive();
  const rows = data?.toolsets ?? [];
  const groups = [...new Set(rows.map((t) => t.platform || "cli"))].map((id) => ({
    id,
    label: id === "cli" ? "CLI" : id,
  }));

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      {loading ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">Leyendo las herramientas de Hermes…</p>
      ) : error ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">{error}</p>
      ) : (
        <CatalogPage
          kicker="Tools"
          title="Herramientas"
          description={
            data?.writable
              ? "Toolsets de tu Hermes. Los del núcleo y los que tienes configurados ahora."
              : "Toolsets de tu Hermes. Conecta el agente para activarlos o apagarlos desde aquí."
          }
          groups={groups}
          empty="Hermes no tiene toolsets visibles."
          rows={rows.map((t) => ({
            id: t.id,
            title: t.label,
            name: t.name,
            description: t.description,
            group: t.platform || "cli",
            groupLabel: t.platform === "cli" || !t.platform ? "CLI" : t.platform,
            meta: t.tools.slice(0, 6).join(", ") || (t.configured === false ? "Sin claves" : undefined),
            enabled: t.enabled,
          }))}
          onToggle={
            data?.writable
              ? (id) => {
                  const row = rows.find((t) => t.id === id);
                  if (!row || !data) return;
                  const enabled = !row.enabled;
                  setData({
                    ...data,
                    toolsets: data.toolsets.map((t) => (t.id === id ? { ...t, enabled } : t)),
                  });
                  void mutateHermes({ action: "toggle-toolset", name: row.name, enabled }).then((r) => {
                    if (r.ok) return;
                    setData({
                      ...data,
                      toolsets: data.toolsets.map((t) => (t.id === id ? { ...t, enabled: row.enabled } : t)),
                    });
                  });
                }
              : undefined
          }
          chatPrompt={(row) => `Usa ${row.name} para `}
        />
      )}
    </div>
  );
}
