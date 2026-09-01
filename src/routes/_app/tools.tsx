import { createFileRoute } from "@tanstack/react-router";
import { SlidersHorizontal } from "lucide-react";
import { useState } from "react";
import { CatalogPage, PageHeader } from "@/components/catalog-page";
import { ToolsetDialog } from "@/components/toolset-dialog";
import { HermesSystemToolsPanel } from "@/components/hermes-system-tools";
import { Button } from "@/components/ui/button";
import {
  listHermesLive,
  mutateHermes,
  type HermesToolsetRow,
} from "@/lib/hermes-live";
import { localizeError } from "@/lib/i18n";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/tools")({
  component: ToolsPage,
});

function ToolsPage() {
  const t = useT();
  const locale = useLocale();
  const { data, error, loading, setData } = useHermesLive();
  const [selected, setSelected] = useState<HermesToolsetRow | null>(null);
  const rows = data?.toolsets ?? [];
  const groups = [...new Set(rows.map((tool) => tool.platform || "cli"))].map(
    (id) => ({
      id,
      label: id === "cli" ? "CLI" : id,
    }),
  );

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      {loading || error ? (
        // Keep the page chrome mounted while loading or failing, so the header
        // does not pop in after the fact and shift the content down.
        <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
          <PageHeader
            kicker={t("tools.kicker")}
            title={t("tools.title")}
            description={t("tools.descOff")}
          />
          <p
            className="rounded-xl border border-border bg-card px-4 py-10 text-center text-sm text-muted-foreground"
            {...(error ? { role: "alert" as const } : {})}
          >
            {error ? localizeError(locale, error) : t("tools.loading")}
          </p>
        </div>
      ) : (
        <CatalogPage
          kicker={t("tools.kicker")}
          title={t("tools.title")}
          description={data?.writable ? t("tools.descOn") : t("tools.descOff")}
          overview={
            <HermesSystemToolsPanel writable={Boolean(data?.writable)} />
          }
          groups={groups}
          empty={t("tools.empty")}
          rows={rows.map((tool) => ({
            id: tool.id,
            title: tool.label,
            name: tool.name,
            description: tool.description,
            group: tool.platform || "cli",
            groupLabel:
              tool.platform === "cli" || !tool.platform ? "CLI" : tool.platform,
            meta:
              tool.tools.slice(0, 6).join(", ") ||
              (tool.configured === false ? t("tools.noKeys") : undefined),
            enabled: tool.enabled,
          }))}
          onToggle={
            data?.writable
              ? (id) => {
                  const row = rows.find((tool) => tool.id === id);
                  if (!row || !data) return;
                  const enabled = !row.enabled;
                  setData({
                    ...data,
                    toolsets: data.toolsets.map((tool) =>
                      tool.id === id ? { ...tool, enabled } : tool,
                    ),
                  });
                  void mutateHermes({
                    action: "toggle-toolset",
                    name: row.name,
                    enabled,
                  }).then((r) => {
                    if (r.ok) return;
                    setData({
                      ...data,
                      toolsets: data.toolsets.map((tool) =>
                        tool.id === id
                          ? { ...tool, enabled: row.enabled }
                          : tool,
                      ),
                    });
                  });
                }
              : undefined
          }
          rowActions={(row) => (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label={t("tools.inspectNamed", { name: row.title })}
              onClick={() =>
                setSelected(rows.find((tool) => tool.id === row.id) ?? null)
              }
            >
              <SlidersHorizontal className="size-4" />
            </Button>
          )}
          chatPrompt={(row) => t("tools.prompt", { name: row.name })}
        />
      )}
      <ToolsetDialog
        toolset={selected}
        open={Boolean(selected)}
        onOpenChange={(open) => !open && setSelected(null)}
        onChanged={async () => {
          const fresh = await listHermesLive();
          if (fresh.ok) setData(fresh);
        }}
      />
    </div>
  );
}
