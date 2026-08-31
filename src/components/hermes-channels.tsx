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
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { type HermesChannelRow } from "@/lib/hermes-live";
import { localizeError, type MsgKey } from "@/lib/i18n";
import { useHermesMutation } from "@/lib/use-hermes-mutation";
import { useLocale, useT } from "@/lib/use-i18n";

export function HermesChannelsPanel({
  channels,
  writable,
  onChanged,
}: {
  channels: HermesChannelRow[];
  writable: boolean;
  onChanged: () => Promise<void>;
}) {
  const t = useT();
  const locale = useLocale();
  const [editing, setEditing] = useState<HermesChannelRow | null>(null);
  const [values, setValues] = useState<Record<string, string>>({});
  const [clear, setClear] = useState<string[]>([]);
  const [enabled, setEnabled] = useState(false);
  const { busy, error, notice, run, setError, setNotice } =
    useHermesMutation(onChanged);
  const [tests, setTests] = useState<
    Record<string, { ok: boolean; message: string }>
  >({});

  useEffect(() => {
    if (!editing) {
      setValues({});
      setClear([]);
      setError(null);
      return;
    }
    setEnabled(editing.enabled);
  }, [editing, setError]);

  function setChannelValue(key: string, value: string) {
    setValues((current) => ({ ...current, [key]: value }));
    setClear((current) => current.filter((item) => item !== key));
  }

  function toggleChannelClear(key: string) {
    setValues((current) => ({ ...current, [key]: "" }));
    setClear((current) =>
      current.includes(key)
        ? current.filter((item) => item !== key)
        : [...current, key],
    );
  }

  async function save() {
    if (!editing) return;
    const env = Object.fromEntries(
      Object.entries(values)
        .map(([key, value]) => [key, value.trim()])
        .filter((entry) => entry[1]),
    );
    const result = await run(`save:${editing.id}`, {
      action: "channel-update",
      platformId: editing.id,
      enabled,
      env: Object.keys(env).length ? env : undefined,
      clearEnv: clear.length ? clear : undefined,
    });
    if (result.ok) {
      setEditing(null);
      setNotice(t("connect.channelSaved"));
    }
  }

  async function test(channel: HermesChannelRow) {
    const result = await run(`test:${channel.id}`, {
      action: "channel-test",
      platformId: channel.id,
    });
    if (result.ok && result.channelTest) {
      setTests((current) => ({
        ...current,
        [channel.id]: {
          ok: result.channelTest!.ok,
          message: result.channelTest!.message,
        },
      }));
    }
  }

  return (
    <section className="space-y-3">
      <h2 className="text-sm font-medium">{t("connect.channels")}</h2>
      {notice ? (
        <p role="status" className="text-sm text-live">
          {notice}
        </p>
      ) : null}
      {error && !editing ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
      {channels.length === 0 ? (
        <div className="rounded-lg border border-border px-4 py-8 text-center text-sm text-muted-foreground">
          {t("connect.noChannels")}
        </div>
      ) : (
        <ul className="divide-y divide-border overflow-hidden rounded-lg border border-border">
          {channels.map((channel) => {
            const testResult = tests[channel.id];
            return (
              <li key={channel.id} className="bg-card px-4 py-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="font-medium">{channel.name}</h3>
                      <Badge variant={channel.enabled ? "live" : "outline"}>
                        {channelStatus(t, channel.state)}
                      </Badge>
                    </div>
                    {channel.description ? (
                      <p className="mt-1 text-sm text-muted-foreground">
                        {channel.description}
                      </p>
                    ) : null}
                    {channel.error ? (
                      <p className="mt-1 text-sm text-destructive">
                        {localizeError(locale, channel.error)}
                      </p>
                    ) : null}
                    {testResult ? (
                      <p
                        role="status"
                        className={
                          testResult.ok
                            ? "mt-2 text-sm text-live"
                            : "mt-2 text-sm text-destructive"
                        }
                      >
                        {testResult.message}
                      </p>
                    ) : null}
                  </div>
                  {writable ? (
                    <div className="flex flex-wrap items-center justify-end gap-1">
                      <Switch
                        checked={channel.enabled}
                        disabled={busy !== null}
                        aria-label={t("connect.channelToggle", {
                          name: channel.name,
                        })}
                        onCheckedChange={(next) =>
                          void run(`toggle:${channel.id}`, {
                            action: "channel-update",
                            platformId: channel.id,
                            enabled: next,
                          }).then((result) => {
                            if (result.ok) setNotice(t("connect.channelSaved"));
                          })
                        }
                      />
                      <Button
                        size="sm"
                        variant="ghost"
                        className="min-h-11 md:min-h-8"
                        disabled={busy !== null}
                        onClick={() => setEditing(channel)}
                      >
                        {t("connect.channelConfigure")}
                      </Button>
                      <Button
                        size="sm"
                        variant="ghost"
                        className="min-h-11 md:min-h-8"
                        disabled={busy !== null || !channel.configured}
                        onClick={() => void test(channel)}
                      >
                        {busy === `test:${channel.id}`
                          ? t("connect.channelTesting")
                          : t("connect.channelTest")}
                      </Button>
                    </div>
                  ) : null}
                </div>
              </li>
            );
          })}
        </ul>
      )}

      <Dialog
        open={editing !== null}
        onOpenChange={(open) => !busy && !open && setEditing(null)}
      >
        <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-xl overflow-y-auto">
          {editing ? (
            <>
              <DialogHeader>
                <DialogTitle>
                  {t("connect.channelConfigureTitle", { name: editing.name })}
                </DialogTitle>
                <DialogDescription>
                  {t("connect.channelConfigureDescription")}
                </DialogDescription>
              </DialogHeader>
              <form
                className="space-y-4"
                onSubmit={(event) => {
                  event.preventDefault();
                  void save();
                }}
              >
                <label className="flex min-h-11 items-center justify-between gap-4 text-sm">
                  <span>{t("connect.channelEnabled")}</span>
                  <Switch checked={enabled} onCheckedChange={setEnabled} />
                </label>
                <ChannelFields
                  fields={editing.envVars.filter((field) => !field.advanced)}
                  values={values}
                  clear={clear}
                  onValue={setChannelValue}
                  onClear={toggleChannelClear}
                />
                {editing.envVars.some((field) => field.advanced) ? (
                  <details className="rounded-lg border border-border p-3">
                    <summary className="min-h-11 cursor-pointer py-3 text-sm font-medium">
                      {t("connect.channelAdvanced")}
                    </summary>
                    <div className="space-y-4 pt-2">
                      <ChannelFields
                        fields={editing.envVars.filter(
                          (field) => field.advanced,
                        )}
                        values={values}
                        clear={clear}
                        onValue={setChannelValue}
                        onClear={toggleChannelClear}
                      />
                    </div>
                  </details>
                ) : null}
                {editing.docsUrl ? (
                  <a
                    className="inline-flex min-h-11 items-center text-sm underline underline-offset-4"
                    href={editing.docsUrl}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {t("connect.channelDocs")}
                  </a>
                ) : null}
                {error ? (
                  <p role="alert" className="text-sm text-destructive">
                    {error}
                  </p>
                ) : null}
                <Button
                  className="w-full"
                  type="submit"
                  disabled={busy !== null}
                >
                  {busy === `save:${editing.id}`
                    ? t("common.saving")
                    : t("connect.saveSession")}
                </Button>
              </form>
            </>
          ) : null}
        </DialogContent>
      </Dialog>
    </section>
  );
}

function ChannelFields({
  fields,
  values,
  clear,
  onValue,
  onClear,
}: {
  fields: HermesChannelRow["envVars"];
  values: Record<string, string>;
  clear: string[];
  onValue: (key: string, value: string) => void;
  onClear: (key: string) => void;
}) {
  const t = useT();
  return fields.map((field) => (
    <div key={field.key} className="space-y-1.5">
      <label className="flex flex-col gap-1.5 text-sm">
        <span>
          {field.prompt || field.key}
          {field.required ? ` · ${t("connect.channelRequired")}` : ""}
        </span>
        <Input
          type={field.isPassword ? "password" : "text"}
          autoComplete="off"
          value={values[field.key] ?? ""}
          placeholder={
            field.isSet
              ? t("connect.channelSavedValue")
              : field.description || field.key
          }
          onChange={(event) => onValue(field.key, event.target.value)}
        />
      </label>
      <div className="flex min-h-6 items-center justify-between gap-3">
        <span className="text-xs text-muted-foreground">
          {field.description}
        </span>
        {field.isSet ? (
          <button
            type="button"
            className="min-h-10 shrink-0 text-xs underline underline-offset-4"
            aria-pressed={clear.includes(field.key)}
            onClick={() => onClear(field.key)}
          >
            {clear.includes(field.key)
              ? t("connect.channelKeepValue")
              : t("connect.channelClearValue")}
          </button>
        ) : null}
      </div>
    </div>
  ));
}

function channelStatus(t: ReturnType<typeof useT>, state: string) {
  const map: Record<string, MsgKey> = {
    connected: "channel.connected",
    disabled: "channel.disabled",
    not_configured: "channel.not_configured",
    pending_restart: "channel.pending_restart",
    gateway_stopped: "channel.gateway_stopped",
    startup_failed: "channel.startup_failed",
    disconnected: "channel.disconnected",
    fatal: "channel.fatal",
    "en config": "channel.config",
    "en tareas": "channel.jobs",
    activo: "channel.on",
    apagado: "channel.off",
  };
  const key = map[state];
  return key ? t(key) : state;
}
