import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Plus } from "lucide-react";
import { useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { localizeError } from "@/lib/i18n";
import { listHermesLive, mutateHermes } from "@/lib/hermes-live";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/projects")({
  component: ProjectsPage,
});

function ProjectsPage() {
  const t = useT();
  const locale = useLocale();
  const navigate = useNavigate();
  const { data, error, loading, setData } = useHermesLive();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [path, setPath] = useState("");
  const [description, setDescription] = useState("");
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const projects = (data?.projects ?? []).filter((p) => !p.archived);

  async function createProject() {
    const projectName = name.trim();
    const projectPath = path.trim();
    if (!projectName || !projectPath || creating) return;
    setCreating(true);
    setCreateError(null);
    const result = await mutateHermes({
      action: "project-create",
      name: projectName,
      path: projectPath,
      description: description.trim(),
    });
    if (!result.ok) {
      setCreateError(result.error || t("projects.createError"));
      setCreating(false);
      return;
    }
    const fresh = await listHermesLive();
    if (fresh.ok) setData(fresh);
    setCreating(false);
    setOpen(false);
    setName("");
    setPath("");
    setDescription("");
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("projects.kicker")}
          title={t("projects.title")}
          description={t("projects.description")}
          action={
            <Button
              disabled={loading}
              onClick={() =>
                data?.writable
                  ? setOpen(true)
                  : void navigate({ to: "/connect" })
              }
            >
              <Plus />
              {t("projects.new")}
            </Button>
          }
        />
        {loading ? (
          <p className="text-sm text-muted-foreground">
            {t("projects.loading")}
          </p>
        ) : error ? (
          <p className="text-sm text-muted-foreground">
            {localizeError(locale, error)}
          </p>
        ) : projects.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground shadow-border">
            {data?.writable ? t("projects.emptyOn") : t("projects.emptyOff")}
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {projects.map((project) => (
              <li
                key={project.id}
                className="rounded-xl bg-card px-4 py-4 shadow-border"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="font-medium">{project.name}</h2>
                  {project.slug ? (
                    <Badge variant="mute">{project.slug}</Badge>
                  ) : null}
                </div>
                {project.description ? (
                  <p className="mt-1 text-sm text-muted-foreground">
                    {project.description}
                  </p>
                ) : null}
                {project.path ? (
                  <p className="mt-2 font-mono text-2xs text-muted-foreground">
                    {project.path}
                  </p>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </div>
      <Dialog
        open={open}
        onOpenChange={(next) => {
          if (!creating) setOpen(next);
          if (next) setCreateError(null);
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t("projects.createTitle")}</DialogTitle>
            <DialogDescription>
              {t("projects.createDescription")}
            </DialogDescription>
          </DialogHeader>
          <form
            className="flex flex-col gap-4"
            onSubmit={(event) => {
              event.preventDefault();
              void createProject();
            }}
          >
            <label className="flex flex-col gap-1.5 text-sm">
              {t("projects.name")}
              <Input
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder={t("projects.namePlaceholder")}
                autoFocus
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              {t("projects.folder")}
              <Input
                value={path}
                onChange={(event) => setPath(event.target.value)}
                placeholder={t("projects.folderPlaceholder")}
                spellCheck={false}
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              {t("projects.about")}
              <textarea
                value={description}
                onChange={(event) => setDescription(event.target.value)}
                placeholder={t("projects.aboutPlaceholder")}
                className="min-h-24 resize-none rounded-md bg-muted px-3 py-2 text-base text-foreground shadow-border placeholder:text-muted-foreground/80 focus-visible:outline-none md:text-sm"
              />
            </label>
            {createError ? (
              <p className="text-sm text-destructive">
                {localizeError(locale, createError)}
              </p>
            ) : null}
            <div className="flex justify-end gap-2">
              <Button
                type="button"
                variant="ghost"
                onClick={() => setOpen(false)}
                disabled={creating}
              >
                {t("projects.cancel")}
              </Button>
              <Button
                type="submit"
                disabled={creating || !name.trim() || !path.trim()}
              >
                {creating ? t("projects.creating") : t("projects.create")}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
