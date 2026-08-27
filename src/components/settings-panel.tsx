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
import { useHermes } from "@/lib/store";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

type SectionId = "general" | "modelo" | "perfil" | "cuenta" | "atajos";

const SECTIONS: {
  id: SectionId;
  label: string;
  icon: LucideIcon;
  keywords: string;
}[] = [
  {
    id: "general",
    label: "General",
    icon: SlidersHorizontal,
    keywords: "apariencia tema claro oscuro texto tamaño color acento compacto foco",
  },
  {
    id: "modelo",
    label: "Modelo",
    icon: Sparkles,
    keywords: "modelo hermes proveedor inferencia",
  },
  {
    id: "perfil",
    label: "Perfil",
    icon: CircleUser,
    keywords: "perfil contexto",
  },
  {
    id: "cuenta",
    label: "Cuenta",
    icon: LogOut,
    keywords: "cuenta correo sesión salir login móvil teléfono tailscale",
  },
  {
    id: "atajos",
    label: "Atajos",
    icon: Keyboard,
    keywords: "atajo teclado comando buscar enviar",
  },
];

export function SettingsDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [sectionId, setSectionId] = useState<SectionId>("general");
  const [query, setQuery] = useState("");

  useEffect(() => {
    if (!open) return;
    setSectionId("general");
    setQuery("");
  }, [open]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return SECTIONS;
    return SECTIONS.filter((s) => `${s.label} ${s.keywords}`.toLowerCase().includes(q));
  }, [query]);

  const current = filtered.find((s) => s.id === sectionId) ?? filtered[0];

  useEffect(() => {
    if (current && current.id !== sectionId) setSectionId(current.id);
  }, [current, sectionId]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex h-[min(38rem,85vh)] max-w-3xl flex-row gap-0 overflow-hidden p-0 [&>button]:hidden">
        <DialogDescription className="sr-only">Ajustes de Alice</DialogDescription>
        <nav className="flex w-52 shrink-0 flex-col border-r border-border p-3">
          <DialogClose asChild>
            <button
              type="button"
              aria-label="Cerrar"
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
              placeholder="Buscar ajustes"
              aria-label="Buscar ajustes"
              className="h-9 rounded-lg pl-8 text-sm"
            />
          </div>
          <ul className="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto">
            {filtered.length === 0 ? (
              <li className="px-2.5 py-2 text-sm text-muted-foreground">Nada coincide.</li>
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
                {current.id === "modelo" ? (
                  <ModeloSection onNavigate={() => onOpenChange(false)} />
                ) : null}
                {current.id === "perfil" ? <PerfilSection onNavigate={() => onOpenChange(false)} /> : null}
                {current.id === "cuenta" ? <CuentaSection /> : null}
                {current.id === "atajos" ? <AtajosSection /> : null}
              </>
            ) : (
              <>
                <DialogTitle className="sr-only">Ajustes</DialogTitle>
                <p className="text-sm text-muted-foreground">Nada coincide.</p>
              </>
            )}
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

function GeneralSection() {
  const theme = useHermes((s) => s.theme);
  const setTheme = useHermes((s) => s.setTheme);
  const fontSize = useHermes((s) => s.fontSize);
  const setFontSize = useHermes((s) => s.setFontSize);
  const accent = useHermes((s) => s.accent);
  const setAccent = useHermes((s) => s.setAccent);
  const compact = useHermes((s) => s.compact);
  const setCompact = useHermes((s) => s.setCompact);
  const focusMode = useHermes((s) => s.focusMode);
  const setFocusMode = useHermes((s) => s.setFocusMode);

  return (
    <div className="divide-y divide-border">
      <SettingRow label="Tema claro" hint="Papel cálido. El oscuro sigue siendo el de trabajo.">
        <Switch
          checked={theme === "light"}
          onCheckedChange={(v) => setTheme(v ? "light" : "dark")}
          aria-label="Tema claro"
        />
      </SettingRow>
      <SettingRow label="Tamaño del texto" hint="Para leer con calma, sin apretar.">
        <div className="flex rounded-lg bg-muted p-0.5" role="radiogroup" aria-label="Tamaño del texto">
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
              {opt.label}
            </button>
          ))}
        </div>
      </SettingRow>
      <SettingRow label="Color" hint="El acento de botones y selección.">
        <div className="flex flex-wrap justify-end gap-2" role="radiogroup" aria-label="Color">
          {ACCENTS.map((opt) => (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={accent === opt.id}
              aria-label={opt.label}
              title={opt.label}
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
      <SettingRow label="Compacto" hint="Menos aire. Más lista, menos página.">
        <Switch checked={compact} onCheckedChange={setCompact} aria-label="Compacto" />
      </SettingRow>
      <SettingRow
        label="Modo foco"
        hint={
          <>
            Oculta la barra. Solo el hilo. También con <Kbd>⌘.</Kbd>
          </>
        }
      >
        <Switch checked={focusMode} onCheckedChange={setFocusMode} aria-label="Modo foco" />
      </SettingRow>
    </div>
  );
}

function ModeloSection({ onNavigate }: { onNavigate?: () => void }) {
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
        Los modelos salen de tu agente.{" "}
        <Link
          to="/connect"
          className="text-foreground underline-offset-2 hover:underline"
          onClick={onNavigate}
        >
          Conéctalo
        </Link>{" "}
        para ver los que tiene ahora.
      </p>
    );
  }

  if (modelGroups.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        Hermes no tiene proveedores autenticados ahora. En{" "}
        <Link
          to="/connect"
          className="text-foreground underline-offset-2 hover:underline"
          onClick={onNavigate}
        >
          Conectar
        </Link>{" "}
        puedes añadir cualquier API de inferencia compatible con OpenAI.
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
                    {on ? <Badge variant="outline">Actual</Badge> : null}
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
  const profile = useHermes((s) => s.profile);
  return (
    <div>
      <p className="font-medium">{profile}</p>
      <p className="mt-1 text-sm text-muted-foreground">
        Este es el perfil de Hermes. Soul, perfil de usuario y notas están en{" "}
        <Link
          to="/memory"
          className="text-foreground underline-offset-2 hover:underline"
          onClick={onNavigate}
        >
          Memoria
        </Link>
        .
      </p>
    </div>
  );
}

function CuentaSection() {
  const user = useCurrentUser();
  const [signingOut, setSigningOut] = useState(false);
  const [phone, setPhone] = useState<string | null>(null);
  const label = user?.displayName || user?.primaryEmail || "Esta sesión";

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
          {signingOut ? "Saliendo…" : "Cerrar sesión"}
        </Button>
      ) : (
        <p className="text-sm text-muted-foreground">Esta es la cuenta de este Mac.</p>
      )}
      {phone ? (
        <div className="border-t border-border pt-4">
          <p className="text-sm font-medium">En el móvil</p>
          <p className="mt-1 text-sm text-muted-foreground">
            En Safari, esta dirección:
          </p>
          <a
            href={phone}
            className="mt-1 block break-all text-sm text-foreground underline-offset-2 hover:underline"
          >
            {phone}
          </a>
          <p className="mt-1 text-sm text-muted-foreground">
            Compartir → Añadir a pantalla de inicio. Este Mac tiene que estar despierto.
            Otras personas pueden crear su cuenta en esta misma dirección y conectar su
            Hermes.
          </p>
        </div>
      ) : null}
    </div>
  );
}

function AtajosSection() {
  return (
    <ul className="divide-y divide-border text-sm">
      <Shortcut keys="⌘K" label="Buscar en todo Hermes" />
      <Shortcut keys="⌘N" label="Nuevo chat" />
      <Shortcut keys="⌘." label="Modo foco" />
      <Shortcut keys="Enter" label="Enviar mensaje" />
      <Shortcut keys="Shift+Enter" label="Nueva línea" />
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

const FONT_SIZES: { id: FontSize; label: string }[] = [
  { id: "sm", label: "Pequeño" },
  { id: "md", label: "Normal" },
  { id: "lg", label: "Grande" },
];

const ACCENTS: { id: Accent; label: string; swatch: string }[] = [
  { id: "stone", label: "Piedra", swatch: "#d4d0c8" },
  { id: "sage", label: "Salvia", swatch: "#8fa894" },
  { id: "sky", label: "Cielo", swatch: "#7fa3bf" },
  { id: "violet", label: "Violeta", swatch: "#a392be" },
  { id: "rose", label: "Rosa", swatch: "#c49293" },
  { id: "amber", label: "Ámbar", swatch: "#c4a574" },
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
