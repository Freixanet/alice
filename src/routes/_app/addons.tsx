import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { addons } from "@/lib/catalog";
import { useHermes } from "@/lib/store";

export const Route = createFileRoute("/_app/addons")({
  component: AddonsPage,
});

const GROUPS = [
  { id: "plugin", label: "Plugins" },
  { id: "mcp", label: "MCP" },
  { id: "bundle", label: "Paquetes" },
];

function AddonsPage() {
  const isAddonOn = useHermes((s) => s.isAddonOn);
  const toggleAddon = useHermes((s) => s.toggleAddon);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <CatalogPage
        kicker="Plugins · MCP · bundles"
        title="Complementos"
        description="Todo lo que se enchufa: plugins del escritorio, servidores MCP y paquetes de skills."
        groups={GROUPS}
        rows={addons.map((a) => ({
          id: a.id,
          title: a.name,
          name: a.id,
          description: a.description,
          group: a.kind,
          groupLabel: GROUPS.find((g) => g.id === a.kind)?.label ?? a.kind,
          trust: a.trust,
          version: a.version,
          enabled: isAddonOn(a.id),
        }))}
        onToggle={toggleAddon}
        chatPrompt={(row) => `Configura el complemento ${row.title}: `}
      />
    </div>
  );
}
