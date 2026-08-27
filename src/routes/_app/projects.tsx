import { createFileRoute } from "@tanstack/react-router";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { useHermesLive } from "@/lib/use-hermes-live";

export const Route = createFileRoute("/_app/projects")({
  component: ProjectsPage,
});

function ProjectsPage() {
  const { data, error, loading } = useHermesLive();
  const projects = (data?.projects ?? []).filter((p) => !p.archived);

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker="Hermes"
          title="Proyectos"
          description="Los proyectos nombrados de tu Hermes: una carpeta, un nombre, el contexto con el que trabaja."
        />
        {loading ? (
          <p className="text-sm text-muted-foreground">Leyendo los proyectos de Hermes…</p>
        ) : error ? (
          <p className="text-sm text-muted-foreground">{error}</p>
        ) : projects.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            {data?.writable
              ? "Hermes no tiene proyectos nombrados todavía."
              : "Conecta tu Hermes para ver sus proyectos."}
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {projects.map((project) => (
              <li key={project.id} className="rounded-xl bg-card px-4 py-4 shadow-border">
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="font-medium">{project.name}</h2>
                  {project.slug ? <Badge variant="mute">{project.slug}</Badge> : null}
                </div>
                {project.description ? (
                  <p className="mt-1 text-sm text-muted-foreground">{project.description}</p>
                ) : null}
                {project.path ? (
                  <p className="mt-2 font-mono text-2xs text-muted-foreground">{project.path}</p>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
