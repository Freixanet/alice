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
  listHermesModels,
  prettyProvider,
  setHermesModel,
} from "@/lib/gateway";
import { getDeviceSessionKey } from "@/lib/hermes-direct";
import { authEnabled, signOut } from "@/lib/auth/client";
import { useCurrentUser } from "@/lib/auth/use-current-user";
import { useHermes, type Accent, type FontSize } from "@/lib/store";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useT } from "@/lib/use-i18n";
import type { MsgKey } from "@/lib/i18n";
import type { Locale } from "@/lib/i18n";

type SectionId = "general" | "model" | "profile" | "account" | "shortcuts";

const SECTION_META: {
  id: SectionId;
  labelKey: MsgKey;
  keywordsKey: MsgKey;
  icon: LucideIcon;
}[] = [
  { id: "general", labelKey: "settings.general", keywordsKey: "settings.keywords.general", icon: SlidersHorizontal },
  { id: "model", labelKey: "settings.model", keywordsKey: "settings.keywords.model", icon: Sparkles },
  { id: "profile", labelKey: "settings.profile", keywordsKey: "settings.keywords.profile", icon: CircleUser },
  { id: "account", labelKey: "settings.account", keywordsKey: "settings.keywords.account", icon: LogOut },
  { id: "shortcuts", labelKey: "settings.shortcuts", keywordsKey: "settings.keywords.shortcuts", icon: Keyboard },
];

export function SettingsDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const t = useT();
  const [sectionId, setSectionId] = useState<SectionId>("general");
  const [query, setQuery] = useState("");

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
    return sections.filter((s) => `${s.label} ${s.keywords}`.toLowerCase().includes(q));
  }, [query, sections]);

  const current = filtered.find((s) => s.id === sectionId) ?? filtered[0];

  useEffect(() => {
    if (current && current.id !== sectionId) setSectionId(current.id);
  }, [current, sectionId]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex h-[min(38rem,85vh)] max-w-3xl flex-row gap-0 overflow-hidden p-0 [&>button]:hidden">
        <DialogDescription className="sr-only">{t("settings.title")}</DialogDescription>
        <nav className="flex w-52 shrink-0 flex-col border-r border-border p-3">
          <DialogClose asChild>
            <button
              type="button"
              aria-label={t("settings.close")}
              className="mb-3 grid size-8 place-items-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground"
            >
              <X className="size-4" />
            </button>
          </DialogClose>
          <div className="relative mb-3">
            <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={t("settings.search")}
              aria-label={t("settings.search")}
              className="h-9 rounded-lg pl-8 text-sm"
            />
          </div>
          <ul className="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto">
            {filtered.length === 0 ? (
              <li className="px-2.5 py-2 text-sm text-muted-foreground">{t("settings.noMatch")}</li>
            ) : (
              filtered.map((s) => {
                const on = s.id === current?.id;
                return (
                  <li key={s.id}>
                    <button
                      type="button"
                      onClick={() => setSectionId(s.id)}
                      className={cn(
                        "flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-sm",
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
        <div className="flex min-w-0 flex-1 flex-col">
          <div className="min-h-0 flex-1 overflow-y-auto px-8 py-6">
            {current ? (
              <>
                <DialogTitle className="mb-5 text-xl font-medium tracking-tight">
                  {current.label}
                </DialogTitle>
                {current.id === "general" ? <GeneralSection /> : null}
                {current.id === "model" ? (
                  <ModeloSection onNavigate={() => onOpenChange(false)} />
                ) : null}
                {current.id === "profile" ? <PerfilSection onNavigate={() => onOpenChange(false)} /> : null}
                {current.id === "account" ? <CuentaSection /> : null}
                {current.id === "shortcuts" ? <AtajosSection /> : null}
              </>
            ) : (
              <>
                <DialogTitle className="sr-only">{t("settings.title")}</DialogTitle>
                <p className="text-sm text-muted-foreground">{t("settings.noMatch")}</p>
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

  return (
    <div className="divide-y divide-border">
      <SettingRow label={t("settings.lightTheme")} hint={t("settings.lightThemeHint")}>
        <Switch
          checked={theme === "light"}
          onCheckedChange={(v) => setTheme(v ? "light" : "dark")}
          aria-label={t("settings.lightTheme")}
        />
      </SettingRow>
      <SettingRow label={t("settings.fontSize")} hint={t("settings.fontSizeHint")}>
        <div className="flex rounded-lg bg-muted p-0.5" role="radiogroup" aria-label={t("settings.fontSize")}>
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
        <div className="flex flex-wrap justify-end gap-2" role="radiogroup" aria-label={t("settings.color")}>
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
      <SettingRow label={t("settings.compact")} hint={t("settings.compactHint")}>
        <Switch checked={compact} onCheckedChange={setCompact} aria-label={t("settings.compact")} />
      </SettingRow>
      <SettingRow label={t("settings.focus")} hint={t("settings.focusHint")}>
        <Switch checked={focusMode} onCheckedChange={setFocusMode} aria-label={t("settings.focus")} />
      </SettingRow>
      <SettingRow label={t("settings.language")} hint={t("settings.languageHint")}>
        <div className="flex rounded-lg bg-muted p-0.5" role="radiogroup" aria-label={t("settings.language")}>
          {(["en", "es"] as Locale[]).map((id) => (
            <button
              key={id}
              type="button"
              role="radio"
              aria-checked={locale === id}
              onClick={() => setLocale(id)}
              className={cn(
                "h-7 rounded-md px-2 text-[11px] font-medium tracking-wide",
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
    void listHermesModels({ refresh: true, signal: ctrl.signal }).then((result) => {
      if (ctrl.signal.aborted || !result.ok) return;
      setGatewayModels(result.models);
    });
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
          ? getMacSessionKey() ?? undefined
          : gatewayPlace === "device"
            ? getDeviceSessionKey() ?? undefined
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
              const on = model === m.id && (!modelProvider || modelProvider === m.provider);
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
                      {on ? <span className="size-1.5 rounded-full bg-primary" /> : null}
                    </span>
                    <span className="flex-1">
                      <span className="block text-sm font-medium">{m.label}</span>
                      <span className="text-sm text-muted-foreground">
                        {prettyProvider(m.provider)}
                      </span>
                    </span>
                    {on ? <Badge variant="outline">{t("settings.current")}</Badge> : null}
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
  const t = useT();
  const profile = useHermes((s) => s.profile);
  return (
    <div>
      <p className="font-medium">{profile}</p>
      <p className="mt-1 text-sm text-muted-foreground">
        {t("settings.profileHint")}{" "}
        <Link
          to="/memory"
          className="text-foreground underline-offset-2 hover:underline"
          onClick={onNavigate}
        >
          {t("nav.memory")}
        </Link>
        .
      </p>
    </div>
  );
}

function CuentaSection() {
  const t = useT();
  const user = useCurrentUser();
  const [signingOut, setSigningOut] = useState(false);
  const [phone, setPhone] = useState<string | null>(null);
  const label = user?.displayName || user?.primaryEmail || t("settings.thisSession");

  useEffect(() => {
    const ctrl = new AbortController();
    void fetch("/api/phone", { signal: ctrl.signal })
      .then((res) => res.json() as Promise<{ origin?: string | null }>)
      .then((data) => {
        if (typeof data.origin === "string" && data.origin) setPhone(data.origin);
      })
      .catch(() => {});
    return () => ctrl.abort();
  }, []);

  return (
    <div className="space-y-4">
      <div>
        <p className="font-medium">{label}</p>
        {user?.primaryEmail ? (
          <p className="mt-1 text-sm text-muted-foreground">{user.primaryEmail}</p>
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
        <p className="text-sm text-muted-foreground">{t("settings.macAccount")}</p>
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
    <div className="flex items-center justify-between gap-4 py-4">
      <div className="min-w-0">
        <p className="text-sm font-medium">{label}</p>
        {hint ? <p className="mt-0.5 text-sm text-muted-foreground">{hint}</p> : null}
      </div>
      <div className="shrink-0">{children}</div>
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
