import { createFileRoute } from "@tanstack/react-router";
import { Eye, Plus, RefreshCw, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { CatalogPage } from "@/components/catalog-page";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input, Textarea } from "@/components/ui/input";
import {
  listHermesLive,
  mutateHermes,
  readHermesSkillContent,
  searchHermesSkillsHub,
  waitForHermesAction,
  type HermesSkillHubRow,
  type HermesSkillRow,
} from "@/lib/hermes-live";
import { localizeError, skillGroupLabel } from "@/lib/i18n";
import type { HermesMutation } from "@/lib/hermes-operations";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/skills")({
  component: SkillsPage,
});

const NEW_SKILL_CONTENT = `---
name: my-skill
description: Describe when Hermes should use this skill.
---

# Instructions

Explain the workflow Hermes should follow.
`;

function newSkillContent(name: string): string {
  return NEW_SKILL_CONTENT.replace("name: my-skill", `name: ${name}`);
}

function SkillsPage() {
  const t = useT();
  const locale = useLocale();
  const { data, error, loading, setData } = useHermesLive();
  const rows = data?.skills ?? [];
  // A successful live management read is the most reliable per-function
  // negotiation for dashboard versions that predate `/v1/capabilities`.
  const canManage = Boolean(data?.writable);
  const groups = [
    ...new Map(rows.map((skill) => [skill.group, skill.groupLabel])).entries(),
  ].map(([id, label]) => ({ id, label: skillGroupLabel(locale, id, label) }));
  const [inspectSkill, setInspectSkill] = useState<HermesSkillRow | null>(null);
  const [inspectContent, setInspectContent] = useState("");
  const [inspectLoading, setInspectLoading] = useState(false);
  const [createOpen, setCreateOpen] = useState(false);
  const [createName, setCreateName] = useState("my-skill");
  const [createCategory, setCreateCategory] = useState("");
  const [createContent, setCreateContent] = useState(NEW_SKILL_CONTENT);
  const [installOpen, setInstallOpen] = useState(false);
  const [identifier, setIdentifier] = useState("");
  const [hubQuery, setHubQuery] = useState("");
  const [hubResults, setHubResults] = useState<HermesSkillHubRow[]>([]);
  const [searchingHub, setSearchingHub] = useState(false);
  const [hubSearched, setHubSearched] = useState(false);
  const [removeSkill, setRemoveSkill] = useState<HermesSkillRow | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<string | null>(null);
  const [lifetime] = useState(() => new AbortController());

  useEffect(() => () => lifetime.abort(), [lifetime]);

  useEffect(() => {
    if (!inspectSkill) return;
    const controller = new AbortController();
    setInspectLoading(true);
    setFeedback(null);
    void readHermesSkillContent({
      name: inspectSkill.name,
      signal: controller.signal,
    }).then((result) => {
      if (controller.signal.aborted) return;
      setInspectLoading(false);
      if (result.ok) setInspectContent(result.content);
      else setFeedback(localizeError(locale, result.error));
    });
    return () => controller.abort();
  }, [inspectSkill, locale]);

  async function refresh(): Promise<boolean> {
    const fresh = await listHermesLive();
    if (!fresh.ok) {
      setFeedback(localizeError(locale, fresh.error));
      return false;
    }
    setData(fresh);
    return true;
  }

  async function runMutation(
    key: string,
    mutation: HermesMutation,
    success: string,
  ): Promise<boolean> {
    if (busy) return false;
    setBusy(key);
    setFeedback(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setFeedback(localizeError(locale, result.error));
      setBusy(null);
      return false;
    }
    if (result.actionName) {
      const completed = await waitForHermesAction({
        name: result.actionName,
        signal: lifetime.signal,
      });
      if (!completed.ok) {
        setFeedback(localizeError(locale, completed.error));
        setBusy(null);
        return false;
      }
    }
    const refreshed = await refresh();
    setBusy(null);
    if (refreshed) setFeedback(success);
    return refreshed;
  }

  async function installSkill(requestedIdentifier?: string) {
    const value = (requestedIdentifier ?? identifier).trim();
    if (!value) return;
    if (
      await runMutation(
        "install",
        { action: "skill-install", identifier: value },
        t("skills.installed"),
      )
    ) {
      setIdentifier("");
      setInstallOpen(false);
    }
  }

  async function searchHub() {
    const query = hubQuery.trim();
    if (!query || searchingHub) return;
    setSearchingHub(true);
    setFeedback(null);
    const result = await searchHermesSkillsHub({ query });
    setSearchingHub(false);
    setHubSearched(true);
    if (result.ok) setHubResults(result.results);
    else setFeedback(localizeError(locale, result.error));
  }

  async function createSkill() {
    if (!createName.trim() || !createContent.trim()) return;
    if (
      await runMutation(
        "create",
        {
          action: "skill-create",
          name: createName,
          category: createCategory || undefined,
          content: createContent,
        },
        t("skills.created"),
      )
    ) {
      setCreateOpen(false);
      setCreateName("my-skill");
      setCreateCategory("");
      setCreateContent(NEW_SKILL_CONTENT);
    }
  }

  async function saveInspectedSkill() {
    if (!inspectSkill || inspectSkill.provenance !== "agent") return;
    if (
      await runMutation(
        `edit:${inspectSkill.name}`,
        {
          action: "skill-edit",
          name: inspectSkill.name,
          content: inspectContent,
        },
        t("skills.saved"),
      )
    ) {
      setInspectSkill(null);
    }
  }

  async function confirmRemove() {
    if (!removeSkill) return;
    const mutation: HermesMutation =
      removeSkill.provenance === "hub"
        ? {
            action: "skill-uninstall",
            name: removeSkill.name,
            confirm: true,
          }
        : {
            action: "skill-delete",
            name: removeSkill.name,
            confirm: true,
          };
    if (
      await runMutation(
        `remove:${removeSkill.name}`,
        mutation,
        t("skills.removed"),
      )
    ) {
      setRemoveSkill(null);
      if (inspectSkill?.name === removeSkill.name) setInspectSkill(null);
    }
  }

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
          description={canManage ? t("skills.descOn") : t("skills.descOff")}
          action={
            canManage ? (
              <div className="flex flex-wrap justify-end gap-2">
                <Button
                  variant="ghost"
                  disabled={Boolean(busy)}
                  onClick={() =>
                    void runMutation(
                      "update",
                      { action: "skills-update" },
                      t("skills.updated"),
                    )
                  }
                >
                  <RefreshCw />
                  {busy === "update"
                    ? t("skills.updating")
                    : t("skills.update")}
                </Button>
                <Button
                  variant="outline"
                  disabled={Boolean(busy)}
                  onClick={() => setInstallOpen(true)}
                >
                  <Plus />
                  {t("skills.install")}
                </Button>
                <Button
                  disabled={Boolean(busy)}
                  onClick={() => setCreateOpen(true)}
                >
                  <Plus />
                  {t("skills.create")}
                </Button>
              </div>
            ) : undefined
          }
          groups={groups}
          empty={t("skills.empty")}
          rows={rows.map((skill) => ({
            id: skill.id,
            title: skill.title,
            name: skill.name,
            description: skill.description,
            group: skill.group,
            groupLabel: skillGroupLabel(locale, skill.group, skill.groupLabel),
            meta: skill.provenance,
            enabled: skill.enabled,
          }))}
          onToggle={
            canManage
              ? (id) => {
                  const row = rows.find((skill) => skill.id === id);
                  if (!row || !data || busy) return;
                  const enabled = !row.enabled;
                  setData({
                    ...data,
                    skills: data.skills.map((skill) =>
                      skill.id === id ? { ...skill, enabled } : skill,
                    ),
                  });
                  void mutateHermes({
                    action: "toggle-skill",
                    name: row.name,
                    enabled,
                  }).then((result) => {
                    if (result.ok) return;
                    setFeedback(localizeError(locale, result.error));
                    setData({
                      ...data,
                      skills: data.skills.map((skill) =>
                        skill.id === id
                          ? { ...skill, enabled: row.enabled }
                          : skill,
                      ),
                    });
                  });
                }
              : undefined
          }
          rowActions={(row) => {
            const skill = rows.find((item) => item.id === row.id);
            if (!skill) return null;
            const removable =
              canManage &&
              (skill.provenance === "agent" || skill.provenance === "hub");
            return (
              <>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  disabled={Boolean(busy)}
                  aria-label={t("skills.inspect")}
                  onClick={() => setInspectSkill(skill)}
                >
                  <Eye className="size-4" />
                </Button>
                {removable ? (
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    disabled={Boolean(busy)}
                    aria-label={t("skills.remove")}
                    onClick={() => setRemoveSkill(skill)}
                  >
                    <Trash2 className="size-4" />
                  </Button>
                ) : null}
              </>
            );
          }}
          chatPrompt={(row) => t("skills.prompt", { name: row.name })}
        />
      )}

      {feedback ? (
        <p
          role="status"
          className="fixed right-4 bottom-4 z-40 max-w-[min(28rem,calc(100%-2rem))] whitespace-pre-wrap rounded-md bg-popover px-3 py-2 text-sm border border-border"
        >
          {feedback}
        </p>
      ) : null}

      <Dialog open={installOpen} onOpenChange={setInstallOpen}>
        <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t("skills.installTitle")}</DialogTitle>
            <DialogDescription>
              {t("skills.installDescription")}
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-2">
            <label className="text-sm">{t("skills.hubSearch")}</label>
            <div className="flex gap-2">
              <Input
                value={hubQuery}
                onChange={(event) => {
                  setHubQuery(event.target.value);
                  setHubResults([]);
                  setHubSearched(false);
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    void searchHub();
                  }
                }}
                placeholder={t("skills.hubSearchPlaceholder")}
              />
              <Button
                variant="outline"
                disabled={!hubQuery.trim() || searchingHub || Boolean(busy)}
                onClick={() => void searchHub()}
              >
                {searchingHub ? t("skills.searching") : t("catalog.search")}
              </Button>
            </div>
            {hubResults.length ? (
              <ul className="alice-record-list max-h-64 overflow-y-auto rounded-md border border-border">
                {hubResults.map((result) => (
                  <li
                    key={result.identifier}
                    className="alice-record flex items-start gap-3 px-3 py-3 not-last:border-b not-last:border-border"
                  >
                    <div className="min-w-0 flex-1">
                      <p className="font-medium">{result.name}</p>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {result.description}
                      </p>
                      <p className="mt-1 text-2xs text-muted-foreground">
                        {[result.source, result.trust]
                          .filter(Boolean)
                          .join(" · ")}
                      </p>
                    </div>
                    <Button
                      size="sm"
                      disabled={Boolean(busy)}
                      onClick={() => void installSkill(result.identifier)}
                    >
                      {busy === "install"
                        ? t("skills.installing")
                        : t("skills.install")}
                    </Button>
                  </li>
                ))}
              </ul>
            ) : hubSearched && !searchingHub ? (
              <p className="text-xs text-muted-foreground">
                {t("skills.noHubResults")}
              </p>
            ) : null}
          </div>
          <div className="h-px bg-border" />
          <label className="grid gap-1.5 text-sm">
            {t("skills.identifier")}
            <Input
              value={identifier}
              onChange={(event) => setIdentifier(event.target.value)}
              placeholder="official/research/arxiv"
            />
          </label>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(busy)}
              onClick={() => setInstallOpen(false)}
            >
              {t("skills.cancel")}
            </Button>
            <Button
              disabled={!identifier.trim() || Boolean(busy)}
              onClick={() => void installSkill()}
            >
              {busy === "install"
                ? t("skills.installing")
                : t("skills.install")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t("skills.createTitle")}</DialogTitle>
          </DialogHeader>
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="grid gap-1.5 text-sm">
              {t("skills.name")}
              <Input
                value={createName}
                onChange={(event) => {
                  const next = event.target.value;
                  setCreateContent((current) =>
                    current === newSkillContent(createName)
                      ? newSkillContent(next)
                      : current,
                  );
                  setCreateName(next);
                }}
              />
            </label>
            <label className="grid gap-1.5 text-sm">
              {t("skills.category")}
              <Input
                value={createCategory}
                onChange={(event) => setCreateCategory(event.target.value)}
                placeholder="productivity"
              />
            </label>
          </div>
          <label className="grid gap-1.5 text-sm">
            {t("skills.content")}
            <Textarea
              className="min-h-72 resize-y rounded-md bg-muted p-3 font-mono text-xs border border-border"
              value={createContent}
              onChange={(event) => setCreateContent(event.target.value)}
            />
          </label>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(busy)}
              onClick={() => setCreateOpen(false)}
            >
              {t("skills.cancel")}
            </Button>
            <Button
              disabled={
                !createName.trim() || !createContent.trim() || Boolean(busy)
              }
              onClick={() => void createSkill()}
            >
              {busy === "create" ? t("skills.saving") : t("skills.save")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(inspectSkill)}
        onOpenChange={(open) => !open && setInspectSkill(null)}
      >
        <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {t(
                inspectSkill?.provenance === "agent"
                  ? "skills.editTitle"
                  : "skills.inspectTitle",
                { name: inspectSkill?.name ?? "" },
              )}
            </DialogTitle>
            {inspectSkill?.provenance !== "agent" ? (
              <DialogDescription>{t("skills.readOnly")}</DialogDescription>
            ) : null}
          </DialogHeader>
          {inspectLoading ? (
            <p className="py-8 text-sm text-muted-foreground">
              {t("skills.loading")}
            </p>
          ) : (
            <Textarea
              readOnly={inspectSkill?.provenance !== "agent"}
              className="min-h-[50dvh] resize-y rounded-md bg-muted p-3 font-mono text-xs border border-border"
              value={inspectContent}
              onChange={(event) => setInspectContent(event.target.value)}
            />
          )}
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setInspectSkill(null)}>
              {t("skills.cancel")}
            </Button>
            {inspectSkill?.provenance === "agent" ? (
              <Button
                disabled={
                  inspectLoading || !inspectContent.trim() || Boolean(busy)
                }
                onClick={() => void saveInspectedSkill()}
              >
                {busy === `edit:${inspectSkill.name}`
                  ? t("skills.saving")
                  : t("skills.save")}
              </Button>
            ) : null}
          </div>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(removeSkill)}
        onOpenChange={(open) => !open && !busy && setRemoveSkill(null)}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t("skills.removeTitle", { name: removeSkill?.name ?? "" })}
            </DialogTitle>
            <DialogDescription>
              {t("skills.removeDescription")}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(busy)}
              onClick={() => setRemoveSkill(null)}
            >
              {t("skills.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={Boolean(busy)}
              onClick={() => void confirmRemove()}
            >
              {busy?.startsWith("remove:")
                ? t("skills.removing")
                : t("skills.remove")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
