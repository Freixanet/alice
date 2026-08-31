import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input, Textarea } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { type HermesWebhooksState } from "@/lib/hermes-live";
import { useHermesMutation } from "@/lib/use-hermes-mutation";
import { useT } from "@/lib/use-i18n";

const DELIVER_OPTIONS = [
  "log",
  "telegram",
  "discord",
  "slack",
  "email",
  "github_comment",
] as const;

type Draft = {
  name: string;
  description: string;
  events: string;
  deliver: string;
  deliverOnly: boolean;
  prompt: string;
  skills: string;
  deliverChatId: string;
};

const EMPTY_DRAFT: Draft = {
  name: "",
  description: "",
  events: "",
  deliver: "log",
  deliverOnly: false,
  prompt: "",
  skills: "",
  deliverChatId: "",
};

export function HermesWebhooksPanel({
  state,
  writable,
  onChanged,
}: {
  state: HermesWebhooksState;
  writable: boolean;
  onChanged: () => Promise<void>;
}) {
  const t = useT();
  const [createOpen, setCreateOpen] = useState(false);
  const [enabledLocally, setEnabledLocally] = useState(false);
  const [draft, setDraft] = useState<Draft>(EMPTY_DRAFT);
  const { busy, error, notice, run, setError, setNotice } =
    useHermesMutation(onChanged);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [created, setCreated] = useState<{
    url: string;
    secret: string;
  } | null>(null);
  const [copied, setCopied] = useState<"url" | "secret" | null>(null);
  const enabled = state.enabled || enabledLocally;

  useEffect(() => {
    if (!createOpen) {
      setDraft(EMPTY_DRAFT);
      setCreated(null);
      setCopied(null);
    }
  }, [createOpen]);

  function update<K extends keyof Draft>(key: K, value: Draft[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
    setError(null);
  }

  async function create() {
    const name = draft.name.trim().toLowerCase().replace(/\s+/g, "-");
    if (!/^[a-z0-9][a-z0-9_-]{0,127}$/.test(name)) {
      setError(t("connect.webhookNameError"));
      return;
    }
    if (draft.deliverOnly && draft.deliver === "log") {
      setError(t("connect.webhookDeliverError"));
      return;
    }
    const result = await run("create", {
      action: "webhook-create",
      name,
      description: optional(draft.description),
      events: list(draft.events),
      prompt: optional(draft.prompt),
      skills: list(draft.skills),
      deliver: draft.deliver,
      deliverOnly: draft.deliverOnly,
      deliverChatId: optional(draft.deliverChatId),
    });
    if (result.ok && result.secret && result.url) {
      setCreated({ secret: result.secret, url: result.url });
      setDraft(EMPTY_DRAFT);
    }
  }

  async function copy(value: string, kind: "url" | "secret") {
    await navigator.clipboard.writeText(value);
    setCopied(kind);
    window.setTimeout(() => setCopied(null), 1_500);
  }

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <h2 className="text-sm font-medium">{t("connect.webhooks")}</h2>
          <Badge variant={enabled ? "live" : "outline"}>
            {enabled ? t("connect.active") : t("connect.off")}
          </Badge>
        </div>
        {writable ? (
          <div className="flex gap-2">
            {!enabled ? (
              <Button
                size="sm"
                className="min-h-11 md:min-h-8"
                disabled={busy !== null}
                onClick={() =>
                  void run("enable", { action: "webhook-enable" }).then(
                    (result) => {
                      if (result.ok) {
                        setEnabledLocally(true);
                        setNotice(t("connect.webhookPlatformEnabled"));
                      }
                    },
                  )
                }
              >
                {t("connect.webhookEnable")}
              </Button>
            ) : null}
            <Button
              size="sm"
              className="min-h-11 md:min-h-8"
              disabled={!enabled || busy !== null}
              onClick={() => setCreateOpen(true)}
            >
              {t("connect.webhookCreate")}
            </Button>
          </div>
        ) : null}
      </div>

      {notice ? (
        <p role="status" className="text-sm text-live">
          {notice}
        </p>
      ) : null}
      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}

      {state.subscriptions.length === 0 ? (
        <div className="rounded-lg border border-border px-4 py-8 text-center text-sm text-muted-foreground">
          {t("connect.webhookEmpty")}
        </div>
      ) : (
        <ul className="divide-y divide-border overflow-hidden rounded-lg border border-border">
          {state.subscriptions.map((hook) => (
            <li key={hook.name} className="bg-card px-4 py-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-medium">{hook.name}</h3>
                    <Badge variant={hook.enabled ? "live" : "outline"}>
                      {hook.enabled ? t("connect.active") : t("connect.off")}
                    </Badge>
                  </div>
                  {hook.description ? (
                    <p className="mt-1 text-sm text-muted-foreground">
                      {hook.description}
                    </p>
                  ) : null}
                  <p className="mt-1 break-all text-xs text-muted-foreground">
                    {hook.events.length
                      ? hook.events.join(", ")
                      : t("connect.webhookAllEvents")}
                    {" · "}
                    {t("connect.webhookDeliverTo", { value: hook.deliver })}
                  </p>
                  {hook.url ? (
                    <p className="mt-1 break-all font-mono text-xs text-muted-foreground">
                      {hook.url}
                    </p>
                  ) : null}
                </div>
                {writable ? (
                  <div className="flex items-center gap-1">
                    <Switch
                      checked={hook.enabled}
                      disabled={busy !== null}
                      aria-label={t("connect.webhookToggle", {
                        name: hook.name,
                      })}
                      onCheckedChange={(enabled) =>
                        void run(`toggle:${hook.name}`, {
                          action: "webhook-toggle",
                          name: hook.name,
                          enabled,
                        }).then((result) => {
                          if (result.ok) setNotice(t("connect.webhookSaved"));
                        })
                      }
                    />
                    <Button
                      size="sm"
                      variant={
                        confirmDelete === hook.name ? "destructive" : "ghost"
                      }
                      className="min-h-11 md:min-h-8"
                      disabled={busy !== null}
                      onClick={() => {
                        if (confirmDelete !== hook.name) {
                          setConfirmDelete(hook.name);
                          return;
                        }
                        void run(`delete:${hook.name}`, {
                          action: "webhook-delete",
                          name: hook.name,
                          confirm: true,
                        }).then((result) => {
                          if (result.ok) {
                            setConfirmDelete(null);
                            setNotice(t("connect.webhookDeleted"));
                          }
                        });
                      }}
                    >
                      {confirmDelete === hook.name
                        ? t("connect.webhookConfirmDelete")
                        : t("common.delete")}
                    </Button>
                  </div>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      )}

      <Dialog
        open={createOpen}
        onOpenChange={(open) => !busy && setCreateOpen(open)}
      >
        <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t("connect.webhookCreateTitle")}</DialogTitle>
            <DialogDescription>
              {created
                ? t("connect.webhookCreatedDescription")
                : t("connect.webhookCreateDescription")}
            </DialogDescription>
          </DialogHeader>
          {created ? (
            <div className="space-y-4">
              <CopyField
                label={t("connect.webhookUrl")}
                value={created.url}
                copied={copied === "url"}
                onCopy={() => void copy(created.url, "url")}
              />
              <CopyField
                label={t("connect.webhookSecret")}
                value={created.secret}
                copied={copied === "secret"}
                onCopy={() => void copy(created.secret, "secret")}
              />
              <p className="text-sm text-muted-foreground">
                {t("connect.webhookSecretOnce")}
              </p>
              <Button className="w-full" onClick={() => setCreateOpen(false)}>
                {t("common.done")}
              </Button>
            </div>
          ) : (
            <form
              className="space-y-4"
              onSubmit={(event) => {
                event.preventDefault();
                void create();
              }}
            >
              <Field label={t("connect.webhookName")}>
                <Input
                  autoFocus
                  value={draft.name}
                  maxLength={128}
                  placeholder="github-push"
                  onChange={(event) => update("name", event.target.value)}
                />
              </Field>
              <Field label={t("connect.webhookDescription")}>
                <Input
                  value={draft.description}
                  maxLength={2_000}
                  onChange={(event) =>
                    update("description", event.target.value)
                  }
                />
              </Field>
              <Field label={t("connect.webhookEvents")}>
                <Input
                  value={draft.events}
                  placeholder="push, pull_request"
                  onChange={(event) => update("events", event.target.value)}
                />
              </Field>
              <Field label={t("connect.webhookDeliver")}>
                <select
                  className="min-h-11 w-full rounded-md bg-muted px-3 text-base text-foreground shadow-border focus-visible:outline-none md:text-sm"
                  value={draft.deliver}
                  onChange={(event) => {
                    const deliver = event.target.value;
                    setDraft((current) => ({
                      ...current,
                      deliver,
                      deliverOnly:
                        deliver === "log" ? false : current.deliverOnly,
                    }));
                    setError(null);
                  }}
                >
                  {DELIVER_OPTIONS.map((option) => (
                    <option key={option} value={option}>
                      {option}
                    </option>
                  ))}
                </select>
              </Field>
              {draft.deliver !== "log" ? (
                <Field label={t("connect.webhookChatId")}>
                  <Input
                    value={draft.deliverChatId}
                    maxLength={256}
                    onChange={(event) =>
                      update("deliverChatId", event.target.value)
                    }
                  />
                </Field>
              ) : null}
              <label className="flex min-h-11 items-center justify-between gap-4 text-sm">
                <span>{t("connect.webhookDeliverOnly")}</span>
                <Switch
                  checked={draft.deliverOnly}
                  disabled={draft.deliver === "log"}
                  onCheckedChange={(checked) => update("deliverOnly", checked)}
                />
              </label>
              <Field label={t("connect.webhookPrompt")}>
                <Textarea
                  className="min-h-24 rounded-md bg-muted p-3 shadow-border"
                  value={draft.prompt}
                  maxLength={8_000}
                  onChange={(event) => update("prompt", event.target.value)}
                />
              </Field>
              <Field label={t("connect.webhookSkills")}>
                <Input
                  value={draft.skills}
                  placeholder="research, writing"
                  onChange={(event) => update("skills", event.target.value)}
                />
              </Field>
              {error ? (
                <p role="alert" className="text-sm text-destructive">
                  {error}
                </p>
              ) : null}
              <Button className="w-full" type="submit" disabled={busy !== null}>
                {busy === "create"
                  ? t("common.saving")
                  : t("connect.webhookCreate")}
              </Button>
            </form>
          )}
        </DialogContent>
      </Dialog>
    </section>
  );
}

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <label className="flex flex-col gap-1.5 text-sm">
      {label}
      {children}
    </label>
  );
}

function CopyField({
  label,
  value,
  copied,
  onCopy,
}: {
  label: string;
  value: string;
  copied: boolean;
  onCopy: () => void;
}) {
  const t = useT();
  return (
    <div className="space-y-1.5">
      <p className="text-sm">{label}</p>
      <div className="flex items-center gap-2 rounded-md bg-muted p-2">
        <code className="min-w-0 flex-1 break-all text-xs">{value}</code>
        <Button
          size="sm"
          variant="ghost"
          className="min-h-11 md:min-h-8"
          onClick={onCopy}
        >
          {copied ? t("connect.commandCopied") : t("connect.copyCommand")}
        </Button>
      </div>
    </div>
  );
}

function optional(value: string): string | undefined {
  const next = value.trim();
  return next || undefined;
}

function list(value: string): string[] | undefined {
  const items = value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  return items.length ? items : undefined;
}
