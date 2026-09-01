import { useCallback, useEffect, useMemo, useState } from "react";
import { Check, Plus, Trash2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, Textarea } from "@/components/ui/input";
import { advertisesHermesCapability } from "@/lib/gateway-contracts";
import {
  mutateHermes,
  readHermesProfiles,
  readHermesProfileSoul,
  type HermesProfilesState,
} from "@/lib/hermes-live";
import { localizeError } from "@/lib/i18n";
import { isHermesProfileName } from "@/lib/hermes-profile";
import { useHermes } from "@/lib/store";
import { useLocale, useT } from "@/lib/use-i18n";
import { cn } from "@/lib/utils";

export function HermesProfilesSettings({
  onChatProfile,
}: {
  onChatProfile?: (profile: string) => void;
} = {}) {
  const t = useT();
  const locale = useLocale();
  const connected = useHermes(
    (state) => state.gatewayOn && state.gatewayStatus === "live",
  );
  const manifest = useHermes((state) => state.gatewayMeta?.manifest);
  const selected = useHermes((state) => state.profile);
  const setProfile = useHermes((state) => state.setProfile);
  const supported = advertisesHermesCapability(manifest, "profiles");
  const [profiles, setProfiles] = useState<HermesProfilesState | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [newName, setNewName] = useState("");
  const [cloneSelected, setCloneSelected] = useState(false);
  const [rename, setRename] = useState("");
  const [description, setDescription] = useState("");
  const [soul, setSoul] = useState("");
  const [soulLoading, setSoulLoading] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  const refresh = useCallback(
    async (signal?: AbortSignal) => {
      setLoading(true);
      const result = await readHermesProfiles({ signal });
      if (signal?.aborted) return;
      setLoading(false);
      if (!result.ok) {
        setError(localizeError(locale, result.error));
        return;
      }
      setError(null);
      setProfiles(result.state);
      if (!result.state.profiles.some((profile) => profile.name === selected)) {
        setProfile(result.state.active || result.state.current || "default");
      }
    },
    [locale, selected, setProfile],
  );

  useEffect(() => {
    if (!connected || !supported) {
      setProfiles(null);
      return;
    }
    const controller = new AbortController();
    void refresh(controller.signal);
    return () => controller.abort();
  }, [connected, refresh, supported]);

  const current = useMemo(
    () => profiles?.profiles.find((profile) => profile.name === selected),
    [profiles, selected],
  );

  useEffect(() => {
    setRename(current?.name ?? "");
    setDescription(current?.description ?? "");
    setConfirmDelete(false);
    if (!current) {
      setSoul("");
      return;
    }
    const ctrl = new AbortController();
    setSoulLoading(true);
    void readHermesProfileSoul({
      name: current.name,
      signal: ctrl.signal,
    }).then((result) => {
      if (ctrl.signal.aborted) return;
      setSoulLoading(false);
      if (result.ok) setSoul(result.content);
      else setError(localizeError(locale, result.error));
    });
    return () => ctrl.abort();
  }, [current, locale]);

  async function run(
    key: string,
    mutation: Parameters<typeof mutateHermes>[0],
  ): Promise<boolean> {
    setBusy(key);
    setError(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setError(localizeError(locale, result.error));
      setBusy(null);
      return false;
    }
    await refresh();
    setBusy(null);
    return true;
  }

  if (!connected || !supported) {
    return (
      <p className="text-sm leading-6 text-muted-foreground">
        {t("settings.profilesUnavailable")}
      </p>
    );
  }

  if (loading && !profiles) {
    return (
      <p className="text-sm text-muted-foreground">
        {t("settings.profilesLoading")}
      </p>
    );
  }

  return (
    <div className="space-y-6">
      <p className="text-sm leading-6 text-muted-foreground">
        {t("settings.profileProcessHint")}
      </p>

      <div className="overflow-hidden rounded-md border border-border">
        {profiles?.profiles.map((profile) => {
          const isSelected = profile.name === selected;
          return (
            <div
              key={profile.name}
              className={cn(
                "flex min-h-16 items-center gap-3 border-b border-border px-3 py-2.5 last:border-b-0",
                isSelected && "bg-accent",
              )}
            >
              <button
                type="button"
                className="flex min-h-11 min-w-0 flex-1 items-center gap-3 rounded-md text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                onClick={() => setProfile(profile.name)}
                aria-pressed={isSelected}
              >
                <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-secondary text-xs font-semibold uppercase">
                  {isSelected ? <Check aria-hidden="true" /> : profile.name[0]}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium">
                    {profile.displayName}
                  </span>
                  <span className="block truncate text-xs text-muted-foreground">
                    {profile.provider && profile.model
                      ? `${profile.provider} · ${profile.model}`
                      : t("settings.profileSkills", {
                          count: profile.skillCount,
                        })}
                  </span>
                </span>
              </button>
              <span className="hidden shrink-0 flex-wrap justify-end gap-1 sm:flex">
                {isSelected ? (
                  <Badge variant="outline">
                    {t("settings.profileSelected")}
                  </Badge>
                ) : null}
                {profiles.active === profile.name ? (
                  <Badge variant="outline">{t("settings.profileActive")}</Badge>
                ) : null}
                {profiles.current === profile.name ? (
                  <Badge variant="outline">
                    {t("settings.profileCurrent")}
                  </Badge>
                ) : null}
              </span>
              {onChatProfile ? (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onChatProfile(profile.name)}
                >
                  {t("agents.chat")}
                </Button>
              ) : null}
            </div>
          );
        })}
      </div>

      <div className="flex flex-wrap gap-2">
        <Button
          variant="outline"
          onClick={() => setCreating((value) => !value)}
        >
          <Plus aria-hidden="true" />
          {t("settings.profileCreate")}
        </Button>
        {current && profiles?.active !== current.name ? (
          <Button
            variant="outline"
            disabled={Boolean(busy)}
            onClick={() =>
              void run(`activate:${current.name}`, {
                action: "profile-activate",
                name: current.name,
              })
            }
          >
            {t("settings.profileMakeDefault")}
          </Button>
        ) : null}
      </div>

      {creating ? (
        <form
          className="space-y-3 rounded-md bg-muted p-3 border border-border"
          onSubmit={(event) => {
            event.preventDefault();
            if (!isHermesProfileName(newName.trim())) return;
            void run("create", {
              action: "profile-create",
              name: newName.trim(),
              cloneFrom: cloneSelected ? selected : undefined,
            }).then((ok) => {
              if (!ok) return;
              setProfile(newName.trim());
              setNewName("");
              setCreating(false);
            });
          }}
        >
          <label className="block space-y-1.5 text-sm">
            <span>{t("settings.profileName")}</span>
            <Input
              value={newName}
              onChange={(event) => setNewName(event.target.value.toLowerCase())}
              placeholder="research"
              autoComplete="off"
              spellCheck={false}
            />
            <span className="block text-xs text-muted-foreground">
              {t("settings.profileIdentifierHint")}
            </span>
          </label>
          <label className="flex min-h-11 items-center gap-3 text-sm">
            <input
              type="checkbox"
              checked={cloneSelected}
              onChange={(event) => setCloneSelected(event.target.checked)}
              className="size-5 rounded-sm accent-primary"
            />
            {cloneSelected
              ? t("settings.profileCloneCurrent")
              : t("settings.profileFresh")}
          </label>
          <Button
            type="submit"
            disabled={busy === "create" || !isHermesProfileName(newName.trim())}
          >
            {busy === "create"
              ? t("common.saving")
              : t("settings.profileCreateAction")}
          </Button>
        </form>
      ) : null}

      {current ? (
        <div className="space-y-5 border-t border-border pt-5">
          {!current.isDefault ? (
            <form
              className="space-y-2"
              onSubmit={(event) => {
                event.preventDefault();
                const nextName = rename.trim();
                if (!isHermesProfileName(nextName) || nextName === current.name)
                  return;
                void run(`rename:${current.name}`, {
                  action: "profile-rename",
                  name: current.name,
                  newName: nextName,
                }).then((ok) => {
                  if (ok) setProfile(nextName);
                });
              }}
            >
              <label className="block space-y-1.5 text-sm">
                <span>{t("settings.profileRename")}</span>
                <div className="flex gap-2">
                  <Input
                    value={rename}
                    onChange={(event) =>
                      setRename(event.target.value.toLowerCase())
                    }
                    spellCheck={false}
                  />
                  <Button
                    type="submit"
                    variant="outline"
                    disabled={
                      Boolean(busy) ||
                      !isHermesProfileName(rename.trim()) ||
                      rename.trim() === current.name
                    }
                  >
                    {t("shell.save")}
                  </Button>
                </div>
              </label>
            </form>
          ) : null}

          <form
            className="space-y-2"
            onSubmit={(event) => {
              event.preventDefault();
              void run(`description:${current.name}`, {
                action: "profile-description",
                name: current.name,
                description,
              });
            }}
          >
            <label className="block space-y-1.5 text-sm">
              <span>{t("settings.profileDescription")}</span>
              <Input
                value={description}
                onChange={(event) => setDescription(event.target.value)}
                maxLength={2_000}
              />
            </label>
            <Button type="submit" variant="outline" disabled={Boolean(busy)}>
              {t("settings.profileSaveDescription")}
            </Button>
          </form>

          <form
            className="space-y-2"
            onSubmit={(event) => {
              event.preventDefault();
              void run(`soul:${current.name}`, {
                action: "profile-soul-update",
                name: current.name,
                content: soul,
              });
            }}
          >
            <label className="block space-y-1.5 text-sm">
              <span>{t("settings.profileSoul")}</span>
              <span className="block text-xs text-muted-foreground">
                {t("settings.profileSoulHint")}
              </span>
              <div className="rounded-md bg-muted p-3 border border-border">
                <Textarea
                  value={soul}
                  onChange={(event) => setSoul(event.target.value)}
                  disabled={soulLoading}
                  className="min-h-44 font-mono text-sm"
                  spellCheck={false}
                />
              </div>
            </label>
            <Button type="submit" variant="outline" disabled={Boolean(busy)}>
              {t("settings.profileSaveSoul")}
            </Button>
          </form>

          {!current.isDefault &&
          profiles?.active !== current.name &&
          profiles?.current !== current.name ? (
            <Button
              variant={confirmDelete ? "destructive" : "ghost"}
              disabled={Boolean(busy)}
              onClick={() => {
                if (!confirmDelete) {
                  setConfirmDelete(true);
                  return;
                }
                void run(`delete:${current.name}`, {
                  action: "profile-delete",
                  name: current.name,
                  confirm: true,
                }).then((ok) => {
                  if (ok) setProfile(profiles?.active || "default");
                });
              }}
            >
              <Trash2 aria-hidden="true" />
              {confirmDelete
                ? t("settings.profileDeleteConfirm")
                : t("settings.profileDelete")}
            </Button>
          ) : null}
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
    </div>
  );
}
