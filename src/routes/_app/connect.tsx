import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  assertGatewayKey,
  friendlyProbeError,
  getMacSessionKey,
  inferGatewayPlace,
  normalizeGatewayUrl,
  probeGateway,
  saveHermesCustomEndpoint,
  setMacSessionKey,
} from "@/lib/gateway";
import { authHeaders } from "@/lib/auth/client";
import { getDeviceSessionKey } from "@/lib/hermes-direct";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useHermes } from "@/lib/store";

export const Route = createFileRoute("/_app/connect")({
  component: ConnectPage,
});

function ConnectPage() {
  const place = useHermes((s) => s.gatewayPlace);
  const setPlace = useHermes((s) => s.setGatewayPlace);
  const url = useHermes((s) => s.gatewayUrl);
  const setUrl = useHermes((s) => s.setGatewayUrl);
  const status = useHermes((s) => s.gatewayStatus);
  const meta = useHermes((s) => s.gatewayMeta);
  const error = useHermes((s) => s.gatewayError);
  const on = useHermes((s) => s.gatewayOn);
  const setChecking = useHermes((s) => s.setGatewayChecking);
  const setLive = useHermes((s) => s.setGatewayLive);
  const setDown = useHermes((s) => s.setGatewayDown);
  const forget = useHermes((s) => s.forgetGateway);
  const setModel = useHermes((s) => s.setModel);
  const setGatewayModels = useHermes((s) => s.setGatewayModels);
  const [key, setKey] = useState("");
  const [busy, setBusy] = useState(false);
  const [endpointName, setEndpointName] = useState("");
  const [endpointUrl, setEndpointUrl] = useState("");
  const [endpointKey, setEndpointKey] = useState("");
  const [endpointModel, setEndpointModel] = useState("");
  const [endpointBusy, setEndpointBusy] = useState(false);
  const [endpointError, setEndpointError] = useState<string | null>(null);
  const [endpointOk, setEndpointOk] = useState(false);
  const liveState = useHermesLive();
  const [gate, setGate] = useState<{ owner: boolean; local: boolean } | null>(null);

  useEffect(() => {
    const ctrl = new AbortController();
    void fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "status" }),
      signal: ctrl.signal,
    })
      .then((res) => res.json() as Promise<{ owner?: boolean; local?: boolean }>)
      .then((data) => {
        if (ctrl.signal.aborted) return;
        setGate({ owner: Boolean(data.owner), local: Boolean(data.local) });
      })
      .catch(() => {});
    return () => ctrl.abort();
  }, []);

  const live = on && status === "live";

  async function connect() {
    setBusy(true);
    setChecking();
    try {
      const normalized = normalizeGatewayUrl(url);
      setUrl(normalized);
      const nextPlace = inferGatewayPlace(normalized, {
        owner: Boolean(gate?.owner),
        local: Boolean(gate?.local),
      });
      setPlace(nextPlace);
      const stored =
        nextPlace === "mac"
          ? getMacSessionKey()
          : nextPlace === "device"
            ? getDeviceSessionKey()
            : null;
      const token = assertGatewayKey(key || stored || "");
      if (nextPlace === "mac") setMacSessionKey(token);
      const result = await probeGateway({
        url: normalized,
        key: token,
        place: nextPlace,
        save: true,
      });
      if (result.ok) {
        setKey("");
        setLive({
          model: result.model,
          provider: result.provider,
          models: result.models,
          platform: result.platform,
          skills: result.skills,
          probedAt: Date.now(),
          mode: result.mode,
          place: nextPlace,
        });
      } else {
        setDown(result.error);
      }
    } catch (e) {
      setDown(friendlyProbeError((e as { code?: "invalid" }).code));
    } finally {
      setBusy(false);
    }
  }

  async function addEndpoint() {
    if (!live) return;
    setEndpointBusy(true);
    setEndpointError(null);
    setEndpointOk(false);
    try {
      const result = await saveHermesCustomEndpoint({
        name: endpointName,
        baseUrl: endpointUrl,
        apiKey: endpointKey,
        model: endpointModel,
      });
      if (!result.ok) {
        setEndpointError(result.error || "No se ha podido guardar.");
        return;
      }
      setEndpointKey("");
      setEndpointOk(true);
      if (result.models?.length) setGatewayModels(result.models);
      if (result.model) setModel(result.model, result.provider);
    } catch {
      setEndpointError("No se ha podido guardar.");
    } finally {
      setEndpointBusy(false);
    }
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-8 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker="Gateway"
          title="Conectar"
          description="Pega la dirección de tu Hermes y la clave. Local o en internet: Alice lo deduce."
        />

        <section className="space-y-3">
          <div className="flex flex-col gap-4 rounded-xl bg-card p-4 shadow-border">
            <label className="flex flex-col gap-1.5 text-sm">
              Dirección
              <Input
                value={url}
                onChange={(e) => setUrl(e.target.value)}
                placeholder="https://tu-hermes o http://127.0.0.1:8642"
                autoComplete="off"
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              Clave
              <Input
                type="password"
                value={key}
                onChange={(e) => setKey(e.target.value)}
                placeholder={live ? "Ya conectado — pega otra para cambiar" : "La clave de tu Hermes"}
                autoComplete="off"
              />
            </label>
            {error ? <p className="text-sm text-destructive">{error}</p> : null}
            <div className="flex flex-wrap items-center gap-2">
              <Button onClick={() => void connect()} disabled={busy || !url.trim() || (!key.trim() && !live)}>
                {busy ? "Comprobando…" : live ? "Volver a conectar" : "Conectar"}
              </Button>
              {live ? (
                <Button variant="ghost" onClick={forget}>
                  Olvidar
                </Button>
              ) : null}
            </div>
          </div>
        </section>

        {live && meta ? (
          <section className="space-y-3">
            <h2 className="text-sm font-medium">Estado</h2>
            <div className="rounded-xl bg-card px-4 py-4 shadow-border">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant="live">En línea</Badge>
                <span className="text-sm">{meta.model}</span>
              </div>
              <p className="mt-2 text-sm text-muted-foreground">
                {meta.platform ?? "Hermes"} · {meta.place === "cloud" ? "remoto" : "local"}
              </p>
            </div>
          </section>
        ) : null}

        <HermesLiveSections
          loading={liveState.loading}
          error={liveState.error}
          data={liveState.data}
        />

        {place !== "device" ? (
        <section className="space-y-3">
          <h2 className="text-sm font-medium">Proveedor de inferencia</h2>
          <div className="flex flex-col gap-4 rounded-xl bg-card p-4 shadow-border">
            <p className="text-sm text-muted-foreground">
              Cualquier API compatible con OpenAI. Lo guarda Hermes y sale en el selector.
            </p>
            <label className="flex flex-col gap-1.5 text-sm">
              Nombre
              <Input
                value={endpointName}
                onChange={(e) => {
                  setEndpointName(e.target.value);
                  setEndpointOk(false);
                }}
                placeholder="El nombre que quieras"
                autoComplete="off"
                disabled={!live}
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              Dirección
              <Input
                value={endpointUrl}
                onChange={(e) => {
                  setEndpointUrl(e.target.value);
                  setEndpointOk(false);
                }}
                placeholder="https://api.ejemplo.com/v1"
                autoComplete="off"
                disabled={!live}
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              Clave
              <Input
                type="password"
                value={endpointKey}
                onChange={(e) => setEndpointKey(e.target.value)}
                placeholder="Si el endpoint la pide"
                autoComplete="off"
                disabled={!live}
              />
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              Modelo
              <Input
                value={endpointModel}
                onChange={(e) => setEndpointModel(e.target.value)}
                placeholder="Opcional. Si está vacío, Hermes lista los del endpoint."
                autoComplete="off"
                disabled={!live}
              />
            </label>
            {!live ? (
              <p className="text-sm text-muted-foreground">Conecta tu Hermes arriba para añadirlo.</p>
            ) : null}
            {endpointError ? <p className="text-sm text-destructive">{endpointError}</p> : null}
            {endpointOk ? (
              <p className="text-sm text-muted-foreground">Guardado. Ya está en el selector del chat.</p>
            ) : null}
            <div>
              <Button
                onClick={() => void addEndpoint()}
                disabled={!live || endpointBusy || !endpointUrl.trim()}
              >
                {endpointBusy ? "Guardando…" : "Añadir a Hermes"}
              </Button>
            </div>
          </div>
        </section>
        ) : null}
      </div>
    </div>
  );
}

function HermesLiveSections({
  loading,
  error,
  data,
}: {
  loading: boolean;
  error: string | null;
  data: ReturnType<typeof useHermesLive>["data"];
}) {
  if (loading) {
    return <p className="text-sm text-muted-foreground">Leyendo canales y sesiones de Hermes…</p>;
  }
  if (error) {
    return <p className="text-sm text-muted-foreground">{error}</p>;
  }
  if (!data) return null;

  const channels = data.channels;
  const pending = data.pairing;
  const approved = data.pairingApproved;
  const sessions = data.sessions;
  const webhooks = data.webhooks;

  return (
    <>
      <section className="space-y-3">
        <h2 className="text-sm font-medium">Canales</h2>
        {channels.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-8 text-center text-sm text-muted-foreground shadow-border">
            Hermes no tiene canales de mensajería configurados.
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {channels.map((channel) => (
              <li key={channel.id} className="rounded-xl bg-card px-4 py-4 shadow-border">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-medium">{channel.name}</h3>
                  <Badge variant={channel.enabled ? "live" : "outline"}>
                    {channelLabel(channel.state)}
                  </Badge>
                </div>
                {channel.description ? (
                  <p className="mt-1 text-sm text-muted-foreground">{channel.description}</p>
                ) : null}
                {channel.error ? (
                  <p className="mt-1 text-sm text-destructive">{channel.error}</p>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </section>

      {pending.length > 0 || approved.length > 0 ? (
        <section className="space-y-3">
          <h2 className="text-sm font-medium">Emparejamiento</h2>
          <ul className="flex flex-col gap-2">
            {pending.map((row) => (
              <li
                key={`p-${row.platform}-${row.user ?? row.code ?? ""}`}
                className="rounded-xl bg-card px-4 py-4 shadow-border"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-medium">{row.user || row.platform}</h3>
                  <Badge variant="warn">Pendiente</Badge>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">
                  {prettyPlatform(row.platform)}
                  {row.code ? ` · ${row.code}` : ""}
                </p>
              </li>
            ))}
            {approved.map((row) => (
              <li
                key={`a-${row.platform}-${row.user ?? row.code ?? ""}`}
                className="rounded-xl bg-card px-4 py-4 shadow-border"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-medium">{row.user || row.platform}</h3>
                  <Badge variant="live">Aprobado</Badge>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">{prettyPlatform(row.platform)}</p>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="space-y-3">
        <h2 className="text-sm font-medium">Sesiones de Hermes</h2>
        <p className="text-sm text-muted-foreground">
          Las conversaciones que guarda tu agente. No son los chats de este cockpit.
        </p>
        {sessions.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-8 text-center text-sm text-muted-foreground shadow-border">
            No hay sesiones recientes, o el dashboard no las ha enviado.
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {sessions.map((session) => (
              <li key={session.id} className="rounded-xl bg-card px-4 py-4 shadow-border">
                <h3 className="font-medium">{session.title || session.id}</h3>
                <p className="mt-1 text-2xs text-muted-foreground">
                  {session.source ? prettyPlatform(session.source) : "Hermes"}
                  {typeof session.messages === "number" ? ` · ${session.messages} mensajes` : ""}
                  {session.updatedAt ? ` · ${formatStamp(session.updatedAt)}` : ""}
                </p>
              </li>
            ))}
          </ul>
        )}
      </section>

      {webhooks.length > 0 ? (
        <section className="space-y-3">
          <h2 className="text-sm font-medium">Webhooks</h2>
          <ul className="flex flex-col gap-2">
            {webhooks.map((hook) => (
              <li key={hook.name} className="rounded-xl bg-card px-4 py-4 shadow-border">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-medium">{hook.name}</h3>
                  <Badge variant={hook.enabled ? "live" : "outline"}>
                    {hook.enabled ? "Activo" : "Apagado"}
                  </Badge>
                </div>
                {hook.event ? (
                  <p className="mt-1 text-sm text-muted-foreground">{hook.event}</p>
                ) : null}
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </>
  );
}

function channelLabel(state: string) {
  const map: Record<string, string> = {
    connected: "Conectado",
    disabled: "Apagado",
    not_configured: "Sin configurar",
    pending_restart: "Reinicio pendiente",
    gateway_stopped: "Gateway parado",
    startup_failed: "Fallo al arrancar",
    disconnected: "Desconectado",
    fatal: "Error",
    "en config": "En config",
    "en tareas": "En tareas",
    activo: "Activo",
    apagado: "Apagado",
  };
  return map[state] ?? state;
}

function prettyPlatform(id: string) {
  const map: Record<string, string> = {
    whatsapp: "WhatsApp",
    telegram: "Telegram",
    discord: "Discord",
    slack: "Slack",
    signal: "Signal",
    cli: "CLI",
  };
  return map[id] ?? id;
}

function formatStamp(value: string) {
  const n = Number(value);
  const d = new Date(!Number.isNaN(n) && n > 1_000_000_000 ? (n < 1e12 ? n * 1000 : n) : value);
  if (Number.isNaN(d.getTime())) return value;
  return new Intl.DateTimeFormat("es", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(d);
}
