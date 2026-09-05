import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
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
  MessagePatch,
  Webhook,
} from "./types";
import { isHermesProfileName } from "./hermes-profile";
import type {
  GatewayMeta,
  GatewayPlace,
  GatewayStatus,
  HermesModelOption,
} from "./gateway-contracts";
import { unionHermesModels } from "./gateway-contracts";
import { forgetHermesSecret } from "./hermes-secret-client";
import type { Locale } from "./i18n";
import { isLocale } from "./i18n";
import {
  cockpitIsOwner,
  cockpitUserId,
  COCKPIT_STORE,
} from "./auth/cockpit-user";
import { uid } from "./utils";
import { createHybridStorage } from "./hybrid-storage";
import {
  importHermesSessionConversation,
  type HermesSessionImport,
} from "./hermes-session-conversation";
import { clearHermesLiveCache } from "./hermes-live-cache";
import { applyMessagePatch } from "./message-patch";

const welcomeId = "welcome";
const freshId = "fresh";

function seedConversation(): Conversation {
  return {
    id: welcomeId,
    title: "Welcome",
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

function seedBlankChat(): Conversation {
  return {
    id: freshId,
    title: "New chat",
    createdAt: Date.now(),
    updatedAt: Date.now(),
    messages: [],
  };
}

/** "system" follows the OS; the other two pin it regardless of the OS. */
export type Theme = "dark" | "light" | "system";
export type FontSize = "sm" | "md" | "lg";
export type Accent = "stone" | "sage" | "sky" | "violet" | "rose" | "amber";
export type RecentModel = { id: string; provider: string };

const RECENT_MODEL_LIMIT = 5;

export function rememberRecentModel(
  recent: RecentModel[],
  model: RecentModel,
): RecentModel[] {
  const id = model.id.trim().slice(0, 512);
  const provider = model.provider.trim().slice(0, 256);
  if (!id) return recent;
  return [
    { id, provider },
    ...recent.filter((item) => item.id !== id || item.provider !== provider),
  ].slice(0, RECENT_MODEL_LIMIT);
}

function parseRecentModels(value: unknown): RecentModel[] {
  if (!Array.isArray(value)) return [];
  const parsed: RecentModel[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const candidate = item as Record<string, unknown>;
    if (
      typeof candidate.id !== "string" ||
      typeof candidate.provider !== "string"
    ) {
      continue;
    }
    const id = candidate.id.trim().slice(0, 512);
    const provider = candidate.provider.trim().slice(0, 256);
    if (
      !id ||
      parsed.some((model) => model.id === id && model.provider === provider)
    ) {
      continue;
    }
    parsed.push({ id, provider });
    if (parsed.length === RECENT_MODEL_LIMIT) break;
  }
  return parsed;
}

interface HermesState {
  hydrated: boolean;
  theme: Theme;
  fontSize: FontSize;
  accent: Accent;
  locale: Locale;
  sidebarCollapsed: boolean;
  focusMode: boolean;
  compact: boolean;
  cloudSyncEnabled: boolean;
  model: string;
  modelProvider: string;
  recentModels: RecentModel[];
  profile: string;
  skillEnabled: Record<string, boolean>;
  toolEnabled: Record<string, boolean>;
  addonEnabled: Record<string, boolean>;
  channelStatus: Record<string, ChannelStatus>;
  pinned: string[];
  conversations: Conversation[];
  conversationTombstones: Record<string, number>;
  /**
   * How far cloud sync has read, per account.
   *
   * Kept in the persisted state rather than in localStorage so that it is
   * written in the same IndexedDB transaction as the conversations it
   * describes. Apart, the two could disagree: the position saved and the
   * records not, which is how a device came to skip conversations that were
   * still in the cloud.
   */
  syncCursors: Record<string, string>;
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
  setLocale: (locale: Locale) => void;
  setSidebarCollapsed: (v: boolean) => void;
  setFocusMode: (v: boolean) => void;
  toggleFocus: () => void;
  setCompact: (v: boolean) => void;
  setCloudSyncEnabled: (v: boolean) => void;
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
  newChat: (profile?: string) => string;
  importHermesSession: (payload: HermesSessionImport) => string;
  selectChat: (id: string) => void;
  deleteChat: (id: string) => void;
  renameChat: (id: string, title: string) => void;
  pinChat: (id: string) => void;
  appendMessage: (conversationId: string, message: Message) => void;
  patchMessage: (
    conversationId: string,
    messageId: string,
    patch: MessagePatch,
  ) => void;
  truncateConversationAfter: (
    conversationId: string,
    messageId: string,
  ) => void;
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
  restoreGateway: (connection: { url: string; place: GatewayPlace }) => void;
  setGatewayChecking: () => void;
  setGatewayLive: (meta: GatewayMeta) => void;
  setGatewayModels: (
    models: HermesModelOption[],
    current?: { model?: string; provider?: string },
  ) => void;
  setGatewayDown: (error: string) => void;
  disconnectGateway: () => void;
  forgetGateway: () => void;
}

function initialHermesData() {
  const approvals: Approval[] = [
    {
      id: "a1",
      kind: "skill",
      title: "Installing docker-management changes nothing",
      detail:
        "The skill is already in the catalog. Hermes wants to mark it as daily-use and pin it.",
      targetId: "docker-management",
    },
  ];
  return {
    hydrated: false,
    theme: "system" as Theme,
    fontSize: "md" as FontSize,
    accent: "stone" as Accent,
    locale: "en" as Locale,
    sidebarCollapsed: false,
    focusMode: false,
    compact: false,
    cloudSyncEnabled: false,
    model: "hermes-agent",
    modelProvider: "",
    recentModels: [] as RecentModel[],
    profile: "default",
    skillEnabled: {} as Record<string, boolean>,
    toolEnabled: {} as Record<string, boolean>,
    addonEnabled: {} as Record<string, boolean>,
    channelStatus: {} as Record<string, ChannelStatus>,
    pinned: ["hermes-core", "grok", "web_search", "memory"],
    conversations: [seedBlankChat(), seedConversation()],
    conversationTombstones: {} as Record<string, number>,
    syncCursors: {} as Record<string, string>,
    activeId: freshId,
    memories: seedMemories,
    jobs: seedJobs,
    hooks: seedWebhooks,
    activeBackend: "local",
    approvals,
    composerDraft: "",
    gatewayUrl: "",
    gatewayPlace: "cloud" as GatewayPlace,
    gatewayOn: false,
    gatewayStatus: "idle" as GatewayStatus,
    gatewayMeta: null,
    gatewayError: null,
  };
}

export const useHermes = create<HermesState>()(
  persist(
    (set, get) => ({
      ...initialHermesData(),
      setHydrated: () => set({ hydrated: true }),
      setTheme: (theme) => set({ theme }),
      setFontSize: (fontSize) => set({ fontSize }),
      setAccent: (accent) => set({ accent }),
      setLocale: (locale) => set({ locale }),
      setSidebarCollapsed: (v) => set({ sidebarCollapsed: v }),
      setFocusMode: (v) => set({ focusMode: v }),
      toggleFocus: () => set({ focusMode: !get().focusMode }),
      setCompact: (v) => set({ compact: v }),
      setCloudSyncEnabled: (v) => set({ cloudSyncEnabled: v }),
      setModel: (id, provider) =>
        set((state) => {
          const nextProvider = provider ?? state.modelProvider;
          return {
            model: id,
            ...(provider !== undefined ? { modelProvider: provider } : {}),
            recentModels: rememberRecentModel(state.recentModels, {
              id,
              provider: nextProvider,
            }),
          };
        }),
      setProfile: (name) => {
        const profile = name.trim();
        if (isHermesProfileName(profile) && profile !== get().profile) {
          set({ profile });
          clearHermesLiveCache();
        }
      },
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
      newChat: (profile) => {
        const id = uid();
        const conv: Conversation = {
          id,
          title: "New chat",
          createdAt: Date.now(),
          updatedAt: Date.now(),
          messages: [],
          ...(profile && isHermesProfileName(profile)
            ? { hermesProfile: profile }
            : {}),
        };
        set({
          conversations: [conv, ...get().conversations],
          activeId: id,
          composerDraft: "",
        });
        return id;
      },
      importHermesSession: (payload) => {
        const imported = importHermesSessionConversation(
          get().conversations,
          payload,
          uid,
          Date.now(),
        );
        set({ ...imported, composerDraft: "" });
        return imported.activeId;
      },
      selectChat: (id) => set({ activeId: id }),
      deleteChat: (id) => {
        const next = get().conversations.filter((c) => c.id !== id);
        const list = next.length
          ? next
          : [{ ...seedBlankChat(), id: uid(), title: "New chat" }];
        set({
          conversations: list,
          conversationTombstones: {
            ...get().conversationTombstones,
            [id]: Date.now(),
          },
          activeId: get().activeId === id ? list[0]!.id : get().activeId,
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
                    (c.title === "New chat" || c.title === "Nuevo chat") &&
                    message.role === "user" &&
                    !message.content.startsWith("/")
                      ? message.content.slice(0, 42) || "New chat"
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
                    m.id === messageId ? applyMessagePatch(m, patch) : m,
                  ),
                }
              : c,
          ),
        }),
      truncateConversationAfter: (conversationId, messageId) =>
        set({
          conversations: get().conversations.map((c) => {
            if (c.id !== conversationId) return c;
            const index = c.messages.findIndex((m) => m.id === messageId);
            return index < 0
              ? c
              : {
                  ...c,
                  updatedAt: Date.now(),
                  messages: c.messages.slice(0, index + 1),
                };
          }),
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
        const id =
          name
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, "-")
            .replace(/(^-|-$)/g, "") || uid();
        set({
          approvals: get().approvals.filter((x) => x.id !== "learn-" + id),
        });
        const pinned = get().pinned.includes(id)
          ? get().pinned
          : [...get().pinned, id];
        set({ pinned });
        void from;
      },
      enabledSkillNames: () =>
        skills.filter((s) => get().isSkillOn(s.id)).map((s) => s.name),
      enabledToolNames: () =>
        tools.filter((t) => get().isToolOn(t.id)).map((t) => t.name),
      enabledAddonNames: () =>
        addons.filter((a) => get().isAddonOn(a.id)).map((a) => a.name),
      setGatewayPlace: (place) => {
        if (place === get().gatewayPlace) return;
        set({ gatewayPlace: place });
        clearHermesLiveCache();
      },
      setGatewayUrl: (url) => {
        if (url === get().gatewayUrl) return;
        set({ gatewayUrl: url });
        clearHermesLiveCache();
      },
      restoreGateway: ({ url, place }) => {
        const connectionChanged =
          url !== get().gatewayUrl || place !== get().gatewayPlace;
        set((state) => ({
          gatewayUrl: url,
          gatewayPlace: place,
          gatewayOn: true,
          gatewayStatus:
            state.gatewayStatus === "live" && state.gatewayUrl === url
              ? "live"
              : "idle",
          gatewayError: null,
        }));
        if (connectionChanged) clearHermesLiveCache();
      },
      setGatewayChecking: () =>
        set({ gatewayStatus: "checking", gatewayError: null }),
      setGatewayLive: (meta) => {
        const models = unionHermesModels([], meta.models ?? []);
        const currentId = get().model;
        const currentProvider = get().modelProvider;
        const stillSelected = models.some(
          (m) =>
            m.id === currentId &&
            (!currentProvider || m.provider === currentProvider),
        );
        const chosen = stillSelected
          ? models.find(
              (m) =>
                m.id === currentId &&
                (!currentProvider || m.provider === currentProvider),
            )
          : models.find((m) => m.id === meta.model);
        set({
          gatewayOn: true,
          gatewayStatus: "live",
          gatewayMeta: { ...meta, models },
          gatewayError: null,
          ...(stillSelected
            ? chosen?.provider && !currentProvider
              ? { modelProvider: chosen.provider }
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
        const nextModels = unionHermesModels([], models);
        const chosen = current?.model
          ? nextModels.find(
              (item) =>
                item.id === current.model &&
                (!current.provider || item.provider === current.provider),
            )
          : undefined;
        set({
          gatewayMeta: {
            ...meta,
            models: nextModels,
          },
          ...(current?.model
            ? {
                model: current.model,
                modelProvider:
                  current.provider || chosen?.provider || meta.provider || "",
              }
            : {}),
        });
      },
      setGatewayDown: (error) =>
        set({
          gatewayStatus: "down",
          gatewayError: error,
        }),
      disconnectGateway: () => {
        set({
          gatewayOn: false,
          gatewayStatus: "idle",
          gatewayMeta: null,
          gatewayError: null,
        });
        clearHermesLiveCache();
      },
      forgetGateway: () => {
        void forgetHermesSecret();
        set({
          gatewayUrl: "",
          gatewayOn: false,
          gatewayStatus: "idle",
          gatewayMeta: null,
          gatewayError: null,
        });
        clearHermesLiveCache();
      },
    }),
    {
      name: COCKPIT_STORE,
      storage: createJSONStorage(() =>
        createHybridStorage({
          userId: cockpitUserId,
          isLegacyOwner: cockpitIsOwner,
        }),
      ),
      skipHydration: true,
      version: 11,
      migrate: (persisted) => {
        if (persisted && typeof persisted === "object") {
          const next = { ...(persisted as Record<string, unknown>) };
          delete next.gatewayKey;
          if (
            next.gatewayOn &&
            next.gatewayMeta &&
            typeof next.gatewayMeta === "object"
          ) {
            next.gatewayStatus = "live";
          }
          if (!isLocale(next.locale)) {
            next.locale = "en";
          }
          if (
            typeof next.profile !== "string" ||
            !isHermesProfileName(next.profile)
          ) {
            next.profile = "default";
          }
          if (
            next.model === "gpt-5.6-luna" ||
            next.model === "grok-4.5" ||
            next.model === "claude-sonnet"
          ) {
            next.model = "hermes-agent";
            next.modelProvider = "";
          }
          const recentModels = parseRecentModels(next.recentModels);
          next.recentModels = recentModels;
          if (recentModels.length === 0 && typeof next.model === "string") {
            next.recentModels = rememberRecentModel([], {
              id: next.model,
              provider:
                typeof next.modelProvider === "string"
                  ? next.modelProvider
                  : "",
            });
          }
          if (
            next.fontSize !== "sm" &&
            next.fontSize !== "md" &&
            next.fontSize !== "lg"
          ) {
            next.fontSize = "md";
          }
          delete next.designMode;
          if (typeof next.cloudSyncEnabled !== "boolean") {
            next.cloudSyncEnabled = false;
          }
          if (
            !next.conversationTombstones ||
            typeof next.conversationTombstones !== "object" ||
            Array.isArray(next.conversationTombstones)
          ) {
            next.conversationTombstones = {};
          }
          if (Array.isArray(next.conversations)) {
            next.conversations = next.conversations.map((value) => {
              if (!value || typeof value !== "object" || Array.isArray(value)) {
                return value;
              }
              const conversation = { ...(value as Record<string, unknown>) };
              if (
                typeof conversation.hermesSessionId !== "string" ||
                !conversation.hermesSessionId.trim() ||
                conversation.hermesSessionId.length > 160
              ) {
                delete conversation.hermesSessionId;
              }
              if (
                typeof conversation.hermesProfile !== "string" ||
                !isHermesProfileName(conversation.hermesProfile)
              ) {
                delete conversation.hermesProfile;
              }
              return conversation;
            });
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
          if (
            next.gatewayPlace !== "cloud" &&
            next.gatewayPlace !== "mac" &&
            next.gatewayPlace !== "device"
          ) {
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
        locale: s.locale,
        sidebarCollapsed: s.sidebarCollapsed,
        focusMode: s.focusMode,
        compact: s.compact,
        cloudSyncEnabled: s.cloudSyncEnabled,
        model: s.model,
        modelProvider: s.modelProvider,
        recentModels: s.recentModels,
        profile: s.profile,
        skillEnabled: s.skillEnabled,
        toolEnabled: s.toolEnabled,
        addonEnabled: s.addonEnabled,
        channelStatus: s.channelStatus,
        pinned: s.pinned,
        conversations: s.conversations,
        conversationTombstones: s.conversationTombstones,
        syncCursors: s.syncCursors,
        activeId: s.activeId,
        memories: s.memories,
        jobs: s.jobs,
        hooks: s.hooks,
        activeBackend: s.activeBackend,
        approvals: s.approvals,
        gatewayUrl: s.gatewayUrl,
        gatewayPlace: s.gatewayPlace,
        gatewayOn: s.gatewayOn,
        gatewayStatus: s.gatewayStatus === "live" ? "live" : "idle",
        gatewayMeta: s.gatewayMeta,
      }),
      onRehydrateStorage: () => () => {
        useHermes.getState().setHydrated();
      },
    },
  ),
);

/** Clear account-bound state while storage has no active identity. */
export function resetHermesAccountState() {
  useHermes.setState(initialHermesData());
}
