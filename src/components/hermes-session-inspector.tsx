import { useEffect, useId, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  readHermesSessionMessages,
  type HermesSessionMessage,
} from "@/lib/hermes-live";
import { dateLocale, localizeError, type MsgKey } from "@/lib/i18n";
import { useLocale, useT } from "@/lib/use-i18n";

export function HermesSessionInspector({ sessionId }: { sessionId: string }) {
  const t = useT();
  const locale = useLocale();
  const panelId = useId();
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<HermesSessionMessage[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open || messages) return;
    const controller = new AbortController();
    setError(null);
    void readHermesSessionMessages({
      sessionId,
      signal: controller.signal,
    }).then((result) => {
      if (controller.signal.aborted) return;
      if (result.ok) setMessages(result.messages);
      else setError(localizeError(locale, result.error));
    });
    return () => controller.abort();
  }, [locale, messages, open, sessionId]);

  return (
    <div className="w-full">
      <Button
        variant="outline"
        size="sm"
        className="min-h-11 md:min-h-8"
        aria-expanded={open}
        aria-controls={panelId}
        onClick={() => setOpen((current) => !current)}
      >
        {open ? t("connect.hideSession") : t("connect.inspectSession")}
      </Button>
      {open ? (
        <div
          id={panelId}
          className="mt-3 border-t border-border pt-3"
          aria-live="polite"
        >
          {error ? (
            <p className="text-sm text-destructive" role="alert">
              {error || t("connect.sessionReadError")}
            </p>
          ) : messages === null ? (
            <p className="text-sm text-muted-foreground">
              {t("connect.loadingSession")}
            </p>
          ) : messages.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t("connect.emptySession")}
            </p>
          ) : (
            <ol className="max-h-96 divide-y divide-border overflow-y-auto border-y border-border">
              {messages.map((message) => (
                <li key={message.id} className="py-3 first:pt-0 last:pb-0">
                  <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                    <span className="text-2xs font-medium uppercase tracking-[0.12em] text-muted-foreground">
                      {t(roleKey(message.role))}
                    </span>
                    {message.toolName ? (
                      <span className="font-mono text-2xs text-muted-foreground">
                        {message.toolName}
                      </span>
                    ) : null}
                    {message.timestamp ? (
                      <time
                        className="ml-auto text-2xs text-muted-foreground"
                        dateTime={message.timestamp}
                      >
                        {formatTimestamp(locale, message.timestamp)}
                      </time>
                    ) : null}
                  </div>
                  <p className="mt-1 whitespace-pre-wrap break-words text-sm leading-6 text-foreground">
                    {message.content}
                  </p>
                </li>
              ))}
            </ol>
          )}
        </div>
      ) : null}
    </div>
  );
}

function roleKey(role: HermesSessionMessage["role"]): MsgKey {
  const keys: Record<HermesSessionMessage["role"], MsgKey> = {
    user: "connect.sessionRoleUser",
    assistant: "connect.sessionRoleAssistant",
    system: "connect.sessionRoleSystem",
    tool: "connect.sessionRoleTool",
    unknown: "connect.sessionRoleUnknown",
  };
  return keys[role];
}

function formatTimestamp(locale: "en" | "es", value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? value
    : date.toLocaleString(dateLocale(locale), {
        dateStyle: "medium",
        timeStyle: "short",
      });
}
