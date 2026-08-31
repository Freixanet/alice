import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useNavigate } from "@tanstack/react-router";
import {
  Camera,
  Check,
  ChevronDown,
  Copy,
  Image as ImageIcon,
  Paperclip,
  Plus,
  RotateCw,
  Share2,
  X,
} from "lucide-react";
import { Mark } from "@/components/logo";
import { ChatRunApproval } from "@/components/chat-run-approval";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input, Textarea } from "@/components/ui/input";
import type { ChatEvent, HermesChatContent } from "@/lib/gateway";
import { groupHermesModels, prettyModelLabel } from "@/lib/gateway";
import { controlHermesRunClient, listHermesModels } from "@/lib/hermes-client";
import {
  getDeviceSessionKey,
  streamHermesDirect,
  streamHermesSessionDirect,
} from "@/lib/hermes-direct";
import { authHeaders } from "@/lib/auth/client";
import { matchSlash } from "@/lib/slash";
import { displayMessageContent, slashHint, t as tr } from "@/lib/i18n";
import { useLocale, useT } from "@/lib/use-i18n";
import { useHermes } from "@/lib/store";
import type { Attachment, Message } from "@/lib/types";
import type {
  HermesApprovalChoice,
  HermesModelOption,
} from "@/lib/gateway-contracts";
import { advertisesHermesCapability } from "@/lib/gateway-contracts";
import {
  reduceChatStreamEvent,
  type ChatStreamAccumulator,
} from "@/lib/chat-stream";
import {
  useHermesRunRecovery,
  type ActiveHermesRun,
} from "@/lib/use-hermes-run-recovery";
import { cn, uid } from "@/lib/utils";

export function ChatView() {
  const conversations = useHermes((s) => s.conversations);
  const activeId = useHermes((s) => s.activeId);
  const draft = useHermes((s) => s.composerDraft);
  const setDraft = useHermes((s) => s.setDraft);
  const appendMessage = useHermes((s) => s.appendMessage);
  const patchMessage = useHermes((s) => s.patchMessage);
  const truncateConversationAfter = useHermes(
    (s) => s.truncateConversationAfter,
  );
  const newChat = useHermes((s) => s.newChat);
  const model = useHermes((s) => s.model);
  const provider = useHermes((s) => s.modelProvider);
  const recentModelRefs = useHermes((s) => s.recentModels);
  const setModel = useHermes((s) => s.setModel);
  const gatewayOn = useHermes((s) => s.gatewayOn);
  const gatewayStatus = useHermes((s) => s.gatewayStatus);
  const gatewayMeta = useHermes((s) => s.gatewayMeta);
  const gatewayUrl = useHermes((s) => s.gatewayUrl);
  const gatewayPlace = useHermes((s) => s.gatewayPlace);
  const profile = useHermes((s) => s.profile);
  const setGatewayModels = useHermes((s) => s.setGatewayModels);
  const [sending, setSending] = useState(false);
  const [files, setFiles] = useState<Attachment[]>([]);
  const [modelsOpen, setModelsOpen] = useState(false);
  const [attachOpen, setAttachOpen] = useState(false);
  const [modelsLoading, setModelsLoading] = useState(false);
  const [modelQuery, setModelQuery] = useState("");
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [activeRunId, setActiveRunId] = useState<string | null>(null);
  const [steering, setSteering] = useState(false);
  const [steerError, setSteerError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const activeRunRef = useRef<ActiveHermesRun | null>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const cameraRef = useRef<HTMLInputElement>(null);
  const galleryRef = useRef<HTMLInputElement>(null);
  const filesRef = useRef<HTMLInputElement>(null);
  const navigate = useNavigate();
  const t = useT();
  const locale = useLocale();
  const conv = conversations.find((c) => c.id === activeId) ?? conversations[0];
  const slash = matchSlash(draft);
  const live = gatewayOn && gatewayStatus === "live";
  const sessionBound = Boolean(conv?.hermesSessionId);
  const supportsSessionChat = advertisesHermesCapability(
    gatewayMeta?.manifest,
    "session_chat_stream",
  );
  const chatProfile = advertisesHermesCapability(
    gatewayMeta?.manifest,
    "profiles",
  )
    ? profile
    : undefined;
  const supportsRuns =
    gatewayMeta?.manifest?.capabilities["chat.runs"] === true &&
    gatewayMeta.manifest.capabilities["chat.cancel"] === true &&
    gatewayMeta.manifest.capabilities["chat.approvals"] === true;
  const supportsSteer =
    supportsRuns && gatewayMeta?.manifest?.capabilities["chat.steer"] === true;
  const supportsRunIdempotency =
    supportsRuns &&
    gatewayMeta?.manifest?.capabilities["chat.run_idempotency"] === true;
  useHermesRunRecovery({
    activeId,
    enabled: live && supportsRuns,
    sending,
    activeRunRef,
  });
  const empty = !conv || conv.messages.length === 0;
  const firstIsUser = Boolean(
    conv?.messages[0] && conv.messages[0].role === "user",
  );
  const modelChoices = useMemo(
    () => (live ? (gatewayMeta?.models ?? []) : []),
    [gatewayMeta?.models, live],
  );
  const currentChoice =
    modelChoices.find(
      (m) => m.id === model && (!provider || m.provider === provider),
    ) ?? modelChoices.find((m) => m.id === model);
  const currentLabel = live
    ? (currentChoice?.label ?? prettyModelLabel(model) ?? "Hermes")
    : "Hermes";
  const modelGroups = groupHermesModels(modelChoices);
  const modelFilter = modelQuery.trim().toLowerCase();
  const visibleGroups = useMemo(() => {
    if (!modelFilter) return modelGroups;
    return modelGroups
      .map((group) => ({
        ...group,
        models: group.models.filter((m) =>
          [m.id, m.label, m.provider, m.providerName, group.name].some(
            (value) => (value || "").toLowerCase().includes(modelFilter),
          ),
        ),
      }))
      .filter((group) => group.models.length > 0);
  }, [modelGroups, modelFilter]);
  const recentModels = useMemo(() => {
    const refs =
      recentModelRefs.length > 0
        ? recentModelRefs
        : currentChoice
          ? [{ id: currentChoice.id, provider: currentChoice.provider }]
          : [];
    const seen = new Set<string>();
    return refs.flatMap((ref) => {
      const choice =
        modelChoices.find(
          (item) =>
            item.id === ref.id &&
            (!ref.provider || item.provider === ref.provider),
        ) ?? modelChoices.find((item) => item.id === ref.id);
      if (!choice) return [];
      const key = `${choice.provider}:${choice.id}`;
      if (seen.has(key)) return [];
      seen.add(key);
      if (
        modelFilter &&
        ![choice.id, choice.label, choice.provider, choice.providerName].some(
          (value) => (value || "").toLowerCase().includes(modelFilter),
        )
      ) {
        return [];
      }
      return [choice];
    });
  }, [currentChoice, modelChoices, modelFilter, recentModelRefs]);

  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const firstTurn = Boolean(
      conv?.messages[0]?.role === "user" && conv.messages.length <= 2,
    );
    if (firstTurn && el.scrollHeight <= el.clientHeight) return;
    el.scrollTo({ top: el.scrollHeight });
  }, [conv?.messages, sending]);

  useEffect(() => {
    if (!live) return;
    const ctrl = new AbortController();
    void listHermesModels({ refresh: true, signal: ctrl.signal }).then(
      (result) => {
        if (ctrl.signal.aborted || !result.ok) return;
        setGatewayModels(result.models, {
          model: result.currentModel,
          provider: result.currentProvider,
        });
      },
    );
    return () => ctrl.abort();
  }, [live, profile, setGatewayModels]);

  useEffect(() => {
    if (!modelsOpen || !live) return;
    const ctrl = new AbortController();
    setModelsLoading(true);
    void listHermesModels({ refresh: true, signal: ctrl.signal }).then(
      (result) => {
        if (ctrl.signal.aborted) return;
        if (result.ok) setGatewayModels(result.models);
        setModelsLoading(false);
      },
    );
    return () => {
      ctrl.abort();
      setModelsLoading(false);
    };
  }, [modelsOpen, live, setGatewayModels]);

  useEffect(() => {
    if (!modelsOpen) setModelQuery("");
  }, [modelsOpen]);

  async function send() {
    const text = draft.trim();
    if ((!text && files.length === 0) || sending || !conv) return;
    if (text === "/new" || text === "/reset" || text === "/clear") {
      setDraft("");
      newChat();
      return;
    }
    if (text === "/retry") {
      setDraft("");
      if (sessionBound) return;
      const last = [...conv.messages]
        .reverse()
        .find((m) => m.role === "assistant" && !m.pending);
      if (last && (last.error || last.incomplete)) void retry(last.id);
      return;
    }
    const user: Message = {
      id: uid(),
      role: "user",
      content: text,
      createdAt: Date.now(),
      attachments: files.length ? files : undefined,
    };
    const assistantId = uid();
    appendMessage(conv.id, user);
    appendMessage(conv.id, {
      id: assistantId,
      role: "assistant",
      content: "",
      createdAt: Date.now(),
      pending: true,
    });
    setDraft("");
    setFiles([]);
    await runStream(conv.id, assistantId, [...conv.messages, user]);
  }

  async function retry(assistantId: string) {
    if (sending || !conv || conv.hermesSessionId) return;
    const latest =
      useHermes.getState().conversations.find((c) => c.id === conv.id) ?? conv;
    const idx = latest.messages.findIndex((m) => m.id === assistantId);
    if (idx < 0) return;
    const history = latest.messages.slice(0, idx);
    if (!history.some((m) => m.role === "user")) return;
    truncateConversationAfter(conv.id, assistantId);
    patchMessage(conv.id, assistantId, {
      content: "",
      pending: true,
      error: undefined,
      incomplete: undefined,
      tools: undefined,
    });
    await runStream(conv.id, assistantId, history);
  }

  async function copyResponse(messageId: string, text: string) {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(messageId);
      window.setTimeout(
        () =>
          setCopiedId((current) => (current === messageId ? null : current)),
        1_600,
      );
    } catch {
      // Clipboard access can be unavailable in restricted browser contexts.
    }
  }

  async function shareResponse(messageId: string, text: string) {
    if (navigator.share) {
      try {
        await navigator.share({ title: "Alice", text });
        return;
      } catch (error) {
        if ((error as Error).name === "AbortError") return;
      }
    }
    await copyResponse(messageId, text);
  }

  async function runStream(
    conversationId: string,
    assistantId: string,
    history: Message[],
  ) {
    setSending(true);
    setAttachOpen(false);
    setModelsOpen(false);
    setActiveRunId(null);
    setSteerError(null);
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    let latestAttachmentMessage = -1;
    for (let index = history.length - 1; index >= 0; index -= 1) {
      if (history[index]?.attachments?.length) {
        latestAttachmentMessage = index;
        break;
      }
    }
    const payload = history
      .map((message, index) => ({
        role: message.role as "user" | "assistant",
        content: hermesContent(message, index === latestAttachmentMessage),
      }))
      .filter((message) =>
        typeof message.content === "string"
          ? Boolean(message.content.trim())
          : message.content.length > 0,
      );
    const hermesSessionId = useHermes
      .getState()
      .conversations.find(
        (conversation) => conversation.id === conversationId,
      )?.hermesSessionId;
    const fail = (message: string) => {
      patchMessage(conversationId, assistantId, {
        pending: false,
        error: message,
        incomplete: undefined,
        content: message,
      });
    };
    try {
      if (hermesSessionId && !supportsSessionChat) {
        fail(tr(locale, "chat.sessionUnavailable"));
        return;
      }
      const apply = (ev: ChatEvent, acc: ChatStreamAccumulator) => {
        const result = reduceChatStreamEvent(acc, ev);
        patchMessage(conversationId, assistantId, result.patch);
        if (result.activeRun) {
          activeRunRef.current = {
            conversationId,
            assistantId,
            runId: result.activeRun.runId,
          };
          setActiveRunId(
            result.activeRun.terminal ? null : result.activeRun.runId,
          );
          if (result.activeRun.terminal) activeRunRef.current = null;
        }
        return result.stop ? ("stop" as const) : ("continue" as const);
      };

      const acc: ChatStreamAccumulator = { content: "", tools: [] };
      const finish = () => {
        const cancelled = acc.runStatus === "cancelled";
        patchMessage(conversationId, assistantId, {
          content: acc.content || (cancelled ? "" : tr("en", "chat.noReply")),
          pending: false,
          incomplete: cancelled || !acc.content,
        });
      };

      if (gatewayPlace === "device") {
        const key = getDeviceSessionKey();
        if (!key || !gatewayUrl) {
          fail(tr("en", "error.connectDevice"));
          return;
        }
        const latestUser = [...payload]
          .reverse()
          .find((message) => message.role === "user");
        const stream = hermesSessionId
          ? latestUser
            ? streamHermesSessionDirect({
                url: gatewayUrl,
                key,
                sessionId: hermesSessionId,
                message: latestUser.content,
                conversationId,
                model,
                provider,
                signal: ctrl.signal,
                profile: chatProfile,
              })
            : null
          : streamHermesDirect({
              url: gatewayUrl,
              key,
              conversationId,
              model,
              provider,
              preferRuns: supportsRuns,
              runIdempotency: supportsRunIdempotency,
              messages: payload,
              signal: ctrl.signal,
              profile: chatProfile,
            });
        if (!stream) {
          fail(tr(locale, "error.noReply"));
          return;
        }
        for await (const ev of stream) {
          if (apply(ev, acc) === "stop") return;
        }
        finish();
      } else {
        const res = await fetch("/api/chat", {
          method: "POST",
          headers: authHeaders({ "Content-Type": "application/json" }),
          signal: ctrl.signal,
          body: JSON.stringify({
            conversationId,
            ...(hermesSessionId ? { hermesSessionId } : {}),
            model,
            provider,
            preferRuns: supportsRuns,
            runIdempotency: supportsRunIdempotency,
            profile: chatProfile,
            messages: payload,
          }),
        });
        const ct = res.headers.get("content-type") ?? "";
        if (!res.body) {
          fail(tr("en", "error.noReply"));
          return;
        }
        if (
          !res.ok &&
          ct.includes("application/json") &&
          !ct.includes("ndjson")
        ) {
          fail(tr("en", "error.noReply"));
          return;
        }
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buf = "";
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          const lines = buf.split("\n");
          buf = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.trim()) continue;
            try {
              const ev = JSON.parse(line) as ChatEvent;
              if (apply(ev, acc) === "stop") return;
            } catch {
              // skip malformed
            }
          }
        }
        finish();
      }
    } catch (e) {
      if ((e as Error).name === "AbortError") {
        patchMessage(conversationId, assistantId, {
          pending: false,
          incomplete: true,
        });
      } else {
        fail(tr("en", "error.connect"));
      }
    } finally {
      setSending(false);
      setActiveRunId(null);
      setSteering(false);
      abortRef.current = null;
    }
  }

  function stopRun() {
    setSteerError(null);
    const run = activeRunRef.current;
    if (run) {
      patchMessage(run.conversationId, run.assistantId, {
        runStatus: "stopping",
      });
      void controlHermesRunClient({ action: "stop", runId: run.runId });
    }
    abortRef.current?.abort();
  }

  async function steerRun() {
    const input = draft.trim();
    if (!supportsSteer || !activeRunId || !input || steering) return;
    setSteering(true);
    setSteerError(null);
    const ok = await controlHermesRunClient({
      action: "steer",
      runId: activeRunId,
      input,
    });
    if (ok) setDraft("");
    else setSteerError(t("error.steer"));
    setSteering(false);
  }

  async function resolveRunApproval(
    conversationId: string,
    message: Message,
    choice: HermesApprovalChoice,
  ) {
    if (!message.runId || !message.approval?.choices.includes(choice)) return;
    patchMessage(conversationId, message.id, {
      approval: { ...message.approval, resolving: true, error: undefined },
    });
    const ok = await controlHermesRunClient({
      action: "approval",
      runId: message.runId,
      choice,
    });
    patchMessage(conversationId, message.id, {
      runStatus: ok ? "running" : "waiting_for_approval",
      approval: ok
        ? undefined
        : {
            ...message.approval,
            resolving: false,
            error: tr("en", "error.approval"),
          },
    });
  }

  function pickModel(id: string, nextProvider?: string) {
    setModel(id, nextProvider);
    setModelsOpen(false);
  }

  function pickFromQuery() {
    const q = modelQuery.trim();
    if (!q) return;
    const lower = q.toLowerCase();
    const listed = visibleGroups.flatMap((group) => group.models);
    const exact =
      listed.find((m) => m.id.toLowerCase() === lower) ??
      listed.find((m) => m.label.toLowerCase() === lower);
    const chosen = exact ?? listed[0];
    if (chosen) pickModel(chosen.id, chosen.provider);
    else pickModel(q);
  }

  function renderModelOption(option: HermesModelOption) {
    const on =
      option.id === model && (!provider || option.provider === provider);
    return (
      <DropdownMenuItem
        key={`${option.provider}:${option.id}`}
        onSelect={() => pickModel(option.id, option.provider)}
        className={cn("min-w-0 max-w-full overflow-hidden", on && "bg-accent")}
      >
        <span className="min-w-0 truncate">{option.label}</span>
      </DropdownMenuItem>
    );
  }

  async function onFiles(list: FileList | null) {
    if (!list) return;
    const next: Attachment[] = [];
    for (const file of Array.from(list)) {
      const kind = file.type.startsWith("image/") ? "image" : "file";
      const dataUrl = await readFile(file);
      next.push({
        id: uid(),
        name: file.name,
        mime: file.type || "application/octet-stream",
        kind,
        dataUrl,
      });
    }
    setFiles((prev) => [...prev, ...next]);
  }

  return (
    <div
      className={cn(
        "relative flex min-h-0 flex-1 flex-col",
        empty &&
          "items-center justify-center overflow-hidden overscroll-none pb-[10vh]",
      )}
    >
      {empty ? (
        <div className="alice-empty-state flex flex-col items-center px-6 text-center">
          <Mark className="size-10 text-foreground" />
          <h1 className="mt-5 font-serif text-3xl tracking-tight sm:text-4xl">
            {t("chat.emptyTitle")}
          </h1>
          <p className="mt-2 text-sm text-muted-foreground">
            {t("chat.emptyHint")}
          </p>
        </div>
      ) : (
        <div
          ref={scroller}
          className="alice-chat-scroller min-h-0 flex-1 overflow-y-auto"
        >
          <div
            role="log"
            aria-label={t("chat.conversation")}
            aria-live="polite"
            aria-relevant="additions text"
            className={cn(
              "alice-message-list mx-auto flex w-full max-w-[45rem] flex-col gap-6 px-4 pb-28 sm:px-6",
              firstIsUser ? "pt-[10vh]" : "pt-8",
            )}
          >
            {conv.messages.map((m, i) => {
              const text =
                m.role === "assistant"
                  ? displayMessageContent(locale, m.content.replace(/^\s+/, ""))
                  : m.content;
              const canTryAgain =
                m.role === "assistant" &&
                !m.pending &&
                !conv.hermesSessionId &&
                conv.messages.slice(0, i).some((msg) => msg.role === "user");
              return (
                <article
                  key={m.id}
                  className={cn(
                    "flex flex-col gap-2",
                    m.role === "user" && "items-end",
                  )}
                >
                  {m.role === "user" ? null : (
                    <p className="text-2xs font-medium tracking-[0.12em] text-muted-foreground uppercase">
                      Alice
                    </p>
                  )}
                  {text || m.pending ? (
                    <div
                      className={cn(
                        "alice-message max-w-[42rem] whitespace-pre-wrap text-base leading-relaxed",
                        m.role === "user"
                          ? "alice-user-message rounded-xl bg-card px-4 py-3"
                          : "text-foreground",
                        m.error && "text-destructive",
                      )}
                    >
                      {m.role === "assistant" ? (
                        <AssistantContent text={text} />
                      ) : (
                        text
                      )}
                      {m.pending && !text && !m.approval ? (
                        <ReplyPending />
                      ) : null}
                    </div>
                  ) : null}
                  {m.attachments?.length ? (
                    <MessageAttachments attachments={m.attachments} />
                  ) : null}
                  {m.tools?.length ? <ToolActivity tools={m.tools} /> : null}
                  {m.role === "assistant" && m.approval ? (
                    <ChatRunApproval
                      approval={m.approval}
                      onChoose={(choice) =>
                        void resolveRunApproval(conv.id, m, choice)
                      }
                    />
                  ) : null}
                  {m.role === "assistant" && !m.pending && text ? (
                    <div
                      className="-ml-1 flex items-center"
                      role="group"
                      aria-label={t("chat.responseActions")}
                    >
                      <button
                        type="button"
                        onClick={() => void copyResponse(m.id, text)}
                        aria-label={t(
                          copiedId === m.id ? "chat.copied" : "chat.copy",
                        )}
                        title={t(
                          copiedId === m.id ? "chat.copied" : "chat.copy",
                        )}
                        className="grid h-10 w-8 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground md:size-7"
                      >
                        {copiedId === m.id ? (
                          <Check className="size-3.5" />
                        ) : (
                          <Copy className="size-3.5" />
                        )}
                      </button>
                      <button
                        type="button"
                        onClick={() => void shareResponse(m.id, text)}
                        aria-label={t("chat.share")}
                        title={t("chat.share")}
                        className="grid h-10 w-8 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground md:size-7"
                      >
                        <Share2 className="size-3.5" />
                      </button>
                      <button
                        type="button"
                        disabled={!canTryAgain || sending}
                        onClick={() => void retry(m.id)}
                        aria-label={t("chat.tryAgain")}
                        title={t("chat.tryAgain")}
                        className="grid h-10 w-8 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-35 md:size-7"
                      >
                        <RotateCw className="size-3.5" />
                      </button>
                    </div>
                  ) : null}
                </article>
              );
            })}
          </div>
        </div>
      )}

      <div
        className={cn(
          "px-4 sm:px-6",
          empty ? "mt-8 w-full max-w-2xl" : "w-full pb-5",
        )}
      >
        <div className="mx-auto w-full max-w-2xl">
          {slash.length > 0 ? (
            <ul className="mb-2 overflow-hidden rounded-2xl bg-card py-1 border border-border">
              {slash.map((item) => (
                <li key={item.cmd}>
                  <button
                    type="button"
                    className="flex w-full items-baseline gap-3 px-3 py-2 text-left text-sm hover:bg-accent"
                    onClick={() => setDraft(item.cmd + " ")}
                  >
                    <span className="font-mono text-xs">{item.cmd}</span>
                    <span className="text-muted-foreground">
                      {slashHint(locale, item.cmd)}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          ) : null}
          {files.length > 0 ? (
            <ul className="mb-2 flex flex-wrap gap-1.5">
              {files.map((f) => (
                <li
                  key={f.id}
                  className="flex min-w-0 items-center gap-1 rounded-md bg-card py-1 pl-3 pr-1 text-2xs text-muted-foreground border border-border"
                >
                  <span className="max-w-48 truncate">{f.name}</span>
                  <button
                    type="button"
                    aria-label={t("chat.removeAttachment", { name: f.name })}
                    title={t("chat.removeAttachment", { name: f.name })}
                    onClick={() =>
                      setFiles((current) =>
                        current.filter((file) => file.id !== f.id),
                      )
                    }
                    className="grid size-8 shrink-0 place-items-center rounded-md hover:bg-accent hover:text-foreground"
                  >
                    <X className="size-3.5" />
                  </button>
                </li>
              ))}
            </ul>
          ) : null}
          <div className="alice-composer rounded-2xl bg-card px-4 pb-3 pt-3 border border-border">
            <Textarea
              aria-label={t("chat.placeholder")}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  if (sending) {
                    if (supportsSteer) void steerRun();
                  } else {
                    void send();
                  }
                }
              }}
              placeholder={t("chat.placeholder")}
              rows={2}
              className="min-h-[2.5rem] w-full bg-transparent py-1 pl-2 pr-0 text-base placeholder:text-muted-foreground/70 md:text-base"
            />
            {steerError ? (
              <p className="px-2 pb-1 text-sm text-destructive" role="alert">
                {steerError}
              </p>
            ) : null}
            <div className="mt-1 flex items-center gap-1.5">
              <input
                ref={cameraRef}
                type="file"
                accept="image/*"
                capture="environment"
                className="hidden"
                onChange={(e) => {
                  void onFiles(e.target.files);
                  e.target.value = "";
                }}
              />
              <input
                ref={galleryRef}
                type="file"
                accept="image/*"
                multiple
                className="hidden"
                onChange={(e) => {
                  void onFiles(e.target.files);
                  e.target.value = "";
                }}
              />
              <input
                ref={filesRef}
                type="file"
                accept="image/*,text/*,.md,.markdown,.json,.csv,.ts,.tsx,.js,.jsx,.py,.html,.css,.xml,.yaml,.yml"
                multiple
                className="hidden"
                onChange={(e) => {
                  void onFiles(e.target.files);
                  e.target.value = "";
                }}
              />
              <DropdownMenu
                open={attachOpen}
                onOpenChange={(open) => {
                  if (sending) return;
                  setAttachOpen(open);
                  if (open) setModelsOpen(false);
                }}
              >
                <DropdownMenuTrigger asChild>
                  <button
                    type="button"
                    aria-label={t("chat.add")}
                    disabled={sending}
                    className="grid size-8 place-items-center rounded-full text-muted-foreground hover:bg-accent hover:text-foreground disabled:opacity-40"
                  >
                    <Plus className="size-4" />
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start" className="min-w-44">
                  <DropdownMenuItem
                    onSelect={() => {
                      window.setTimeout(() => cameraRef.current?.click(), 0);
                    }}
                  >
                    <Camera className="size-4" />
                    {t("chat.camera")}
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    onSelect={() => {
                      window.setTimeout(() => galleryRef.current?.click(), 0);
                    }}
                  >
                    <ImageIcon className="size-4" />
                    {t("chat.gallery")}
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    onSelect={() => {
                      window.setTimeout(() => filesRef.current?.click(), 0);
                    }}
                  >
                    <Paperclip className="size-4" />
                    {t("chat.files")}
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
              <DropdownMenu
                open={modelsOpen}
                onOpenChange={(open) => {
                  if (sending) return;
                  setModelsOpen(open);
                  if (open) {
                    setAttachOpen(false);
                  }
                }}
              >
                <DropdownMenuTrigger asChild>
                  <button
                    type="button"
                    disabled={sending}
                    aria-label={t("chat.model", { model: currentLabel })}
                    className="flex h-8 min-w-0 max-w-48 items-center gap-1 rounded-md px-2 text-sm text-foreground hover:bg-accent disabled:opacity-40"
                  >
                    <span className="min-w-0 truncate">{currentLabel}</span>
                    <ChevronDown className="size-3.5 shrink-0 text-muted-foreground" />
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent
                  align="start"
                  className="flex max-h-80 w-[min(18rem,calc(100vw-2rem))] min-w-0 max-w-[calc(100vw-2rem)] flex-col overflow-hidden p-1"
                >
                  {!live ? (
                    <DropdownMenuItem
                      onSelect={() => void navigate({ to: "/connect" })}
                    >
                      {t("chat.connectHermes")}
                    </DropdownMenuItem>
                  ) : (
                    <>
                      <div className="min-w-0 px-1 pb-1 pt-2">
                        <Input
                          value={modelQuery}
                          onChange={(e) => setModelQuery(e.target.value)}
                          onKeyDown={(e) => {
                            e.stopPropagation();
                            if (e.key === "Enter") {
                              e.preventDefault();
                              pickFromQuery();
                            }
                          }}
                          onPointerDown={(e) => e.stopPropagation()}
                          placeholder={t("chat.modelPlaceholder")}
                          className="h-8 px-2"
                          autoComplete="off"
                        />
                      </div>
                      <div className="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden">
                        {modelsLoading && modelChoices.length === 0 ? (
                          <DropdownMenuItem disabled>
                            {t("chat.loadingModels")}
                          </DropdownMenuItem>
                        ) : visibleGroups.length === 0 &&
                          recentModels.length === 0 ? (
                          <DropdownMenuItem
                            onSelect={() => {
                              if (modelQuery.trim())
                                pickModel(modelQuery.trim());
                            }}
                          >
                            {modelQuery.trim()
                              ? t("chat.useModel", { model: modelQuery.trim() })
                              : t("chat.noModels")}
                          </DropdownMenuItem>
                        ) : (
                          <>
                            {recentModels.length > 0 ? (
                              <div className="min-w-0">
                                <DropdownMenuLabel>
                                  {t("chat.recentModels")}
                                </DropdownMenuLabel>
                                {recentModels.map(renderModelOption)}
                              </div>
                            ) : null}
                            {visibleGroups.map((group, i) => (
                              <div key={group.slug} className="min-w-0">
                                {i > 0 || recentModels.length > 0 ? (
                                  <DropdownMenuSeparator />
                                ) : null}
                                <DropdownMenuLabel>
                                  {group.name}
                                </DropdownMenuLabel>
                                {group.models.map(renderModelOption)}
                              </div>
                            ))}
                          </>
                        )}
                      </div>
                    </>
                  )}
                </DropdownMenuContent>
              </DropdownMenu>
              {sending ? (
                <button
                  type="button"
                  aria-label={t("chat.stop")}
                  onClick={stopRun}
                  className="ml-auto grid size-11 place-items-center rounded-full bg-muted text-foreground md:size-9"
                >
                  <span
                    className="size-2.5 rounded-[2px] bg-current"
                    aria-hidden
                  />
                </button>
              ) : null}
              {!sending || supportsSteer ? (
                <button
                  type="button"
                  aria-label={sending ? t("chat.steer") : t("chat.send")}
                  disabled={
                    sending
                      ? !activeRunId || !draft.trim() || steering
                      : !draft.trim() && files.length === 0
                  }
                  onClick={() => (sending ? void steerRun() : void send())}
                  className={cn(
                    "grid size-11 place-items-center rounded-full bg-muted text-foreground disabled:opacity-40 md:size-9",
                    !sending && "ml-auto",
                  )}
                >
                  <svg
                    viewBox="0 0 16 16"
                    className="size-3.5"
                    fill="none"
                    aria-hidden
                  >
                    <path
                      d="M8 12.5V3.5M8 3.5 3.5 8M8 3.5 12.5 8"
                      stroke="currentColor"
                      strokeWidth="1.6"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </button>
              ) : null}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function ReplyPending() {
  const t = useT();
  return (
    <span className="alice-typing" role="status" aria-label={t("chat.pending")}>
      <span aria-hidden />
      <span aria-hidden />
      <span aria-hidden />
    </span>
  );
}

function AssistantContent({ text }: { text: string }) {
  const imagePattern =
    /!\[([^\]]*)\]\(((?:data:image\/(?:png|jpe?g|gif|webp|bmp);base64,[A-Za-z0-9+/=]+)|(?:https?:\/\/[^)\s]+))\)/gi;
  const parts: ReactNode[] = [];
  let start = 0;
  let match: RegExpExecArray | null;
  while ((match = imagePattern.exec(text))) {
    const imageUrl = match[2];
    if (!imageUrl) continue;
    if (match.index > start) parts.push(text.slice(start, match.index));
    parts.push(
      <img
        key={`${match.index}-${imageUrl.slice(0, 32)}`}
        src={imageUrl}
        alt={match[1] || "Image from Hermes"}
        className="my-3 max-h-[32rem] w-auto max-w-full rounded-md object-contain"
      />,
    );
    start = imagePattern.lastIndex;
  }
  if (start < text.length) parts.push(text.slice(start));
  return <>{parts}</>;
}

function MessageAttachments({ attachments }: { attachments: Attachment[] }) {
  return (
    <div className="flex max-w-[42rem] flex-wrap justify-end gap-2">
      {attachments.map((attachment) =>
        attachment.kind === "image" && attachment.dataUrl ? (
          <img
            key={attachment.id}
            src={attachment.dataUrl}
            alt={attachment.name}
            className="max-h-64 max-w-64 rounded-md object-cover"
          />
        ) : (
          <span
            key={attachment.id}
            className="max-w-64 truncate rounded-md bg-card px-3 py-2 text-sm text-muted-foreground"
          >
            {attachment.name}
          </span>
        ),
      )}
    </div>
  );
}

function ToolActivity({ tools }: { tools: NonNullable<Message["tools"]> }) {
  return (
    <ul className="flex flex-col gap-1 text-2xs text-muted-foreground">
      {tools.map((tool) => (
        <li key={tool.id} className="flex min-w-0 items-center gap-2">
          <span
            className={cn(
              "size-1.5 shrink-0 rounded-full",
              tool.status === "done"
                ? "bg-live"
                : "animate-pulse bg-muted-foreground",
            )}
            aria-hidden
          />
          <span className="font-mono">{tool.name}</span>
          {tool.detail && tool.detail !== tool.name ? (
            <span className="truncate">{tool.detail}</span>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

function readFile(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result ?? ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

function hermesContent(
  message: Message,
  includeAttachments: boolean,
): HermesChatContent {
  if (!includeAttachments || !message.attachments?.length)
    return message.content;
  const text = [message.content];
  const images: Exclude<HermesChatContent, string> = [];
  for (const attachment of message.attachments) {
    if (
      attachment.kind === "image" &&
      attachment.dataUrl?.startsWith("data:image/")
    ) {
      images.push({
        type: "image_url",
        image_url: { url: attachment.dataUrl, detail: "auto" },
      });
      continue;
    }
    const contents = textAttachment(attachment);
    if (contents) text.push(`Attached file — ${attachment.name}:\n${contents}`);
  }
  const combined = text.filter(Boolean).join("\n\n").slice(0, 60_000);
  if (images.length === 0) return combined;
  return [
    ...(combined ? [{ type: "text" as const, text: combined }] : []),
    ...images,
  ];
}

function textAttachment(attachment: Attachment): string {
  if (!attachment.dataUrl) return "";
  const textual =
    attachment.mime.startsWith("text/") ||
    /(?:json|javascript|typescript|xml|yaml|csv)/i.test(attachment.mime) ||
    /\.(?:md|markdown|json|csv|ts|tsx|js|jsx|py|html|css|xml|ya?ml)$/i.test(
      attachment.name,
    );
  if (!textual) return "";
  const comma = attachment.dataUrl.indexOf(",");
  if (comma < 0) return "";
  try {
    const metadata = attachment.dataUrl.slice(0, comma);
    const payload = attachment.dataUrl.slice(comma + 1);
    if (!metadata.includes(";base64"))
      return decodeURIComponent(payload).slice(0, 50_000);
    const binary = atob(payload);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    return new TextDecoder().decode(bytes).slice(0, 50_000);
  } catch {
    return "";
  }
}
