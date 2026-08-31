import { useEffect, useState } from "react";
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
  mcpMutationFromDraft,
  type McpAuth,
  type McpDraft,
  type McpTransport,
} from "@/lib/mcp-form";
import type { HermesMutation } from "@/lib/hermes-operations";
import { useT } from "@/lib/use-i18n";
import { cn } from "@/lib/utils";

const EMPTY_DRAFT: McpDraft = {
  name: "",
  transport: "http",
  url: "",
  command: "",
  args: "",
  env: "",
  auth: "none",
  bearerToken: "",
};

export function McpServerDialog({
  open,
  onOpenChange,
  onSave,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSave: (
    mutation: Extract<HermesMutation, { action: "mcp-create" }>,
  ) => Promise<string | null>;
}) {
  const t = useT();
  const [draft, setDraft] = useState<McpDraft>(EMPTY_DRAFT);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      setDraft(EMPTY_DRAFT);
      setSaving(false);
      setError(null);
    }
  }, [open]);

  function set<K extends keyof McpDraft>(key: K, value: McpDraft[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
    setError(null);
  }

  async function submit() {
    if (saving) return;
    const result = mcpMutationFromDraft(draft);
    if (!result.ok) {
      setError(t(`addons.validation.${result.error}`));
      return;
    }
    setSaving(true);
    const saveError = await onSave(result.mutation);
    setSaving(false);
    if (saveError) {
      setError(saveError);
      return;
    }
    onOpenChange(false);
  }

  return (
    <Dialog open={open} onOpenChange={(next) => !saving && onOpenChange(next)}>
      <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t("addons.addTitle")}</DialogTitle>
          <DialogDescription>{t("addons.addDescription")}</DialogDescription>
        </DialogHeader>
        <form
          className="flex flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            void submit();
          }}
        >
          <label className="flex flex-col gap-1.5 text-sm">
            {t("addons.name")}
            <Input
              autoFocus
              value={draft.name}
              onChange={(event) => set("name", event.target.value)}
              placeholder={t("addons.namePlaceholder")}
            />
          </label>

          <fieldset className="flex flex-col gap-2">
            <legend className="text-sm">{t("addons.transport")}</legend>
            <div className="grid grid-cols-2 gap-2">
              {(["http", "stdio"] as McpTransport[]).map((transport) => (
                <button
                  key={transport}
                  type="button"
                  className={cn(
                    "min-h-11 rounded-md px-3 text-sm font-medium border border-border",
                    draft.transport === transport
                      ? "bg-primary text-primary-foreground"
                      : "bg-muted text-foreground",
                  )}
                  onClick={() => set("transport", transport)}
                  aria-pressed={draft.transport === transport}
                >
                  {transport === "http" ? t("addons.http") : t("addons.stdio")}
                </button>
              ))}
            </div>
          </fieldset>

          {draft.transport === "http" ? (
            <>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("addons.url")}
                <Input
                  inputMode="url"
                  spellCheck={false}
                  value={draft.url}
                  onChange={(event) => set("url", event.target.value)}
                  placeholder="https://mcp.example.com/sse"
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("addons.auth")}
                <select
                  className="min-h-11 rounded-md bg-muted px-3 text-base text-foreground border border-border focus-visible:outline-none md:text-sm"
                  value={draft.auth}
                  onChange={(event) =>
                    set("auth", event.target.value as McpAuth)
                  }
                >
                  <option value="none">{t("addons.authNone")}</option>
                  <option value="oauth">OAuth</option>
                  <option value="header">{t("addons.authHeader")}</option>
                </select>
              </label>
              {draft.auth === "header" ? (
                <label className="flex flex-col gap-1.5 text-sm">
                  {t("addons.bearerToken")}
                  <Input
                    type="password"
                    autoComplete="off"
                    value={draft.bearerToken}
                    onChange={(event) => set("bearerToken", event.target.value)}
                  />
                </label>
              ) : null}
            </>
          ) : (
            <>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("addons.command")}
                <Input
                  spellCheck={false}
                  value={draft.command}
                  onChange={(event) => set("command", event.target.value)}
                  placeholder="npx"
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("addons.args")}
                <Textarea
                  spellCheck={false}
                  value={draft.args}
                  onChange={(event) => set("args", event.target.value)}
                  placeholder={t("addons.argsPlaceholder")}
                  className="min-h-24 bg-muted font-mono text-base border border-border md:text-sm"
                />
              </label>
            </>
          )}

          <label className="flex flex-col gap-1.5 text-sm">
            {t("addons.env")}
            <Textarea
              spellCheck={false}
              value={draft.env}
              onChange={(event) => set("env", event.target.value)}
              placeholder="API_KEY=value"
              className="min-h-24 bg-muted font-mono text-base border border-border md:text-sm"
            />
            <span className="text-xs text-muted-foreground">
              {t("addons.envHint")}
            </span>
          </label>

          {error ? (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          ) : null}
          <div className="flex justify-end gap-2">
            <Button
              type="button"
              variant="ghost"
              disabled={saving}
              onClick={() => onOpenChange(false)}
            >
              {t("projects.cancel")}
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? t("addons.adding") : t("addons.add")}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
