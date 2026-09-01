import { MessageSquare, Plus, RefreshCw, Send } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  createHermesRoom,
  readHermesProfiles,
  readHermesRoomLog,
  readHermesRooms,
  sendHermesRoomMessage,
  type HermesProfileRow,
  type HermesRoom,
  type HermesRoomEvent,
} from "@/lib/hermes-live";
import { localizeError } from "@/lib/i18n";
import { useHermes } from "@/lib/store";
import { useLocale, useT } from "@/lib/use-i18n";

export function HermesRoomsPanel() {
  const t = useT();
  const locale = useLocale();
  const connected = useHermes(
    (state) => state.gatewayOn && state.gatewayStatus === "live",
  );
  const [profiles, setProfiles] = useState<HermesProfileRow[]>([]);
  const [rooms, setRooms] = useState<HermesRoom[]>([]);
  const [supported, setSupported] = useState<boolean | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [events, setEvents] = useState<HermesRoomEvent[]>([]);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [members, setMembers] = useState<string[]>([]);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(
    async (signal?: AbortSignal) => {
      if (!connected) {
        setSupported(false);
        setRooms([]);
        setProfiles([]);
        return;
      }
      const [roomResult, profileResult] = await Promise.all([
        readHermesRooms({ signal }),
        readHermesProfiles({ signal }),
      ]);
      if (signal?.aborted) return;
      if (profileResult.ok) {
        setProfiles(profileResult.state.profiles);
        setMembers((current) =>
          current.length
            ? current
            : profileResult.state.profiles.slice(0, 2).map((row) => row.name),
        );
      }
      if (!roomResult.ok) {
        setError(localizeError(locale, roomResult.error));
        return;
      }
      setSupported(roomResult.supported);
      setRooms(roomResult.rooms);
      setSelected((current) =>
        current && roomResult.rooms.some((room) => room.id === current)
          ? current
          : (roomResult.rooms[0]?.id ?? null),
      );
    },
    [connected, locale],
  );

  useEffect(() => {
    const controller = new AbortController();
    void refresh(controller.signal);
    return () => controller.abort();
  }, [refresh]);

  useEffect(() => {
    if (!selected || supported !== true) {
      setEvents([]);
      return;
    }
    const controller = new AbortController();
    let timer: number | undefined;
    const poll = async () => {
      const result = await readHermesRoomLog({
        roomId: selected,
        signal: controller.signal,
      });
      if (controller.signal.aborted) return;
      if (result.ok) {
        setEvents(result.events);
        setError(null);
      } else setError(localizeError(locale, result.error));
      timer = window.setTimeout(poll, 2_500);
    };
    void poll();
    return () => {
      controller.abort();
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [locale, selected, supported]);

  async function createRoom() {
    const nextName = name.trim();
    if (!nextName || members.length < 2 || busy) return;
    setBusy(true);
    setError(null);
    const result = await createHermesRoom({ name: nextName, members });
    setBusy(false);
    if (!result.ok) {
      setError(localizeError(locale, result.error));
      return;
    }
    setCreating(false);
    setName("");
    await refresh();
    if (result.room) setSelected(result.room.id);
  }

  async function sendMessage() {
    const text = message.trim();
    if (!selected || !text || busy) return;
    setBusy(true);
    setError(null);
    const result = await sendHermesRoomMessage({
      roomId: selected,
      message: text,
    });
    setBusy(false);
    if (!result.ok) {
      setError(localizeError(locale, result.error));
      return;
    }
    setMessage("");
    const log = await readHermesRoomLog({ roomId: selected });
    if (log.ok) setEvents(log.events);
  }

  return (
    <section className="space-y-4 border-t border-border pt-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-sm font-medium">{t("agents.roomsTitle")}</h2>
          <p className="mt-1 max-w-xl text-sm leading-6 text-muted-foreground">
            {t("agents.roomsDescription")}
          </p>
        </div>
        <div className="flex shrink-0 gap-1">
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={t("common.done")}
            onClick={() => void refresh()}
          >
            <RefreshCw />
          </Button>
          {supported ? (
            <Button
              variant="outline"
              size="sm"
              onClick={() => setCreating(true)}
            >
              <Plus />
              {t("agents.roomCreate")}
            </Button>
          ) : null}
        </div>
      </div>

      {supported === false ? (
        <p className="rounded-xl border border-border bg-card px-4 py-6 text-sm text-muted-foreground">
          {t("agents.roomsUnavailable")}
        </p>
      ) : creating ? (
        <form
          className="space-y-4 rounded-xl border border-border bg-card p-4"
          onSubmit={(event) => {
            event.preventDefault();
            void createRoom();
          }}
        >
          <label className="block space-y-1.5 text-sm">
            <span>{t("agents.roomName")}</span>
            <Input
              value={name}
              onChange={(event) => setName(event.target.value)}
              maxLength={128}
            />
          </label>
          <fieldset className="space-y-2">
            <legend className="text-sm">{t("agents.roomMembers")}</legend>
            <div className="grid gap-1 sm:grid-cols-2">
              {profiles.map((profile) => (
                <label
                  key={profile.name}
                  className="flex min-h-11 items-center gap-3 rounded-md px-2 hover:bg-accent"
                >
                  <input
                    type="checkbox"
                    className="size-5 accent-primary"
                    checked={members.includes(profile.name)}
                    disabled={
                      members.length >= 6 && !members.includes(profile.name)
                    }
                    onChange={(event) =>
                      setMembers((current) =>
                        event.target.checked
                          ? [...new Set([...current, profile.name])]
                          : current.filter((name) => name !== profile.name),
                      )
                    }
                  />
                  <span className="text-sm">{profile.displayName}</span>
                </label>
              ))}
            </div>
          </fieldset>
          <div className="flex gap-2">
            <Button
              type="submit"
              disabled={busy || !name.trim() || members.length < 2}
            >
              {busy ? t("agents.roomCreating") : t("agents.roomCreate")}
            </Button>
            <Button variant="ghost" onClick={() => setCreating(false)}>
              {t("shell.cancel")}
            </Button>
          </div>
        </form>
      ) : supported ? (
        <div className="grid min-h-72 overflow-hidden rounded-xl border border-border bg-card sm:grid-cols-[14rem_1fr]">
          <div className="border-b border-border sm:border-r sm:border-b-0">
            {rooms.length ? (
              rooms.map((room) => (
                <button
                  key={room.id}
                  type="button"
                  className="flex min-h-12 w-full items-center gap-2 border-b border-border px-3 text-left text-sm last:border-b-0 hover:bg-accent aria-pressed:bg-accent"
                  aria-pressed={selected === room.id}
                  onClick={() => setSelected(room.id)}
                >
                  <MessageSquare className="size-4 shrink-0" />
                  <span className="min-w-0 truncate">{room.name}</span>
                </button>
              ))
            ) : (
              <p className="px-3 py-8 text-center text-sm text-muted-foreground">
                {t("agents.roomEmpty")}
              </p>
            )}
          </div>
          <div className="flex min-h-72 min-w-0 flex-col">
            <div
              className="min-h-0 flex-1 space-y-3 overflow-y-auto p-4"
              aria-live="polite"
            >
              {events.length ? (
                events
                  .filter((event) => event.kind.startsWith("message."))
                  .map((event) => (
                    <div key={event.seq} className="space-y-1">
                      <p className="text-xs font-medium text-muted-foreground">
                        {event.actor}
                      </p>
                      <p className="whitespace-pre-wrap text-sm leading-6">
                        {event.text}
                      </p>
                    </div>
                  ))
              ) : selected ? (
                <p className="text-sm text-muted-foreground">
                  {t("agents.roomWaiting")}
                </p>
              ) : null}
            </div>
            <form
              className="flex gap-2 border-t border-border p-3"
              onSubmit={(event) => {
                event.preventDefault();
                void sendMessage();
              }}
            >
              <Input
                value={message}
                onChange={(event) => setMessage(event.target.value)}
                placeholder={t("agents.roomMessage")}
                disabled={!selected || busy}
              />
              <Button
                type="submit"
                size="icon"
                disabled={!selected || busy || !message.trim()}
                aria-label={t("agents.roomSend")}
              >
                <Send />
              </Button>
            </form>
          </div>
        </div>
      ) : null}

      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}
    </section>
  );
}
