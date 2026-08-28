import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { mutateHermes } from "@/lib/hermes-live";
import { localizeError } from "@/lib/i18n";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/addons")({
  component: AddonsPage,
});

function AddonsPage() {
  const t = useT();
  const locale = useLocale();
  const { data, error, loading, setData } = useHermesLive();
  const rows = data?.mcp ?? [];

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      {loading ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">{t("addons.loading")}</p>
      ) : error ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">{localizeError(locale, error)}</p>
      ) : (
        <CatalogPage
          kicker={t("addons.kicker")}
          title={t("addons.title")}
          description={data?.writable ? t("addons.descOn") : t("addons.descOff")}
          groups={[{ id: "mcp", label: "MCP" }]}
          empty={t("addons.empty")}
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
          chatPrompt={(row) => t("addons.prompt", { title: row.title })}
        />
      )}
    </div>
  );
}
