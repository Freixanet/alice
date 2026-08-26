import { createFileRoute } from "@tanstack/react-router";
import { CatalogPage } from "@/components/catalog-page";
import { LearnSkillButton } from "@/components/learn-skill";
import { skills, SKILL_CATEGORIES } from "@/lib/catalog";
import { useHermes } from "@/lib/store";

export const Route = createFileRoute("/_app/skills")({
  component: SkillsPage,
});

function SkillsPage() {
  const isSkillOn = useHermes((s) => s.isSkillOn);
  const toggleSkill = useHermes((s) => s.toggleSkill);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <CatalogPage
        kicker="Skills"
        title="Habilidades"
        description="Documentos que Hermes carga solo cuando hacen falta. Activa las que usas; el resto no ocupan contexto."
        action={<LearnSkillButton />}
        groups={SKILL_CATEGORIES}
        rows={skills.map((s) => ({
          id: s.id,
          title: s.title,
          name: s.name,
          description: s.description,
          group: s.category,
          groupLabel: SKILL_CATEGORIES.find((c) => c.id === s.category)?.label ?? s.category,
          trust: s.trust,
          version: s.version,
          meta: s.source,
          enabled: isSkillOn(s.id),
        }))}
        onToggle={toggleSkill}
        chatPrompt={(row) => `Usa la skill ${row.name} para `}
      />
    </div>
  );
}
