import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { mutateHermes } from "@/lib/hermes-live";
import { useHermesLive } from "@/lib/use-hermes-live";

export const Route = createFileRoute("/_app/addons")({
  component: AddonsPage,
});

function AddonsPage() {
  const { data, error, loading, setData } = useHermesLive();
  const rows = data?.mcp ?? [];

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      {loading ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">Leyendo los complementos de Hermes…</p>
      ) : error ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">{error}</p>
      ) : (
        <CatalogPage
          kicker="MCP"
          title="Complementos"
          description={
            data?.writable
              ? "Servidores MCP configurados en tu Hermes."
              : "Servidores MCP configurados en tu Hermes. Conecta el agente para activarlos o apagarlos desde aquí."
          }
          groups={[{ id: "mcp", label: "MCP" }]}
          empty="No hay servidores MCP configurados."
          rows={rows.map((a) => ({
            id: a.id,
            title: a.name,
            name: a.name,
            description: a.detail,
            group: "mcp",
            groupLabel: a.transport.toUpperCase(),
            enabled: a.enabled,
          }))}
          onToggle={
            data?.writable
              ? (id) => {
                  const row = rows.find((a) => a.id === id);
                  if (!row || !data) return;
                  const enabled = !row.enabled;
                  setData({
                    ...data,
                    mcp: data.mcp.map((a) => (a.id === id ? { ...a, enabled } : a)),
                  });
                  void mutateHermes({ action: "toggle-mcp", name: row.name, enabled }).then((r) => {
                    if (r.ok) return;
                    setData({
                      ...data,
                      mcp: data.mcp.map((a) => (a.id === id ? { ...a, enabled: row.enabled } : a)),
                    });
                  });
                }
              : undefined
          }
          chatPrompt={(row) => `Usa el MCP ${row.title} para `}
        />
      )}
    </div>
  );
}
