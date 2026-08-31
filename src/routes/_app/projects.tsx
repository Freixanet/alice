import { createFileRoute, useNavigate } from "@tanstack/react-router";
import {
  Archive,
  Check,
  FolderPlus,
  Pencil,
  Plus,
  RotateCcw,
  Trash2,
} from "lucide-react";
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
import { Switch } from "@/components/ui/switch";
import { listHermesLive, mutateHermes } from "@/lib/hermes-live";
import type {
  HermesProjectFolder,
  HermesProjectRow,
} from "@/lib/hermes-live-types";
import type { HermesMutation } from "@/lib/hermes-operations";
import { localizeError } from "@/lib/i18n";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/projects")({
  component: ProjectsPage,
});

type Confirmation =
  | { kind: "archive"; project: HermesProjectRow }
  | {
      kind: "remove-folder";
      project: HermesProjectRow;
      folder: HermesProjectFolder;
    };

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
  const [actionError, setActionError] = useState<string | null>(null);
  const [manageProject, setManageProject] = useState<HermesProjectRow | null>(
    null,
  );
  const [projectName, setProjectName] = useState("");
  const [board, setBoard] = useState("");
  const [folderPath, setFolderPath] = useState("");
  const [folderLabel, setFolderLabel] = useState("");
  const [folderPrimary, setFolderPrimary] = useState(false);
  const [pending, setPending] = useState<string | null>(null);
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const projects = data?.projects ?? [];
  const visibleProjects = projects.filter(
    (project) => showArchived || !project.archived,
  );
  const hasArchived = projects.some((project) => project.archived);
  const canManage = Boolean(data?.writable && data.local && data.owner);

  async function refresh(selectedId?: string) {
    const fresh = await listHermesLive();
    if (!fresh.ok) return;
    setData(fresh);
    if (selectedId) {
      setManageProject(
        fresh.projects.find((project) => project.id === selectedId) ?? null,
      );
    }
  }

  async function runMutation(
    mutation: HermesMutation,
    pendingKey: string,
    selectedId?: string,
  ) {
    if (pending) return false;
    setPending(pendingKey);
    setActionError(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setActionError(result.error || t("projects.actionError"));
      setPending(null);
      return false;
    }
    await refresh(selectedId);
    setPending(null);
    return true;
  }

  function openManager(project: HermesProjectRow) {
    setActionError(null);
    setManageProject(project);
    setProjectName(project.name);
    setBoard(project.boardSlug ?? "");
    setFolderPath("");
    setFolderLabel("");
    setFolderPrimary(false);
  }

  async function createProject() {
    const projectNameValue = name.trim();
    const projectPath = path.trim();
    if (!projectNameValue || !projectPath || creating) return;
    setCreating(true);
    setActionError(null);
    const result = await mutateHermes({
      action: "project-create",
      name: projectNameValue,
      path: projectPath,
      description: description.trim(),
    });
    if (!result.ok) {
      setActionError(result.error || t("projects.createError"));
      setCreating(false);
      return;
    }
    await refresh();
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
              disabled={loading || Boolean(data?.writable && !canManage)}
              title={
                data?.writable && !canManage
                  ? t("projects.localOnly")
                  : undefined
              }
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
        {data?.writable && !canManage ? (
          <p className="text-sm text-muted-foreground">
            {t("projects.localOnly")}
          </p>
        ) : null}
        {hasArchived ? (
          <div className="flex items-center justify-end gap-2">
            <span className="text-sm text-muted-foreground">
              {t("projects.showArchived")}
            </span>
            <Switch
              checked={showArchived}
              onCheckedChange={setShowArchived}
              aria-label={t("projects.showArchived")}
            />
          </div>
        ) : null}
        {loading ? (
          <p className="text-sm text-muted-foreground">
            {t("projects.loading")}
          </p>
        ) : error ? (
          <p className="text-sm text-muted-foreground">
            {localizeError(locale, error)}
          </p>
        ) : visibleProjects.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-12 text-center text-sm text-muted-foreground border border-border">
            {data?.writable ? t("projects.emptyOn") : t("projects.emptyOff")}
          </div>
        ) : (
          <ul className="alice-record-list flex flex-col gap-2">
            {visibleProjects.map((project) => (
              <li
                key={project.id}
                className="alice-record rounded-xl bg-card px-4 py-4"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="font-medium">{project.name}</h2>
                      {project.active ? (
                        <Badge variant="live">{t("projects.active")}</Badge>
                      ) : null}
                      {project.archived ? (
                        <Badge variant="outline">
                          {t("projects.archived")}
                        </Badge>
                      ) : null}
                      {project.slug ? (
                        <Badge variant="mute">{project.slug}</Badge>
                      ) : null}
                      {project.boardSlug ? (
                        <Badge variant="mute">{project.boardSlug}</Badge>
                      ) : null}
                    </div>
                    {project.description ? (
                      <p className="mt-1 text-sm text-muted-foreground">
                        {project.description}
                      </p>
                    ) : null}
                    {project.path ? (
                      <p className="mt-2 break-all font-mono text-2xs text-muted-foreground">
                        {project.path}
                      </p>
                    ) : null}
                  </div>
                  {canManage ? (
                    <div className="flex shrink-0 items-center gap-1">
                      {!project.archived && !project.active ? (
                        <Button
                          variant="ghost"
                          aria-label={t("projects.activate")}
                          disabled={Boolean(pending)}
                          onClick={() =>
                            void runMutation(
                              {
                                action: "project-activate",
                                projectId: project.id,
                              },
                              `activate:${project.id}`,
                            )
                          }
                        >
                          <Check />
                          <span className="hidden sm:inline">
                            {t("projects.activate")}
                          </span>
                        </Button>
                      ) : null}
                      {project.archived ? (
                        <Button
                          variant="ghost"
                          aria-label={t("projects.restore")}
                          disabled={Boolean(pending)}
                          onClick={() =>
                            void runMutation(
                              {
                                action: "project-restore",
                                projectId: project.id,
                              },
                              `restore:${project.id}`,
                            )
                          }
                        >
                          <RotateCcw />
                          <span className="hidden sm:inline">
                            {t("projects.restore")}
                          </span>
                        </Button>
                      ) : (
                        <Button
                          variant="ghost"
                          aria-label={t("projects.manage")}
                          disabled={Boolean(pending)}
                          onClick={() => openManager(project)}
                        >
                          <Pencil />
                          <span className="hidden sm:inline">
                            {t("projects.manage")}
                          </span>
                        </Button>
                      )}
                    </div>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        )}
        {actionError && !open && !manageProject ? (
          <p className="text-sm text-destructive">
            {localizeError(locale, actionError)}
          </p>
        ) : null}
      </div>

      <CreateProjectDialog
        open={open}
        creating={creating}
        error={actionError}
        name={name}
        path={path}
        description={description}
        locale={locale}
        onNameChange={setName}
        onPathChange={setPath}
        onDescriptionChange={setDescription}
        onOpenChange={(next) => {
          if (!creating) setOpen(next);
          if (next) setActionError(null);
        }}
        onCreate={createProject}
      />

      <Dialog
        open={Boolean(manageProject)}
        onOpenChange={(next) => {
          if (!next && !pending) setManageProject(null);
        }}
      >
        <DialogContent className="max-h-[min(90dvh,760px)] max-w-xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t("projects.manageTitle")}</DialogTitle>
            <DialogDescription>
              {t("projects.manageDescription")}
            </DialogDescription>
          </DialogHeader>
          {manageProject ? (
            <div className="flex flex-col gap-6">
              <section className="flex flex-col gap-3">
                <h3 className="text-sm font-medium">{t("projects.rename")}</h3>
                <div className="flex flex-col gap-2 sm:flex-row">
                  <Input
                    value={projectName}
                    onChange={(event) => setProjectName(event.target.value)}
                  />
                  <Button
                    disabled={
                      Boolean(pending) ||
                      !projectName.trim() ||
                      projectName.trim() === manageProject.name
                    }
                    onClick={() =>
                      void runMutation(
                        {
                          action: "project-rename",
                          projectId: manageProject.id,
                          name: projectName.trim(),
                        },
                        `rename:${manageProject.id}`,
                        manageProject.id,
                      )
                    }
                  >
                    {t("projects.saveName")}
                  </Button>
                </div>
              </section>

              <section className="flex flex-col gap-3">
                <h3 className="text-sm font-medium">{t("projects.board")}</h3>
                <div className="flex flex-col gap-2 sm:flex-row">
                  <Input
                    value={board}
                    onChange={(event) => setBoard(event.target.value)}
                    placeholder={t("projects.boardPlaceholder")}
                    spellCheck={false}
                  />
                  <Button
                    disabled={
                      Boolean(pending) ||
                      board.trim() === (manageProject.boardSlug ?? "")
                    }
                    onClick={() =>
                      void runMutation(
                        {
                          action: "project-bind-board",
                          projectId: manageProject.id,
                          board: board.trim(),
                        },
                        `board:${manageProject.id}`,
                        manageProject.id,
                      )
                    }
                  >
                    {board.trim()
                      ? t("projects.saveBoard")
                      : t("projects.unbindBoard")}
                  </Button>
                </div>
              </section>

              <section className="flex flex-col gap-3">
                <h3 className="text-sm font-medium">{t("projects.folders")}</h3>
                {manageProject.folders.length ? (
                  <ul className="divide-y divide-border border border-border">
                    {manageProject.folders.map((folder) => (
                      <li
                        key={folder.path}
                        className="flex flex-col gap-3 px-3 py-3 sm:flex-row sm:items-center sm:justify-between"
                      >
                        <div className="min-w-0">
                          <div className="flex flex-wrap items-center gap-2">
                            <p className="break-all font-mono text-xs">
                              {folder.path}
                            </p>
                            {folder.primary ? (
                              <Badge variant="live">
                                {t("projects.primary")}
                              </Badge>
                            ) : null}
                          </div>
                          {folder.label ? (
                            <p className="mt-1 text-xs text-muted-foreground">
                              {folder.label}
                            </p>
                          ) : null}
                        </div>
                        <div className="flex shrink-0 items-center gap-1">
                          {!folder.primary ? (
                            <Button
                              variant="ghost"
                              disabled={Boolean(pending)}
                              onClick={() =>
                                void runMutation(
                                  {
                                    action: "project-set-primary",
                                    projectId: manageProject.id,
                                    path: folder.path,
                                  },
                                  `primary:${folder.path}`,
                                  manageProject.id,
                                )
                              }
                            >
                              <Check />
                              {t("projects.makePrimary")}
                            </Button>
                          ) : null}
                          <Button
                            variant="ghost"
                            size="icon"
                            aria-label={t("projects.removeFolder")}
                            disabled={Boolean(pending)}
                            onClick={() =>
                              setConfirmation({
                                kind: "remove-folder",
                                project: manageProject,
                                folder,
                              })
                            }
                          >
                            <Trash2 />
                          </Button>
                        </div>
                      </li>
                    ))}
                  </ul>
                ) : null}
                <div className="flex flex-col gap-3 bg-muted/45 p-3 border border-border">
                  <label className="flex flex-col gap-1.5 text-sm">
                    {t("projects.folder")}
                    <Input
                      value={folderPath}
                      onChange={(event) => setFolderPath(event.target.value)}
                      placeholder={t("projects.folderPlaceholder")}
                      spellCheck={false}
                    />
                  </label>
                  <label className="flex flex-col gap-1.5 text-sm">
                    {t("projects.folderLabel")}
                    <Input
                      value={folderLabel}
                      onChange={(event) => setFolderLabel(event.target.value)}
                      placeholder={t("projects.folderLabelPlaceholder")}
                    />
                  </label>
                  <div className="flex items-center justify-between gap-3">
                    <span className="text-sm">{t("projects.primary")}</span>
                    <Switch
                      checked={folderPrimary}
                      onCheckedChange={setFolderPrimary}
                      aria-label={t("projects.primary")}
                    />
                  </div>
                  <Button
                    variant="outline"
                    disabled={Boolean(pending) || !folderPath.trim()}
                    onClick={() => {
                      const selectedId = manageProject.id;
                      void runMutation(
                        {
                          action: "project-add-folder",
                          projectId: selectedId,
                          path: folderPath.trim(),
                          label: folderLabel.trim(),
                          primary: folderPrimary,
                        },
                        `add-folder:${selectedId}`,
                        selectedId,
                      ).then((ok) => {
                        if (!ok) return;
                        setFolderPath("");
                        setFolderLabel("");
                        setFolderPrimary(false);
                      });
                    }}
                  >
                    <FolderPlus />
                    {t("projects.addFolder")}
                  </Button>
                </div>
              </section>

              {actionError ? (
                <p className="text-sm text-destructive">
                  {localizeError(locale, actionError)}
                </p>
              ) : null}
              <div className="flex flex-wrap justify-between gap-2">
                <Button
                  variant="destructive"
                  disabled={Boolean(pending)}
                  onClick={() =>
                    setConfirmation({
                      kind: "archive",
                      project: manageProject,
                    })
                  }
                >
                  <Archive />
                  {t("projects.archive")}
                </Button>
                <Button
                  variant="ghost"
                  disabled={Boolean(pending)}
                  onClick={() => setManageProject(null)}
                >
                  {t("projects.close")}
                </Button>
              </div>
            </div>
          ) : null}
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(confirmation)}
        onOpenChange={(next) => {
          if (!next && !pending) setConfirmation(null);
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {confirmation?.kind === "archive"
                ? t("projects.archiveTitle")
                : t("projects.removeFolderTitle")}
            </DialogTitle>
            <DialogDescription>
              {confirmation?.kind === "archive"
                ? t("projects.archiveHint", {
                    name: confirmation.project.name,
                  })
                : t("projects.removeFolderHint", {
                    path: confirmation?.folder.path ?? "",
                  })}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(pending)}
              onClick={() => setConfirmation(null)}
            >
              {t("projects.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={!confirmation || Boolean(pending)}
              onClick={() => {
                if (!confirmation) return;
                const selected = confirmation;
                const mutation: HermesMutation =
                  selected.kind === "archive"
                    ? {
                        action: "project-archive",
                        projectId: selected.project.id,
                        confirm: true,
                      }
                    : {
                        action: "project-remove-folder",
                        projectId: selected.project.id,
                        path: selected.folder.path,
                        confirm: true,
                      };
                void runMutation(
                  mutation,
                  `${selected.kind}:${selected.project.id}`,
                  selected.kind === "remove-folder"
                    ? selected.project.id
                    : undefined,
                ).then((ok) => {
                  if (!ok) return;
                  setConfirmation(null);
                  if (selected.kind === "archive") setManageProject(null);
                });
              }}
            >
              {confirmation?.kind === "archive"
                ? t("projects.confirmArchive")
                : t("projects.confirmRemoveFolder")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function CreateProjectDialog({
  open,
  creating,
  error,
  name,
  path,
  description,
  locale,
  onNameChange,
  onPathChange,
  onDescriptionChange,
  onOpenChange,
  onCreate,
}: {
  open: boolean;
  creating: boolean;
  error: string | null;
  name: string;
  path: string;
  description: string;
  locale: ReturnType<typeof useLocale>;
  onNameChange: (value: string) => void;
  onPathChange: (value: string) => void;
  onDescriptionChange: (value: string) => void;
  onOpenChange: (open: boolean) => void;
  onCreate: () => Promise<void>;
}) {
  const t = useT();
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
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
            void onCreate();
          }}
        >
          <label className="flex flex-col gap-1.5 text-sm">
            {t("projects.name")}
            <Input
              value={name}
              onChange={(event) => onNameChange(event.target.value)}
              placeholder={t("projects.namePlaceholder")}
              autoFocus
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            {t("projects.folder")}
            <Input
              value={path}
              onChange={(event) => onPathChange(event.target.value)}
              placeholder={t("projects.folderPlaceholder")}
              spellCheck={false}
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            {t("projects.about")}
            <textarea
              value={description}
              onChange={(event) => onDescriptionChange(event.target.value)}
              placeholder={t("projects.aboutPlaceholder")}
              className="min-h-24 resize-none rounded-md bg-muted px-3 py-2 text-base text-foreground border border-border placeholder:text-muted-foreground/80 focus-visible:outline-none md:text-sm"
            />
          </label>
          {error ? (
            <p className="text-sm text-destructive">
              {localizeError(locale, error)}
            </p>
          ) : null}
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              onClick={() => onOpenChange(false)}
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
  );
}
