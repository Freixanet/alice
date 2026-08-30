import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { LearnSkillButton } from "@/components/learn-skill";
import { mutateHermes } from "@/lib/hermes-live";
import { localizeError, skillGroupLabel } from "@/lib/i18n";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/skills")({
  component: SkillsPage,
});

function SkillsPage() {
  const t = useT();
  const locale = useLocale();
  const { data, error, loading, setData } = useHermesLive();
  const rows = data?.skills ?? [];
  const groups = [
    ...new Map(rows.map((s) => [s.group, s.groupLabel])).entries(),
  ].map(([id, label]) => ({ id, label: skillGroupLabel(locale, id, label) }));

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      {loading ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">
          {t("skills.loading")}
        </p>
      ) : error ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">
          {localizeError(locale, error)}
        </p>
      ) : (
        <CatalogPage
          kicker={t("skills.kicker")}
          title={t("skills.title")}
          description={
            data?.writable ? t("skills.descOn") : t("skills.descOff")
          }
          action={<LearnSkillButton />}
          groups={groups}
          empty={t("skills.empty")}
          rows={rows.map((s) => ({
            id: s.id,
            title: s.title,
            name: s.name,
            description: s.description,
            group: s.group,
            groupLabel: skillGroupLabel(locale, s.group, s.groupLabel),
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
                    skills: data.skills.map((s) =>
                      s.id === id ? { ...s, enabled } : s,
                    ),
                  });
                  void mutateHermes({
                    action: "toggle-skill",
                    name: row.name,
                    enabled,
                  }).then((r) => {
                    if (r.ok) return;
                    setData({
                      ...data,
                      skills: data.skills.map((s) =>
                        s.id === id ? { ...s, enabled: row.enabled } : s,
                      ),
                    });
                  });
                }
              : undefined
          }
          chatPrompt={(row) => t("skills.prompt", { name: row.name })}
        />
      )}
    </div>
  );
}
