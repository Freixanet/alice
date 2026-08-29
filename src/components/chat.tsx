import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { Camera, ChevronDown, Image as ImageIcon, Paperclip, Plus, RotateCw } from "lucide-react";
import { Mark } from "@/components/logo";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input, Textarea } from "@/components/ui/input";
import type { ChatEvent } from "@/lib/gateway";
import {
  getMacSessionKey,
  groupHermesModels,
  listHermesModels,
  prettyModelLabel,
  setHermesModel,
} from "@/lib/gateway";
import { getDeviceSessionKey, streamHermesDirect } from "@/lib/hermes-direct";
import { authHeaders } from "@/lib/auth/client";
import { matchSlash } from "@/lib/slash";
import { displayMessageContent, slashHint, t as tr } from "@/lib/i18n";
import { useLocale, useT } from "@/lib/use-i18n";
import { useHermes } from "@/lib/store";
import type { Attachment, Message } from "@/lib/types";
import { cn, uid } from "@/lib/utils";

export function ChatView() {
  const conversations = useHermes((s) => s.conversations);
  const activeId = useHermes((s) => s.activeId);
  const draft = useHermes((s) => s.composerDraft);
  const setDraft = useHermes((s) => s.setDraft);
  const appendMessage = useHermes((s) => s.appendMessage);
  const patchMessage = useHermes((s) => s.patchMessage);
  const newChat = useHermes((s) => s.newChat);
  const model = useHermes((s) => s.model);
  const provider = useHermes((s) => s.modelProvider);
  const setModel = useHermes((s) => s.setModel);
  const gatewayOn = useHermes((s) => s.gatewayOn);
  const gatewayStatus = useHermes((s) => s.gatewayStatus);
  const gatewayMeta = useHermes((s) => s.gatewayMeta);
  const gatewayUrl = useHermes((s) => s.gatewayUrl);
  const gatewayPlace = useHermes((s) => s.gatewayPlace);
  const setGatewayModels = useHermes((s) => s.setGatewayModels);
  const [sending, setSending] = useState(false);
  const [files, setFiles] = useState<Attachment[]>([]);
  const [modelsOpen, setModelsOpen] = useState(false);
  const [attachOpen, setAttachOpen] = useState(false);
  const [modelsLoading, setModelsLoading] = useState(false);
  const [modelQuery, setModelQuery] = useState("");
  const abortRef = useRef<AbortController | null>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const cameraRef = useRef<HTMLInputElement>(null);
  const galleryRef = useRef<HTMLInputElement>(null);
  const filesRef = useRef<HTMLInputElement>(null);
  const modelSearchRef = useRef<HTMLInputElement>(null);
  const navigate = useNavigate();
  const t = useT();
  const locale = useLocale();
  const conv = conversations.find((c) => c.id === activeId) ?? conversations[0];
  const slash = matchSlash(draft);
  const live = gatewayOn && gatewayStatus === "live";
  const empty = !conv || conv.messages.length === 0;
  const firstIsUser = Boolean(conv?.messages[0] && conv.messages[0].role === "user");
  const lastAssistantId = conv
    ? [...conv.messages].reverse().find((msg) => msg.role === "assistant")?.id
    : undefined;
  const modelChoices = live ? (gatewayMeta?.models ?? []) : [];
  const currentChoice =
    modelChoices.find((m) => m.id === model && (!provider || m.provider === provider)) ??
    modelChoices.find((m) => m.id === model);
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
          [m.id, m.label, m.provider, m.providerName, group.name].some((value) =>
            (value || "").toLowerCase().includes(modelFilter),
          ),
        ),
      }))
      .filter((group) => group.models.length > 0);
  }, [modelGroups, modelFilter]);

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
    void listHermesModels({ refresh: true, signal: ctrl.signal }).then((result) => {
      if (ctrl.signal.aborted || !result.ok) return;
      setGatewayModels(result.models);
    });
    return () => ctrl.abort();
  }, [live, setGatewayModels]);

  useEffect(() => {
    if (!modelsOpen || !live) return;
    const ctrl = new AbortController();
    setModelsLoading(true);
    void listHermesModels({ refresh: true, signal: ctrl.signal }).then((result) => {
      if (ctrl.signal.aborted) return;
      if (result.ok) setGatewayModels(result.models);
      setModelsLoading(false);
    });
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
      const last = [...conv.messages].reverse().find((m) => m.role === "assistant" && !m.pending);
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
    if (sending || !conv) return;
    const latest =
      useHermes.getState().conversations.find((c) => c.id === conv.id) ?? conv;
    const idx = latest.messages.findIndex((m) => m.id === assistantId);
    if (idx < 0) return;
    const history = latest.messages.slice(0, idx);
    if (!history.some((m) => m.role === "user")) return;
    patchMessage(conv.id, assistantId, {
      content: "",
      pending: true,
      error: undefined,
      incomplete: undefined,
      tools: undefined,
    });
    await runStream(conv.id, assistantId, history);
  }

  async function runStream(
    conversationId: string,
    assistantId: string,
    history: Message[],
  ) {
    setSending(true);
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    const payload = history
      .filter((m) => m.content.trim())
      .map((m) => ({
        role: m.role as "user" | "assistant",
        content: m.content,
      }));
    const fail = (message: string) => {
      patchMessage(conversationId, assistantId, {
        pending: false,
        error: message,
        incomplete: undefined,
        content: message,
      });
    };
    try {
      const apply = (ev: ChatEvent, acc: { content: string; tools: NonNullable<Message["tools"]> }) => {
        if (ev.type === "delta") {
          const chunk = acc.content ? ev.text : ev.text.replace(/^\s+/, "");
          if (!chunk) return "continue" as const;
          acc.content += chunk;
          patchMessage(conversationId, assistantId, { content: acc.content, pending: true });
          return "continue" as const;
        }
        if (ev.type === "tool") {
          acc.tools.push({
            id: uid(),
            name: ev.name,
            status: ev.status,
            detail: ev.detail,
          });
          patchMessage(conversationId, assistantId, { tools: [...acc.tools], pending: true });
          return "continue" as const;
        }
        patchMessage(conversationId, assistantId, {
          pending: false,
          error: ev.message,
          incomplete: undefined,
          content: acc.content || ev.message,
        });
        return "stop" as const;
      };

      const acc = { content: "", tools: [] as NonNullable<Message["tools"]> };

      if (gatewayPlace === "device") {
        const key = getDeviceSessionKey();
        if (!key || !gatewayUrl) {
          fail(tr("en", "error.connectDevice"));
          return;
        }
        for await (const ev of streamHermesDirect({
          url: gatewayUrl,
          key,
          conversationId,
          model,
          provider,
          messages: payload,
          signal: ctrl.signal,
        })) {
          if (apply(ev, acc) === "stop") return;
        }
        patchMessage(conversationId, assistantId, {
          content: acc.content || tr("en", "chat.noReply"),
          pending: false,
          incomplete: !acc.content,
        });
      } else {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: authHeaders({ "Content-Type": "application/json" }),
        signal: ctrl.signal,
        body: JSON.stringify({
          conversationId,
          model,
          provider,
          messages: payload,
        }),
      });
      const ct = res.headers.get("content-type") ?? "";
      if (!res.body) {
        fail(tr("en", "error.noReply"));
        return;
      }
      if (!res.ok && ct.includes("application/json") && !ct.includes("ndjson")) {
        fail(tr("en", "error.noReply"));
        return;
      }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = "";
      let content = "";
      const tools: NonNullable<Message["tools"]> = [];
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
            if (ev.type === "delta") {
              const chunk = content ? ev.text : ev.text.replace(/^\s+/, "");
              if (!chunk) continue;
              content += chunk;
              patchMessage(conversationId, assistantId, { content, pending: true });
            } else if (ev.type === "tool") {
              tools.push({
                id: uid(),
                name: ev.name,
                status: ev.status,
                detail: ev.detail,
              });
              patchMessage(conversationId, assistantId, { tools: [...tools], pending: true });
            } else if (ev.type === "error") {
              patchMessage(conversationId, assistantId, {
                pending: false,
                error: ev.message,
                incomplete: undefined,
                content: content || ev.message,
              });
              return;
            }
          } catch {
            // skip malformed
          }
        }
      }
      patchMessage(conversationId, assistantId, {
        content: content || tr("en", "chat.noReply"),
        pending: false,
        incomplete: !content,
      });
      }
    } catch (e) {
      if ((e as Error).name === "AbortError") {
        patchMessage(conversationId, assistantId, { pending: false, incomplete: true });
      } else {
        fail(tr("en", "error.connect"));
      }
    } finally {
      setSending(false);
      abortRef.current = null;
    }
  }

  function pickModel(id: string, nextProvider?: string) {
    setModel(id, nextProvider);
    setModelsOpen(false);
    if (!live || !gatewayUrl) return;
    void setHermesModel({
      url: gatewayUrl,
      key:
        gatewayPlace === "mac"
          ? getMacSessionKey() ?? undefined
          : gatewayPlace === "device"
            ? getDeviceSessionKey() ?? undefined
            : undefined,
      place: gatewayPlace,
      model: id,
      provider: nextProvider,
      conversationId: conv?.id,
    });
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

  async function onFiles(list: FileList | null) {
    if (!list) return;
    const next: Attachment[] = [];
    for (const file of Array.from(list)) {
      const kind = file.type.startsWith("image/") ? "image" : "file";
      const dataUrl = await readFile(file);
      next.push({ id: uid(), name: file.name, mime: file.type || "application/octet-stream", kind, dataUrl });
    }
    setFiles((prev) => [...prev, ...next]);
  }

  return (
    <div
      className={cn(
        "relative flex min-h-0 flex-1 flex-col",
        empty && "items-center justify-center pb-[10vh]",
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
        <div ref={scroller} className="min-h-0 flex-1 overflow-y-auto">
          <div
            className={cn(
              "alice-message-list mx-auto flex w-full max-w-2xl flex-col gap-6 px-4 pb-36 sm:px-6",
              firstIsUser ? "pt-[10vh]" : "pt-8",
            )}
          >
            {conv.messages.map((m, i) => {
              const text =
                m.role === "assistant"
                  ? displayMessageContent(locale, m.content.replace(/^\s+/, ""))
                  : m.content;
              const canRetry =
                m.role === "assistant" &&
                !m.pending &&
                Boolean(m.error || m.incomplete) &&
                lastAssistantId === m.id &&
                conv.messages.slice(0, i).some((msg) => msg.role === "user");
              return (
                <article
                  key={m.id}
                  className={cn("flex flex-col gap-2", m.role === "user" && "items-end")}
                >
                  {m.role === "user" ? null : (
                    <p className="text-2xs font-medium tracking-[0.12em] text-muted-foreground uppercase">
                      Alice
                    </p>
                  )}
                  <div
                    className={cn(
                      "alice-message max-w-[42rem] whitespace-pre-wrap text-sm leading-relaxed",
                      m.role === "user"
                        ? "alice-user-message rounded-xl bg-card px-4 py-3 shadow-border"
                        : "text-foreground",
                      m.error && "text-destructive",
                    )}
                  >
                    {text}
                    {m.pending ? <ReplyPending trail={Boolean(text)} /> : null}
                  </div>
                  {canRetry ? (
                    <button
                      type="button"
                      disabled={sending}
                      onClick={() => void retry(m.id)}
                      aria-label={t("chat.retry")}
                      className="inline-flex w-fit items-center gap-1.5 text-2xs text-muted-foreground hover:text-foreground disabled:opacity-40"
                    >
                      <RotateCw className="size-3" />
                      {t("chat.retry")}
                    </button>
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
          empty
            ? "mt-8 w-full max-w-2xl"
            : "pointer-events-none absolute inset-x-0 bottom-0 pb-5",
        )}
      >
        <div className={cn("mx-auto w-full max-w-2xl", !empty && "pointer-events-auto")}>
          {slash.length > 0 ? (
            <ul className="mb-2 overflow-hidden rounded-2xl bg-card py-1 shadow-border">
              {slash.map((item) => (
                <li key={item.cmd}>
                  <button
                    type="button"
                    className="flex w-full items-baseline gap-3 px-3 py-2 text-left text-sm hover:bg-accent"
                    onClick={() => setDraft(item.cmd + " ")}
                  >
                    <span className="font-mono text-xs">{item.cmd}</span>
                    <span className="text-muted-foreground">{slashHint(locale, item.cmd)}</span>
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
                  className="rounded-full bg-card px-2.5 py-1 text-2xs text-muted-foreground shadow-border"
                >
                  {f.name}
                </li>
              ))}
            </ul>
          ) : null}
          <div className="alice-composer rounded-2xl bg-card px-4 pb-3 pt-3 shadow-border">
            <Textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  void send();
                }
              }}
              placeholder={t("chat.placeholder")}
              rows={2}
              className="min-h-[2.5rem] w-full bg-transparent py-1 pl-2 pr-0 text-[15px] placeholder:text-muted-foreground/70"
            />
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
                  setAttachOpen(open);
                  if (open) setModelsOpen(false);
                }}
              >
                <DropdownMenuTrigger asChild>
                  <button
                    type="button"
                    aria-label={t("chat.add")}
                    className="grid size-8 place-items-center rounded-full text-muted-foreground hover:bg-accent hover:text-foreground"
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
                  setModelsOpen(open);
                  if (open) setAttachOpen(false);
                }}
              >
                <DropdownMenuTrigger asChild>
                  <button
                    type="button"
                    className="flex h-8 items-center gap-1 rounded-full px-2 text-sm text-foreground hover:bg-accent"
                  >
                    {currentLabel}
                    <ChevronDown className="size-3.5 text-muted-foreground" />
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent
                  align="start"
                  className="flex max-h-80 min-w-64 flex-col overflow-hidden p-1"
                  onOpenAutoFocus={(e) => {
                    e.preventDefault();
                    window.setTimeout(() => modelSearchRef.current?.focus(), 0);
                  }}
                >
                  {!live ? (
                    <DropdownMenuItem onSelect={() => void navigate({ to: "/connect" })}>
                      {t("chat.connectHermes")}
                    </DropdownMenuItem>
                  ) : (
                    <>
                      <div className="px-1 pb-1 pt-2">
                        <Input
                          ref={modelSearchRef}
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
                      <div className="min-h-0 flex-1 overflow-y-auto [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden">
                        {modelsLoading && modelChoices.length === 0 ? (
                          <DropdownMenuItem disabled>{t("chat.loadingModels")}</DropdownMenuItem>
                        ) : visibleGroups.length === 0 ? (
                          <DropdownMenuItem
                            onSelect={() => {
                              if (modelQuery.trim()) pickModel(modelQuery.trim());
                            }}
                          >
                            {modelQuery.trim()
                              ? t("chat.useModel", { model: modelQuery.trim() })
                              : t("chat.noModels")}
                          </DropdownMenuItem>
                        ) : (
                          visibleGroups.map((group, i) => (
                            <div key={group.slug}>
                              {i > 0 ? <DropdownMenuSeparator /> : null}
                              <DropdownMenuLabel>{group.name}</DropdownMenuLabel>
                              {group.models.map((m) => {
                                const on = m.id === model && (!provider || m.provider === provider);
                                return (
                                  <DropdownMenuItem
                                    key={`${m.provider}:${m.id}`}
                                    onSelect={() => pickModel(m.id, m.provider)}
                                    className={on ? "bg-accent" : undefined}
                                  >
                                    {m.label}
                                  </DropdownMenuItem>
                                );
                              })}
                            </div>
                          ))
                        )}
                      </div>
                    </>
                  )}
                </DropdownMenuContent>
              </DropdownMenu>
              <button
                type="button"
                aria-label={sending ? t("chat.stop") : t("chat.send")}
                disabled={!sending && !draft.trim()}
                onClick={() => (sending ? abortRef.current?.abort() : void send())}
                className="ml-auto grid size-9 place-items-center rounded-full bg-muted text-foreground disabled:opacity-40"
              >
                <svg viewBox="0 0 16 16" className="size-3.5" fill="none" aria-hidden>
                  <path
                    d="M8 12.5V3.5M8 3.5 3.5 8M8 3.5 12.5 8"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function ReplyPending({ trail = false }: { trail?: boolean }) {
  const t = useT();
  return (
    <span
      className={cn("alice-typing", trail && "alice-typing-trail")}
      role="status"
      aria-label={t("chat.pending")}
    >
      <span aria-hidden />
      <span aria-hidden />
      <span aria-hidden />
    </span>
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
