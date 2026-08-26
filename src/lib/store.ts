import { create } from "zustand";
import { persist } from "zustand/middleware";
import {
  addons,
  channels,
  jobs as seedJobs,
  memories as seedMemories,
  skills,
  tools,
  WELCOME,
  webhooks as seedWebhooks,
} from "./catalog";
import type {
  Approval,
  ChannelStatus,
  Conversation,
  Job,
  MemoryItem,
  Message,
  Webhook,
} from "./types";
import type { GatewayMeta, GatewayPlace, GatewayStatus, HermesModelOption } from "./gateway";
import { forgetHermesSecret } from "./gateway";
import { uid } from "./utils";

const welcomeId = "welcome";

function seedConversation(): Conversation {
  return {
    id: welcomeId,
    title: "Bienvenida",
    createdAt: Date.now() - 1000 * 60 * 8,
    updatedAt: Date.now() - 1000 * 60 * 8,
    messages: [
      {
        id: "welcome-msg",
        role: "assistant",
        content: WELCOME,
        createdAt: Date.now() - 1000 * 60 * 8,
      },
    ],
  };
}

export type Theme = "dark" | "light";
export type FontSize = "sm" | "md" | "lg";
export type Accent = "stone" | "sage" | "sky" | "violet" | "rose" | "amber";

interface HermesState {
  hydrated: boolean;
  theme: Theme;
  fontSize: FontSize;
  accent: Accent;
  sidebarCollapsed: boolean;
  focusMode: boolean;
  compact: boolean;
  model: string;
  modelProvider: string;
  profile: string;
  skillEnabled: Record<string, boolean>;
  toolEnabled: Record<string, boolean>;
  addonEnabled: Record<string, boolean>;
  channelStatus: Record<string, ChannelStatus>;
  pinned: string[];
  conversations: Conversation[];
  activeId: string;
  memories: MemoryItem[];
  jobs: Job[];
  hooks: Webhook[];
  activeBackend: string;
  approvals: Approval[];
  composerDraft: string;
  gatewayUrl: string;
  gatewayPlace: GatewayPlace;
  gatewayOn: boolean;
  gatewayStatus: GatewayStatus;
  gatewayMeta: GatewayMeta | null;
  gatewayError: string | null;
  setHydrated: () => void;
  setTheme: (theme: Theme) => void;
  setFontSize: (size: FontSize) => void;
  setAccent: (accent: Accent) => void;
  setSidebarCollapsed: (v: boolean) => void;
  setFocusMode: (v: boolean) => void;
  toggleFocus: () => void;
  setCompact: (v: boolean) => void;
  setModel: (id: string, provider?: string) => void;
  setProfile: (name: string) => void;
  isSkillOn: (id: string) => boolean;
  isToolOn: (id: string) => boolean;
  isAddonOn: (id: string) => boolean;
  channelOf: (id: string) => ChannelStatus;
  toggleSkill: (id: string) => void;
  toggleTool: (id: string) => void;
  toggleAddon: (id: string) => void;
  setChannel: (id: string, status: ChannelStatus) => void;
  togglePin: (id: string) => void;
  isPinned: (id: string) => boolean;
  setDraft: (v: string) => void;
  newChat: () => string;
  selectChat: (id: string) => void;
  deleteChat: (id: string) => void;
  renameChat: (id: string, title: string) => void;
  pinChat: (id: string) => void;
  appendMessage: (conversationId: string, message: Message) => void;
  patchMessage: (conversationId: string, messageId: string, patch: Partial<Message>) => void;
  addMemory: (item: Omit<MemoryItem, "id" | "updatedAt">) => void;
  removeMemory: (id: string) => void;
  toggleJob: (id: string) => void;
  toggleHook: (id: string) => void;
  setBackend: (id: string) => void;
  resolveApproval: (id: string, accept: boolean) => void;
  learnSkill: (payload: { name: string; from: string }) => void;
  enabledSkillNames: () => string[];
  enabledToolNames: () => string[];
  enabledAddonNames: () => string[];
  setGatewayPlace: (place: GatewayPlace) => void;
  setGatewayUrl: (url: string) => void;
  setGatewayChecking: () => void;
  setGatewayLive: (meta: GatewayMeta) => void;
  setGatewayModels: (models: HermesModelOption[], current?: { model?: string; provider?: string }) => void;
  setGatewayDown: (error: string) => void;
  disconnectGateway: () => void;
  forgetGateway: () => void;
}

export const useHermes = create<HermesState>()(
  persist(
    (set, get) => ({
      hydrated: false,
      theme: "dark",
      fontSize: "md",
      accent: "stone",
      sidebarCollapsed: false,
      focusMode: false,
      compact: false,
      model: "grok-4.5",
      modelProvider: "",
      profile: "default",
      skillEnabled: {},
      toolEnabled: {},
      addonEnabled: {},
      channelStatus: {},
      pinned: ["hermes-core", "grok", "web_search", "memory"],
      conversations: [seedConversation()],
      activeId: welcomeId,
      memories: seedMemories,
      jobs: seedJobs,
      hooks: seedWebhooks,
      activeBackend: "local",
      approvals: [
        {
          id: "a1",
          kind: "skill",
          title: "Instalar docker-management no cambia nada",
          detail:
            "La skill ya está en el catálogo. Hermes quiere marcarla como de uso diario y anclarla.",
          targetId: "docker-management",
        },
      ],
      composerDraft: "",
      gatewayUrl: "",
      gatewayPlace: "cloud",
      gatewayOn: false,
      gatewayStatus: "idle",
      gatewayMeta: null,
      gatewayError: null,
      setHydrated: () => set({ hydrated: true }),
      setTheme: (theme) => set({ theme }),
      setFontSize: (fontSize) => set({ fontSize }),
      setAccent: (accent) => set({ accent }),
      setSidebarCollapsed: (v) => set({ sidebarCollapsed: v }),
      setFocusMode: (v) => set({ focusMode: v }),
      toggleFocus: () => set({ focusMode: !get().focusMode }),
      setCompact: (v) => set({ compact: v }),
      setModel: (id, provider) =>
        set({
          model: id,
          ...(provider !== undefined ? { modelProvider: provider } : {}),
        }),
      setProfile: (name) => set({ profile: name }),
      isSkillOn: (id) => {
        const o = get().skillEnabled[id];
        if (typeof o === "boolean") return o;
        return skills.find((s) => s.id === id)?.defaultEnabled ?? false;
      },
      isToolOn: (id) => {
        const o = get().toolEnabled[id];
        if (typeof o === "boolean") return o;
        return tools.find((t) => t.id === id)?.defaultEnabled ?? false;
      },
      isAddonOn: (id) => {
        const o = get().addonEnabled[id];
        if (typeof o === "boolean") return o;
        return addons.find((a) => a.id === id)?.defaultEnabled ?? false;
      },
      channelOf: (id) => {
        const o = get().channelStatus[id];
        if (o) return o;
        return channels.find((c) => c.id === id)?.defaultStatus ?? "off";
      },
      toggleSkill: (id) =>
        set({
          skillEnabled: { ...get().skillEnabled, [id]: !get().isSkillOn(id) },
        }),
      toggleTool: (id) =>
        set({
          toolEnabled: { ...get().toolEnabled, [id]: !get().isToolOn(id) },
        }),
      toggleAddon: (id) =>
        set({
          addonEnabled: { ...get().addonEnabled, [id]: !get().isAddonOn(id) },
        }),
      setChannel: (id, status) =>
        set({
          channelStatus: { ...get().channelStatus, [id]: status },
        }),
      togglePin: (id) => {
        const pinned = get().pinned.includes(id)
          ? get().pinned.filter((x) => x !== id)
          : [...get().pinned, id];
        set({ pinned });
      },
      isPinned: (id) => get().pinned.includes(id),
      setDraft: (v) => set({ composerDraft: v }),
      newChat: () => {
        const id = uid();
        const conv: Conversation = {
          id,
          title: "Nuevo chat",
          createdAt: Date.now(),
          updatedAt: Date.now(),
          messages: [],
        };
        set({
          conversations: [conv, ...get().conversations],
          activeId: id,
          composerDraft: "",
        });
        return id;
      },
      selectChat: (id) => set({ activeId: id }),
      deleteChat: (id) => {
        const next = get().conversations.filter((c) => c.id !== id);
        const list = next.length ? next : [seedConversation()];
        set({
          conversations: list,
          activeId: get().activeId === id ? list[0].id : get().activeId,
        });
      },
      renameChat: (id, title) => {
        const next = title.trim().slice(0, 80);
        if (!next) return;
        set({
          conversations: get().conversations.map((c) =>
            c.id === id ? { ...c, title: next, updatedAt: Date.now() } : c,
          ),
        });
      },
      pinChat: (id) => {
        set({
          conversations: get().conversations.map((c) =>
            c.id === id ? { ...c, pinned: !c.pinned } : c,
          ),
        });
      },
      appendMessage: (conversationId, message) =>
        set({
          conversations: get().conversations.map((c) =>
            c.id === conversationId
              ? {
                  ...c,
                  updatedAt: Date.now(),
                  title:
                    c.title === "Nuevo chat" &&
                    message.role === "user" &&
                    !message.content.startsWith("/")
                      ? message.content.slice(0, 42) || "Nuevo chat"
                      : c.title,
                  messages: [...c.messages, message],
                }
              : c,
          ),
        }),
      patchMessage: (conversationId, messageId, patch) =>
        set({
          conversations: get().conversations.map((c) =>
            c.id === conversationId
              ? {
                  ...c,
                  updatedAt: Date.now(),
                  messages: c.messages.map((m) =>
                    m.id === messageId ? { ...m, ...patch } : m,
                  ),
                }
              : c,
          ),
        }),
      addMemory: (item) =>
        set({
          memories: [
            { ...item, id: uid(), updatedAt: Date.now() },
            ...get().memories,
          ],
        }),
      removeMemory: (id) =>
        set({ memories: get().memories.filter((m) => m.id !== id) }),
      toggleJob: (id) =>
        set({
          jobs: get().jobs.map((j) =>
            j.id === id
              ? { ...j, status: j.status === "active" ? "paused" : "active" }
              : j,
          ),
        }),
      toggleHook: (id) =>
        set({
          hooks: get().hooks.map((h) =>
            h.id === id ? { ...h, enabled: !h.enabled } : h,
          ),
        }),
      setBackend: (id) => set({ activeBackend: id }),
      resolveApproval: (id, accept) => {
        const a = get().approvals.find((x) => x.id === id);
        if (accept && a?.kind === "skill") {
          set({
            skillEnabled: { ...get().skillEnabled, [a.targetId]: true },
            pinned: get().pinned.includes(a.targetId)
              ? get().pinned
              : [...get().pinned, a.targetId],
          });
        }
        set({ approvals: get().approvals.filter((x) => x.id !== id) });
      },
      learnSkill: ({ name, from }) => {
        const id = name
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/(^-|-$)/g, "") || uid();
        set({
          approvals: get().approvals.filter((x) => x.id !== "learn-" + id),
        });
        const pinned = get().pinned.includes(id) ? get().pinned : [...get().pinned, id];
        set({ pinned });
        void from;
      },
      enabledSkillNames: () =>
        skills.filter((s) => get().isSkillOn(s.id)).map((s) => s.name),
      enabledToolNames: () =>
        tools.filter((t) => get().isToolOn(t.id)).map((t) => t.name),
      enabledAddonNames: () =>
        addons.filter((a) => get().isAddonOn(a.id)).map((a) => a.name),
      setGatewayPlace: (place) => set({ gatewayPlace: place }),
      setGatewayUrl: (url) => set({ gatewayUrl: url }),
      setGatewayChecking: () => set({ gatewayStatus: "checking", gatewayError: null }),
      setGatewayLive: (meta) => {
        const ids = new Set((meta.models ?? []).map((m) => m.id));
        const keep = ids.size === 0 || ids.has(get().model);
        const chosen =
          keep
            ? meta.models?.find((m) => m.id === get().model)
            : meta.models?.find((m) => m.id === meta.model);
        set({
          gatewayOn: true,
          gatewayStatus: "live",
          gatewayMeta: meta,
          gatewayError: null,
          ...(keep
            ? chosen?.provider
              ? { modelProvider: chosen.provider }
              : meta.provider
                ? { modelProvider: meta.provider }
                : {}
            : {
                model: meta.model,
                modelProvider: chosen?.provider || meta.provider || "",
              }),
        });
      },
      setGatewayModels: (models, current) => {
        const meta = get().gatewayMeta;
        if (!meta) return;
        const nextModel = current?.model || meta.model;
        const nextProvider = current?.provider || meta.provider;
        set({
          gatewayMeta: {
            ...meta,
            models,
            model: nextModel,
            provider: nextProvider,
          },
        });
      },
      setGatewayDown: (error) =>
        set({
          gatewayStatus: "down",
          gatewayError: error,
        }),
      disconnectGateway: () =>
        set({
          gatewayOn: false,
          gatewayStatus: "idle",
          gatewayMeta: null,
          gatewayError: null,
        }),
      forgetGateway: () => {
        void forgetHermesSecret();
        set({
          gatewayUrl: "",
          gatewayOn: false,
          gatewayStatus: "idle",
          gatewayMeta: null,
          gatewayError: null,
        });
      },
    }),
    {
      name: "hermes-cockpit-v1",
      version: 2,
      migrate: (persisted) => {
        if (persisted && typeof persisted === "object") {
          const next = { ...(persisted as Record<string, unknown>) };
          delete next.gatewayKey;
          if (typeof next.modelProvider !== "string") {
            next.modelProvider = "";
          }
          if (next.fontSize !== "sm" && next.fontSize !== "md" && next.fontSize !== "lg") {
            next.fontSize = "md";
          }
          if (
            next.accent !== "stone" &&
            next.accent !== "sage" &&
            next.accent !== "sky" &&
            next.accent !== "violet" &&
            next.accent !== "rose" &&
            next.accent !== "amber"
          ) {
            next.accent = "stone";
          }
          if (next.gatewayPlace !== "cloud" && next.gatewayPlace !== "mac") {
            next.gatewayPlace = "cloud";
          }
          return next;
        }
        return persisted as HermesState;
      },
      partialize: (s) => ({
        theme: s.theme,
        fontSize: s.fontSize,
        accent: s.accent,
        sidebarCollapsed: s.sidebarCollapsed,
        focusMode: s.focusMode,
        compact: s.compact,
        model: s.model,
        modelProvider: s.modelProvider,
        profile: s.profile,
        skillEnabled: s.skillEnabled,
        toolEnabled: s.toolEnabled,
        addonEnabled: s.addonEnabled,
        channelStatus: s.channelStatus,
        pinned: s.pinned,
        conversations: s.conversations,
        activeId: s.activeId,
        memories: s.memories,
        jobs: s.jobs,
        hooks: s.hooks,
        activeBackend: s.activeBackend,
        approvals: s.approvals,
        gatewayUrl: s.gatewayUrl,
        gatewayPlace: s.gatewayPlace,
        gatewayOn: s.gatewayOn,
      }),
      onRehydrateStorage: () => () => {
        useHermes.getState().setHydrated();
      },
    },
  ),
);
