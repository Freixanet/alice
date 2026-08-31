import { useEffect, useMemo, useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import {
  CircleUser,
  Keyboard,
  LogOut,
  Search,
  SlidersHorizontal,
  Sparkles,
  X,
  type LucideIcon,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Kbd } from "@/components/ui/kbd";
import { Switch } from "@/components/ui/switch";
import {
  getMacSessionKey,
  groupHermesModels,
  prettyProvider,
} from "@/lib/gateway";
import { listHermesModels, setHermesModel } from "@/lib/hermes-client";
import { getDeviceSessionKey } from "@/lib/hermes-direct";
import { authEnabled, signOut } from "@/lib/auth/client";
import { useCurrentUser } from "@/lib/auth/use-current-user";
import { useHermes, type Accent, type FontSize } from "@/lib/store";
import { Button } from "@/components/ui/button";
import { HermesProfilesSettings } from "@/components/hermes-profiles-settings";
import { cn } from "@/lib/utils";
import { useT } from "@/lib/use-i18n";
import type { MsgKey } from "@/lib/i18n";
import type { Locale } from "@/lib/i18n";
import {
  decodeRecoveryPhrase,
  encodeRecoveryPhrase,
  generateMasterSecret,
} from "@/lib/sync-crypto";
import {
  loadMasterSecretForDevice,
  saveMasterSecretForDevice,
} from "@/lib/sync-device-key";

type SectionId = "general" | "model" | "profile" | "account" | "shortcuts";

const SECTION_META: {
  id: SectionId;
  labelKey: MsgKey;
  keywordsKey: MsgKey;
  icon: LucideIcon;
}[] = [
  {
    id: "general",
    labelKey: "settings.general",
    keywordsKey: "settings.keywords.general",
    icon: SlidersHorizontal,
  },
  {
    id: "model",
    labelKey: "settings.model",
    keywordsKey: "settings.keywords.model",
    icon: Sparkles,
  },
  {
    id: "profile",
    labelKey: "settings.profile",
    keywordsKey: "settings.keywords.profile",
    icon: CircleUser,
  },
  {
    id: "account",
    labelKey: "settings.account",
    keywordsKey: "settings.keywords.account",
    icon: LogOut,
  },
  {
    id: "shortcuts",
    labelKey: "settings.shortcuts",
    keywordsKey: "settings.keywords.shortcuts",
    icon: Keyboard,
  },
];

export function SettingsDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const t = useT();
  const [mobile, setMobile] = useState(false);
  const [sectionId, setSectionId] = useState<SectionId>("general");
  const [query, setQuery] = useState("");

  useEffect(() => {
    const media = window.matchMedia("(max-width: 767px)");
    const update = () => setMobile(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  useEffect(() => {
    if (!open) return;
    setSectionId("general");
    setQuery("");
  }, [open]);

  const sections = useMemo(
    () =>
      SECTION_META.map((s) => ({
        ...s,
        label: t(s.labelKey),
        keywords: t(s.keywordsKey),
      })),
    [t],
  );

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return sections;
    return sections.filter((s) =>
      `${s.label} ${s.keywords}`.toLowerCase().includes(q),
    );
  }, [query, sections]);

  const current = filtered.find((s) => s.id === sectionId) ?? filtered[0];

  useEffect(() => {
    if (current && current.id !== sectionId) setSectionId(current.id);
  }, [current, sectionId]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange} modal={!mobile}>
      <DialogContent className="!inset-0 !h-dvh !w-full !max-w-none !translate-x-0 !translate-y-0 !rounded-none flex flex-col gap-0 overflow-hidden p-0 md:!top-1/2 md:!left-1/2 md:!h-[min(38rem,85vh)] md:!w-[calc(100%-2rem)] md:!max-w-3xl md:!-translate-x-1/2 md:!-translate-y-1/2 md:!rounded-xl md:flex-row [&>button]:hidden">
        <DialogDescription className="sr-only">
          {t("settings.title")}
        </DialogDescription>
        <nav className="flex w-full shrink-0 flex-col border-b border-border p-3 md:w-52 md:border-r md:border-b-0">
          <div className="mb-3 flex min-w-0 items-center gap-2 md:block">
            <DialogClose asChild>
              <button
                type="button"
                aria-label={t("settings.close")}
                className="grid size-9 shrink-0 place-items-center rounded-full text-muted-foreground hover:bg-accent hover:text-foreground md:mb-3 md:size-8 md:rounded-md"
              >
                <X className="size-4" />
              </button>
            </DialogClose>
            <div className="relative min-w-0 flex-1">
              <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder={t("settings.search")}
                aria-label={t("settings.search")}
                className="h-9 rounded-lg pl-8"
              />
            </div>
          </div>
          <ul className="flex shrink-0 gap-1 overflow-x-auto pb-1 md:min-h-0 md:flex-1 md:flex-col md:gap-0.5 md:overflow-y-auto md:pb-0">
            {filtered.length === 0 ? (
              <li className="px-2.5 py-2 text-sm text-muted-foreground">
                {t("settings.noMatch")}
              </li>
            ) : (
              filtered.map((s) => {
                const on = s.id === current?.id;
                return (
                  <li key={s.id} className="shrink-0 md:shrink">
                    <button
                      type="button"
                      onClick={() => setSectionId(s.id)}
                      className={cn(
                        "flex w-full items-center gap-2.5 whitespace-nowrap rounded-lg px-2.5 py-2 text-left text-sm",
                        on
                          ? "bg-accent text-foreground"
                          : "text-foreground/80 hover:bg-accent hover:text-foreground",
                      )}
                    >
                      <s.icon className="size-4 shrink-0" strokeWidth={1.75} />
                      {s.label}
                    </button>
                  </li>
                );
              })
            )}
          </ul>
        </nav>
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          <div className="min-h-0 flex-1 overflow-y-auto px-4 py-5 md:px-8 md:py-6">
            {current ? (
              <>
                <DialogTitle className="mb-4 text-xl font-medium tracking-tight md:mb-5">
                  {current.label}
                </DialogTitle>
                {current.id === "general" ? <GeneralSection /> : null}
                {current.id === "model" ? (
                  <ModeloSection onNavigate={() => onOpenChange(false)} />
                ) : null}
                {current.id === "profile" ? (
                  <PerfilSection onNavigate={() => onOpenChange(false)} />
                ) : null}
                {current.id === "account" ? <CuentaSection /> : null}
                {current.id === "shortcuts" ? <AtajosSection /> : null}
              </>
            ) : (
              <>
                <DialogTitle className="sr-only">
                  {t("settings.title")}
                </DialogTitle>
                <p className="text-sm text-muted-foreground">
                  {t("settings.noMatch")}
                </p>
              </>
            )}
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

function GeneralSection() {
  const t = useT();
  const theme = useHermes((s) => s.theme);
  const setTheme = useHermes((s) => s.setTheme);
  const fontSize = useHermes((s) => s.fontSize);
  const setFontSize = useHermes((s) => s.setFontSize);
  const accent = useHermes((s) => s.accent);
  const setAccent = useHermes((s) => s.setAccent);
  const locale = useHermes((s) => s.locale);
  const setLocale = useHermes((s) => s.setLocale);
  const compact = useHermes((s) => s.compact);
  const setCompact = useHermes((s) => s.setCompact);
  const focusMode = useHermes((s) => s.focusMode);
  const setFocusMode = useHermes((s) => s.setFocusMode);
  const cloudSyncEnabled = useHermes((s) => s.cloudSyncEnabled);
  const setCloudSyncEnabled = useHermes((s) => s.setCloudSyncEnabled);
  const user = useCurrentUser();
  const [recoveryPhrase, setRecoveryPhrase] = useState<string | null>(null);
  const [pendingMaster, setPendingMaster] = useState<Uint8Array | null>(null);
  const [recoveryConfirmation, setRecoveryConfirmation] = useState("");
  const [syncBusy, setSyncBusy] = useState(false);
  const [syncError, setSyncError] = useState<string | null>(null);
  const [importingRecovery, setImportingRecovery] = useState(false);

  async function changeCloudSync(enabled: boolean) {
    if (!enabled) {
      setCloudSyncEnabled(false);
      setRecoveryPhrase(null);
      setPendingMaster(null);
      setRecoveryConfirmation("");
      setImportingRecovery(false);
      return;
    }
    if (!user || syncBusy) return;
    setSyncBusy(true);
    setSyncError(null);
    try {
      const existing = await loadMasterSecretForDevice(user.id);
      if (existing) {
        setCloudSyncEnabled(true);
      } else {
        const master = generateMasterSecret();
        setPendingMaster(master);
        setRecoveryPhrase(encodeRecoveryPhrase(master));
      }
    } catch {
      setSyncError(t("settings.syncSetupError"));
    } finally {
      setSyncBusy(false);
    }
  }

  async function confirmRecovery() {
    if (!user || !pendingMaster || !recoveryPhrase || syncBusy) return;
    if (recoveryConfirmation.trim() !== recoveryPhrase) {
      setSyncError(t("settings.recoveryError"));
      return;
    }
    setSyncBusy(true);
    setSyncError(null);
    try {
      await saveMasterSecretForDevice(user.id, pendingMaster);
      setCloudSyncEnabled(true);
      setRecoveryPhrase(null);
      setPendingMaster(null);
      setRecoveryConfirmation("");
    } catch {
      setSyncError(t("settings.syncSetupError"));
    } finally {
      setSyncBusy(false);
    }
  }

  async function importRecovery() {
    if (!user || syncBusy) return;
    setSyncBusy(true);
    setSyncError(null);
    try {
      const master = decodeRecoveryPhrase(recoveryConfirmation);
      await saveMasterSecretForDevice(user.id, master);
      setCloudSyncEnabled(true);
      setImportingRecovery(false);
      setRecoveryConfirmation("");
    } catch {
      setSyncError(t("settings.recoveryError"));
    } finally {
      setSyncBusy(false);
    }
  }

  return (
    <div className="divide-y divide-border">
      <SettingRow
        label={t("settings.lightTheme")}
        hint={t("settings.lightThemeHint")}
      >
        <Switch
          checked={theme === "light"}
          onCheckedChange={(v) => setTheme(v ? "light" : "dark")}
          aria-label={t("settings.lightTheme")}
        />
      </SettingRow>
      <SettingRow
        label={t("settings.fontSize")}
        hint={t("settings.fontSizeHint")}
      >
        <div
          className="flex rounded-lg bg-muted p-0.5"
          role="radiogroup"
          aria-label={t("settings.fontSize")}
        >
          {FONT_SIZES.map((opt) => (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={fontSize === opt.id}
              onClick={() => setFontSize(opt.id)}
              className={cn(
                "h-8 rounded-md px-2.5 text-xs font-medium",
                fontSize === opt.id
                  ? "bg-card text-foreground shadow-border"
                  : "text-muted-foreground hover:text-foreground",
              )}
            >
              {t(opt.labelKey)}
            </button>
          ))}
        </div>
      </SettingRow>
      <SettingRow label={t("settings.color")} hint={t("settings.colorHint")}>
        <div
          className="flex flex-wrap justify-start gap-2 md:justify-end"
          role="radiogroup"
          aria-label={t("settings.color")}
        >
          {ACCENTS.map((opt) => (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={accent === opt.id}
              aria-label={t(opt.labelKey)}
              title={t(opt.labelKey)}
              onClick={() => setAccent(opt.id)}
              className={cn(
                "size-7 rounded-full",
                accent === opt.id
                  ? "ring-2 ring-foreground ring-offset-2 ring-offset-popover"
                  : "hover:scale-105",
              )}
              style={{ background: opt.swatch }}
            />
          ))}
        </div>
      </SettingRow>
      <SettingRow
        label={t("settings.compact")}
        hint={t("settings.compactHint")}
      >
        <Switch
          checked={compact}
          onCheckedChange={setCompact}
          aria-label={t("settings.compact")}
        />
      </SettingRow>
      <SettingRow label={t("settings.focus")} hint={t("settings.focusHint")}>
        <Switch
          checked={focusMode}
          onCheckedChange={setFocusMode}
          aria-label={t("settings.focus")}
        />
      </SettingRow>
      <SettingRow
        label={t("settings.cloudSync")}
        hint={t("settings.cloudSyncHint")}
      >
        <Switch
          checked={cloudSyncEnabled}
          disabled={!user || syncBusy}
          onCheckedChange={(enabled) => void changeCloudSync(enabled)}
          aria-label={t("settings.cloudSync")}
        />
      </SettingRow>
      {recoveryPhrase ? (
        <div className="py-4">
          <p className="text-sm font-medium">{t("settings.recoveryTitle")}</p>
          <p className="mt-1 text-sm text-muted-foreground">
            {t("settings.recoveryHint")}
          </p>
          <div className="mt-3 rounded-md border border-border bg-muted p-3 font-mono text-xs break-all select-all">
            {recoveryPhrase}
          </div>
          <Button
            type="button"
            variant="ghost"
            className="mt-2"
            onClick={() => void navigator.clipboard.writeText(recoveryPhrase)}
          >
            {t("settings.recoveryCopy")}
          </Button>
          <Button
            type="button"
            variant="ghost"
            className="mt-2"
            onClick={() => {
              setRecoveryPhrase(null);
              setPendingMaster(null);
              setRecoveryConfirmation("");
              setImportingRecovery(true);
            }}
          >
            {t("settings.recoveryUseExisting")}
          </Button>
          <Input
            className="mt-3"
            value={recoveryConfirmation}
            onChange={(event) => setRecoveryConfirmation(event.target.value)}
            placeholder={t("settings.recoveryPlaceholder")}
            autoComplete="off"
            spellCheck={false}
          />
          <Button
            type="button"
            className="mt-3"
            disabled={syncBusy || !recoveryConfirmation.trim()}
            onClick={() => void confirmRecovery()}
          >
            {t("settings.recoveryConfirm")}
          </Button>
        </div>
      ) : null}
      {importingRecovery ? (
        <div className="py-4">
          <p className="text-sm font-medium">
            {t("settings.recoveryUseExisting")}
          </p>
          <Input
            className="mt-3"
            value={recoveryConfirmation}
            onChange={(event) => setRecoveryConfirmation(event.target.value)}
            placeholder={t("settings.recoveryPlaceholder")}
            autoComplete="off"
            spellCheck={false}
          />
          <Button
            type="button"
            className="mt-3"
            disabled={syncBusy || !recoveryConfirmation.trim()}
            onClick={() => void importRecovery()}
          >
            {t("settings.recoveryImport")}
          </Button>
        </div>
      ) : null}
      {syncError ? (
        <p className="py-3 text-sm text-destructive">{syncError}</p>
      ) : null}
      <SettingRow
        label={t("settings.language")}
        hint={t("settings.languageHint")}
      >
        <div
          className="flex rounded-lg bg-muted p-0.5"
          role="radiogroup"
          aria-label={t("settings.language")}
        >
          {(["en", "es"] as Locale[]).map((id) => (
            <button
              key={id}
              type="button"
              role="radio"
              aria-checked={locale === id}
              onClick={() => setLocale(id)}
              className={cn(
                "h-7 rounded-md px-2 text-xs font-medium tracking-wide",
                locale === id
                  ? "bg-card text-foreground shadow-border"
                  : "text-muted-foreground hover:text-foreground",
              )}
            >
              {t(id === "en" ? "settings.lang.en" : "settings.lang.es")}
            </button>
          ))}
        </div>
      </SettingRow>
    </div>
  );
}

function ModeloSection({ onNavigate }: { onNavigate?: () => void }) {
  const t = useT();
  const model = useHermes((s) => s.model);
  const setModel = useHermes((s) => s.setModel);
  const gatewayOn = useHermes((s) => s.gatewayOn);
  const gatewayStatus = useHermes((s) => s.gatewayStatus);
  const gatewayMeta = useHermes((s) => s.gatewayMeta);
  const gatewayUrl = useHermes((s) => s.gatewayUrl);
  const gatewayPlace = useHermes((s) => s.gatewayPlace);
  const modelProvider = useHermes((s) => s.modelProvider);
  const setGatewayModels = useHermes((s) => s.setGatewayModels);
  const live = gatewayOn && gatewayStatus === "live";
  const hermesModels = live ? (gatewayMeta?.models ?? []) : [];
  const modelGroups = groupHermesModels(hermesModels);

  useEffect(() => {
    if (!live) return;
    const ctrl = new AbortController();
    void listHermesModels({ refresh: true, signal: ctrl.signal }).then(
      (result) => {
        if (ctrl.signal.aborted || !result.ok) return;
        setGatewayModels(result.models);
      },
    );
    return () => ctrl.abort();
  }, [live, setGatewayModels]);

  function pick(id: string, provider?: string) {
    setModel(id, provider);
    if (!live || !gatewayUrl) return;
    const convId = useHermes.getState().activeId;
    void setHermesModel({
      url: gatewayUrl,
      key:
        gatewayPlace === "mac"
          ? (getMacSessionKey() ?? undefined)
          : gatewayPlace === "device"
            ? (getDeviceSessionKey() ?? undefined)
            : undefined,
      place: gatewayPlace,
      model: id,
      provider,
      conversationId: convId,
    });
  }

  if (!live) {
    return (
      <p className="text-sm text-muted-foreground">
        {t("settings.modelsFromAgent")}{" "}
        <Link
          to="/connect"
          className="text-foreground underline-offset-2 hover:underline"
          onClick={onNavigate}
        >
          {t("settings.connectIt")}
        </Link>{" "}
        {t("settings.modelsFromAgentRest")}
      </p>
    );
  }

  if (modelGroups.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {t("settings.noProviders")}{" "}
        <Link
          to="/connect"
          className="text-foreground underline-offset-2 hover:underline"
          onClick={onNavigate}
        >
          {t("nav.connect")}
        </Link>{" "}
        {t("settings.noProvidersRest")}
      </p>
    );
  }

  return (
    <div className="space-y-5">
      {modelGroups.map((group) => (
        <div key={group.slug}>
          <p className="mb-2 text-2xs font-medium tracking-[0.12em] text-muted-foreground uppercase">
            {group.name}
          </p>
          <ul className="divide-y divide-border">
            {group.models.map((m) => {
              const on =
                model === m.id &&
                (!modelProvider || modelProvider === m.provider);
              return (
                <li key={`${m.provider}:${m.id}`}>
                  <button
                    type="button"
                    onClick={() => pick(m.id, m.provider)}
                    className="flex w-full items-center gap-3 py-3 text-left"
                  >
                    <span
                      className={cn(
                        "flex size-4 items-center justify-center rounded-full shadow-border",
                        on && "border-2 border-primary",
                      )}
                      aria-hidden
                    >
                      {on ? (
                        <span className="size-1.5 rounded-full bg-primary" />
                      ) : null}
                    </span>
                    <span className="flex-1">
                      <span className="block text-sm font-medium">
                        {m.label}
                      </span>
                      <span className="text-sm text-muted-foreground">
                        {prettyProvider(m.provider)}
                      </span>
                    </span>
                    {on ? (
                      <Badge variant="outline">{t("settings.current")}</Badge>
                    ) : null}
                  </button>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </div>
  );
}

function PerfilSection({ onNavigate }: { onNavigate?: () => void }) {
  void onNavigate;
  return <HermesProfilesSettings />;
}

function CuentaSection() {
  const t = useT();
  const user = useCurrentUser();
  const [signingOut, setSigningOut] = useState(false);
  const [phone, setPhone] = useState<string | null>(null);
  const label =
    user?.displayName || user?.primaryEmail || t("settings.thisSession");

  useEffect(() => {
    const ctrl = new AbortController();
    void fetch("/api/phone", { signal: ctrl.signal })
      .then((res) => res.json() as Promise<{ origin?: string | null }>)
      .then((data) => {
        if (typeof data.origin === "string" && data.origin)
          setPhone(data.origin);
      })
      .catch(() => {});
    return () => ctrl.abort();
  }, []);

  return (
    <div className="space-y-4">
      <div>
        <p className="font-medium">{label}</p>
        {user?.primaryEmail ? (
          <p className="mt-1 text-sm text-muted-foreground">
            {user.primaryEmail}
          </p>
        ) : null}
      </div>
      {authEnabled && user && !user.isDevFallback ? (
        <Button
          variant="ghost"
          disabled={signingOut}
          onClick={() => {
            setSigningOut(true);
            void signOut().catch(() => setSigningOut(false));
          }}
        >
          {signingOut ? t("settings.signingOut") : t("settings.signOut")}
        </Button>
      ) : (
        <p className="text-sm text-muted-foreground">
          {t("settings.macAccount")}
        </p>
      )}
      {phone ? (
        <div className="border-t border-border pt-4">
          <p className="text-sm font-medium">{t("settings.onPhone")}</p>
          <p className="mt-1 text-sm text-muted-foreground">
            {t("settings.onPhoneHint")}
          </p>
          <a
            href={phone}
            className="mt-1 block break-all text-sm text-foreground underline-offset-2 hover:underline"
          >
            {phone}
          </a>
          <p className="mt-1 text-sm text-muted-foreground">
            {t("settings.onPhoneRest")}
          </p>
        </div>
      ) : null}
    </div>
  );
}

function AtajosSection() {
  const t = useT();
  return (
    <ul className="divide-y divide-border text-sm">
      <Shortcut keys="⌘K" label={t("settings.shortcut.search")} />
      <Shortcut keys="⌘N" label={t("settings.shortcut.newChat")} />
      <Shortcut keys="⌘." label={t("settings.shortcut.focus")} />
      <Shortcut keys="Enter" label={t("settings.shortcut.send")} />
      <Shortcut keys="Shift+Enter" label={t("settings.shortcut.newline")} />
    </ul>
  );
}

function SettingRow({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="flex flex-col items-start gap-3 py-4 md:flex-row md:items-center md:justify-between md:gap-4">
      <div className="min-w-0">
        <p className="text-sm font-medium">{label}</p>
        {hint ? (
          <p className="mt-0.5 text-sm text-muted-foreground">{hint}</p>
        ) : null}
      </div>
      <div className="w-full md:w-auto md:shrink-0">{children}</div>
    </div>
  );
}

const FONT_SIZES: { id: FontSize; labelKey: MsgKey }[] = [
  { id: "sm", labelKey: "settings.font.sm" },
  { id: "md", labelKey: "settings.font.md" },
  { id: "lg", labelKey: "settings.font.lg" },
];

const ACCENTS: { id: Accent; labelKey: MsgKey; swatch: string }[] = [
  { id: "stone", labelKey: "settings.accent.stone", swatch: "#d4d0c8" },
  { id: "sage", labelKey: "settings.accent.sage", swatch: "#8fa894" },
  { id: "sky", labelKey: "settings.accent.sky", swatch: "#7fa3bf" },
  { id: "violet", labelKey: "settings.accent.violet", swatch: "#a392be" },
  { id: "rose", labelKey: "settings.accent.rose", swatch: "#c49293" },
  { id: "amber", labelKey: "settings.accent.amber", swatch: "#c4a574" },
];

function Shortcut({ keys, label }: { keys: string; label: string }) {
  return (
    <li className="flex items-center justify-between py-3">
      <span>{label}</span>
      <span className="flex gap-1">
        {keys.split("+").map((k) => (
          <Kbd key={k}>{k}</Kbd>
        ))}
      </span>
    </li>
  );
}
