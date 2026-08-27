import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { Camera, ChevronDown, Image as ImageIcon, Paperclip, Plus } from "lucide-react";
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
  const conv = conversations.find((c) => c.id === activeId) ?? conversations[0];
  const slash = matchSlash(draft);
  const live = gatewayOn && gatewayStatus === "live";
  const empty = !conv || conv.messages.length === 0;
  const firstIsUser = Boolean(conv?.messages[0] && conv.messages[0].role === "user");
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
    setSending(true);
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      const apply = (ev: ChatEvent, acc: { content: string; tools: NonNullable<Message["tools"]> }) => {
        if (ev.type === "delta") {
          const chunk = acc.content ? ev.text : ev.text.replace(/^\s+/, "");
          if (!chunk) return "continue" as const;
          acc.content += chunk;
          patchMessage(conv.id, assistantId, { content: acc.content, pending: true });
          return "continue" as const;
        }
        if (ev.type === "tool") {
          acc.tools.push({
            id: uid(),
            name: ev.name,
            status: ev.status,
            detail: ev.detail,
          });
          patchMessage(conv.id, assistantId, { tools: [...acc.tools], pending: true });
          return "continue" as const;
        }
        patchMessage(conv.id, assistantId, {
          pending: false,
          error: ev.message,
          content: acc.content || ev.message,
        });
        return "stop" as const;
      };

      const acc = { content: "", tools: [] as NonNullable<Message["tools"]> };

      if (gatewayPlace === "device") {
        const key = getDeviceSessionKey();
        if (!key || !gatewayUrl) {
          patchMessage(conv.id, assistantId, {
            pending: false,
            error: "Conecta tu Hermes en este equipo.",
            content: "Conecta tu Hermes en este equipo.",
          });
          return;
        }
        for await (const ev of streamHermesDirect({
          url: gatewayUrl,
          key,
          conversationId: conv.id,
          model,
          provider,
          messages: [...conv.messages, user]
            .filter((m) => m.content.trim())
            .map((m) => ({
              role: m.role as "user" | "assistant",
              content: m.content,
            })),
          signal: ctrl.signal,
        })) {
          if (apply(ev, acc) === "stop") return;
        }
        patchMessage(conv.id, assistantId, {
          content: acc.content || "Sin respuesta.",
          pending: false,
        });
      } else {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: authHeaders({ "Content-Type": "application/json" }),
        signal: ctrl.signal,
        body: JSON.stringify({
          conversationId: conv.id,
          model,
          provider,
          messages: [...conv.messages, user]
            .filter((m) => m.content.trim())
            .map((m) => ({
              role: m.role,
              content: m.content,
            })),
        }),
      });
      if (!res.body) {
        patchMessage(conv.id, assistantId, {
          pending: false,
          error: "No se ha podido responder.",
          content: "No se ha podido responder.",
        });
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
              patchMessage(conv.id, assistantId, { content, pending: true });
            } else if (ev.type === "tool") {
              tools.push({
                id: uid(),
                name: ev.name,
                status: ev.status,
                detail: ev.detail,
              });
              patchMessage(conv.id, assistantId, { tools: [...tools], pending: true });
            } else if (ev.type === "error") {
              patchMessage(conv.id, assistantId, {
                pending: false,
                error: ev.message,
                content: content || ev.message,
              });
              return;
            }
          } catch {
            // skip malformed
          }
        }
      }
      patchMessage(conv.id, assistantId, {
        content: content || "Sin respuesta.",
        pending: false,
      });
      }
    } catch (e) {
      if ((e as Error).name === "AbortError") {
        patchMessage(conv.id, assistantId, { pending: false });
      } else {
        patchMessage(conv.id, assistantId, {
          pending: false,
          error: "No se ha podido conectar.",
          content: "No se ha podido conectar.",
        });
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
        <div className="flex flex-col items-center px-6 text-center">
          <Mark className="size-7 text-foreground" />
          <h1 className="mt-5 font-serif text-3xl tracking-tight sm:text-4xl">
            ¿En qué trabajamos?
          </h1>
          <p className="mt-2 text-sm text-muted-foreground">
            Hablas con Alice. Una cosa cada vez.
          </p>
        </div>
      ) : (
        <div ref={scroller} className="min-h-0 flex-1 overflow-y-auto">
          <div
            className={cn(
              "mx-auto flex w-full max-w-2xl flex-col gap-6 px-4 pb-36 sm:px-6",
              firstIsUser ? "pt-[10vh]" : "pt-8",
            )}
          >
            {conv.messages.map((m) => (
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
                    "max-w-[42rem] whitespace-pre-wrap text-sm leading-relaxed",
                    m.role === "user"
                      ? "rounded-xl bg-card px-4 py-3 shadow-border"
                      : "text-foreground",
                    m.error && "text-destructive",
                  )}
                >
                  {(m.role === "assistant" ? m.content.replace(/^\s+/, "") : m.content) ||
                    (m.pending ? "…" : "")}
                </div>
              </article>
            ))}
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
                    <span className="text-muted-foreground">{item.hint}</span>
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
          <div className="rounded-2xl bg-card px-4 pb-3 pt-3 shadow-border">
            <Textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  void send();
                }
              }}
              placeholder="Habla con Alice..."
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
                    aria-label="Añadir"
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
                    Cámara
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    onSelect={() => {
                      window.setTimeout(() => galleryRef.current?.click(), 0);
                    }}
                  >
                    <ImageIcon className="size-4" />
                    Galería
                  </DropdownMenuItem>
                  <DropdownMenuItem
                    onSelect={() => {
                      window.setTimeout(() => filesRef.current?.click(), 0);
                    }}
                  >
                    <Paperclip className="size-4" />
                    Archivos
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
                      Conecta tu Hermes
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
                          placeholder="Escribe el modelo..."
                          className="h-8 px-2"
                          autoComplete="off"
                        />
                      </div>
                      <div className="min-h-0 flex-1 overflow-y-auto [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden">
                        {modelsLoading && modelChoices.length === 0 ? (
                          <DropdownMenuItem disabled>Cargando modelos…</DropdownMenuItem>
                        ) : visibleGroups.length === 0 ? (
                          <DropdownMenuItem
                            onSelect={() => {
                              if (modelQuery.trim()) pickModel(modelQuery.trim());
                            }}
                          >
                            {modelQuery.trim()
                              ? `Usar ${modelQuery.trim()}`
                              : "Ningún modelo en Hermes"}
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
                aria-label={sending ? "Parar" : "Enviar"}
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

function readFile(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result ?? ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}
