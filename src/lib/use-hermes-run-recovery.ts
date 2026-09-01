import { useEffect, type RefObject } from "react";
import { abortableDelay } from "./abortable-delay";
import { getHermesRun } from "./hermes-client";
import { t as tr } from "./i18n";
import { useHermes } from "./store";

export type ActiveHermesRun = {
  conversationId: string;
  assistantId: string;
  runId: string;
};

export function useHermesRunRecovery(opts: {
  activeId: string;
  enabled: boolean;
  sending: boolean;
  activeRunRef: RefObject<ActiveHermesRun | null>;
}) {
  const patchMessage = useHermes((state) => state.patchMessage);

  useEffect(() => {
    if (!opts.enabled || opts.sending) return;
    const conversation = useHermes
      .getState()
      .conversations.find((item) => item.id === opts.activeId);
    if (!conversation) return;
    const message = [...conversation.messages]
      .reverse()
      .find(
        (item) =>
          item.role === "assistant" &&
          item.runId &&
          item.runStatus !== "completed" &&
          item.runStatus !== "failed" &&
          item.runStatus !== "cancelled",
      );
    if (!message?.runId) return;

    const ctrl = new AbortController();
    opts.activeRunRef.current = {
      conversationId: conversation.id,
      assistantId: message.id,
      runId: message.runId,
    };
    void (async () => {
      let misses = 0;
      while (!ctrl.signal.aborted) {
        const run = await getHermesRun({
          runId: message.runId!,
          conversationId: conversation.id,
          signal: ctrl.signal,
        });
        if (ctrl.signal.aborted) return;
        if (!run) {
          misses += 1;
          if (misses < 5) {
            await abortableDelay(1_000, ctrl.signal).catch(() => undefined);
            continue;
          }
          patchMessage(conversation.id, message.id, {
            pending: false,
            incomplete: true,
            error: tr("en", "error.recoverRun"),
          });
          opts.activeRunRef.current = null;
          return;
        }
        misses = 0;
        const terminal =
          run.status === "completed" ||
          run.status === "failed" ||
          run.status === "cancelled";
        patchMessage(conversation.id, message.id, {
          runStatus: run.status,
          ...(run.output !== undefined ? { content: run.output } : {}),
          pending: !terminal,
          ...(run.status === "failed"
            ? { error: run.error || tr("en", "error.noReply") }
            : {}),
          ...(run.status === "cancelled" ? { incomplete: true } : {}),
          ...(run.status === "waiting_for_approval" && !message.approval
            ? {
                approval: {
                  title: tr("en", "chat.approvalTitle"),
                  choices: ["once", "deny"],
                },
              }
            : {}),
          ...(run.status === "running" || terminal
            ? { approval: undefined }
            : {}),
        });
        if (terminal) {
          opts.activeRunRef.current = null;
          return;
        }
        await abortableDelay(1_000, ctrl.signal).catch(() => undefined);
      }
    })();
    return () => ctrl.abort();
  }, [
    opts.activeId,
    opts.activeRunRef,
    opts.enabled,
    opts.sending,
    patchMessage,
  ]);
}
