import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { tools, TOOLSETS } from "@/lib/catalog";
import { useHermes } from "@/lib/store";

export const Route = createFileRoute("/_app/tools")({
  component: ToolsPage,
});

function ToolsPage() {
  const isToolOn = useHermes((s) => s.isToolOn);
  const toggleTool = useHermes((s) => s.toggleTool);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <CatalogPage
        kicker="Tools"
        title="Herramientas"
        description="El registro nativo de Hermes. Las del núcleo siguen cargadas; el resto se encienden por toolset."
        groups={TOOLSETS}
        rows={tools.map((t) => ({
          id: t.id,
          title: t.name,
          name: t.name,
          description: t.description,
          group: t.toolset,
          groupLabel: TOOLSETS.find((s) => s.id === t.toolset)?.label ?? t.toolset,
          version: t.core ? "núcleo" : undefined,
          meta: t.core ? "Siempre en el conjunto base" : undefined,
          enabled: isToolOn(t.id),
        }))}
        onToggle={toggleTool}
        chatPrompt={(row) => `Usa ${row.name} para `}
      />
    </div>
  );
}
