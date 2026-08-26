import { createFileRoute } from "@tanstack/react-router";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Kbd } from "@/components/ui/kbd";
import { Switch } from "@/components/ui/switch";
import { MODELS } from "@/lib/catalog";
import { getMacSessionKey, prettyProvider, setHermesModel } from "@/lib/gateway";
import { useHermes, type Accent, type FontSize } from "@/lib/store";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_app/settings")({
  component: SettingsPage,
});

function SettingsPage() {
  const model = useHermes((s) => s.model);
  const setModel = useHermes((s) => s.setModel);
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
  const profile = useHermes((s) => s.profile);
  const gatewayOn = useHermes((s) => s.gatewayOn);
  const gatewayStatus = useHermes((s) => s.gatewayStatus);
  const gatewayMeta = useHermes((s) => s.gatewayMeta);
  const gatewayUrl = useHermes((s) => s.gatewayUrl);
  const gatewayPlace = useHermes((s) => s.gatewayPlace);
  const live = gatewayOn && gatewayStatus === "live";
  const hermesModels = gatewayMeta?.models ?? [];
  const modelChoices = live && hermesModels.length
    ? hermesModels
    : MODELS.map((m) => ({ id: m.id, label: m.label, provider: m.provider }));

  function pick(id: string, provider?: string) {
    setModel(id, provider);
    if (!live || !gatewayUrl) return;
    const convId = useHermes.getState().activeId;
    void setHermesModel({
      url: gatewayUrl,
      key: gatewayPlace === "mac" ? getMacSessionKey() ?? undefined : undefined,
      place: gatewayPlace,
      model: id,
      provider,
      conversationId: convId,
    });
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-10 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker="Control"
          title="Ajustes"
          description="Una sola página. Sin submenús. Cambia solo lo que importa."
        />

        <section className="space-y-3">
          <h2 className="text-sm font-medium">Modelo</h2>
          <ul className="divide-y divide-border rounded-xl bg-card shadow-border">
            {modelChoices.map((m) => {
              const on = model === m.id;
              return (
                <li key={`${m.provider}:${m.id}`}>
                  <button
                    type="button"
                    onClick={() => pick(m.id, m.provider)}
                    className="flex w-full items-center gap-3 px-4 py-3 text-left"
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
                      <span className="block font-medium">{m.label}</span>
                      <span className="text-sm text-muted-foreground">
                        {prettyProvider(m.provider)}
                      </span>
                    </span>
                    {!live && m.id === "grok-4.5" ? (
                      <Badge variant="outline">Recomendado</Badge>
                    ) : null}
                  </button>
                </li>
              );
            })}
          </ul>
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-medium">Apariencia</h2>
          <ul className="divide-y divide-border rounded-xl bg-card shadow-border">
            <li className="flex items-center justify-between gap-3 px-4 py-3">
              <div>
                <p className="font-medium">Tema claro</p>
                <p className="text-sm text-muted-foreground">
                  Papel cálido. El oscuro sigue siendo el de trabajo.
                </p>
              </div>
              <Switch
                checked={theme === "light"}
                onCheckedChange={(v) => setTheme(v ? "light" : "dark")}
                aria-label="Tema claro"
              />
            </li>
            <li className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p className="font-medium">Tamaño del texto</p>
                <p className="text-sm text-muted-foreground">
                  Para leer con calma, sin apretar.
                </p>
              </div>
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
            </li>
            <li className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p className="font-medium">Color</p>
                <p className="text-sm text-muted-foreground">
                  El acento de botones y selección.
                </p>
              </div>
              <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Color">
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
                        ? "ring-2 ring-foreground ring-offset-2 ring-offset-card"
                        : "hover:scale-105",
                    )}
                    style={{ background: opt.swatch }}
                  />
                ))}
              </div>
            </li>
            <li className="flex items-center justify-between gap-3 px-4 py-3">
              <div>
                <p className="font-medium">Compacto</p>
                <p className="text-sm text-muted-foreground">
                  Menos aire. Más lista, menos página.
                </p>
              </div>
              <Switch
                checked={compact}
                onCheckedChange={setCompact}
                aria-label="Compacto"
              />
            </li>
            <li className="flex items-center justify-between gap-3 px-4 py-3">
              <div>
                <p className="font-medium">Modo foco</p>
                <p className="text-sm text-muted-foreground">
                  Oculta la barra. Solo el hilo. También con <Kbd>⌘.</Kbd>
                </p>
              </div>
              <Switch
                checked={focusMode}
                onCheckedChange={setFocusMode}
                aria-label="Modo foco"
              />
            </li>
          </ul>
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-medium">Perfil</h2>
          <div className="rounded-xl bg-card px-4 py-4 shadow-border">
            <p className="font-medium">{profile}</p>
            <p className="mt-1 text-sm text-muted-foreground">
              Configuración, memoria y skills aisladas. Un perfil, sin ruido de
              otros contextos.
            </p>
          </div>
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-medium">Atajos</h2>
          <ul className="divide-y divide-border rounded-xl bg-card shadow-border text-sm">
            <Shortcut keys="⌘K" label="Buscar en todo Hermes" />
            <Shortcut keys="⌘N" label="Nuevo chat" />
            <Shortcut keys="⌘." label="Modo foco" />
            <Shortcut keys="Enter" label="Enviar mensaje" />
            <Shortcut keys="Shift+Enter" label="Nueva línea" />
          </ul>
        </section>
      </div>
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
    <li className="flex items-center justify-between px-4 py-3">
      <span>{label}</span>
      <span className="flex gap-1">
        {keys.split("+").map((k) => (
          <Kbd key={k}>{k}</Kbd>
        ))}
      </span>
    </li>
  );
}
