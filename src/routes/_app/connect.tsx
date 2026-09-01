import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { PageHeader } from "@/components/catalog-page";
import { HermesDiagnosticsPanel } from "@/components/hermes-diagnostics";
import { HermesChannelsPanel } from "@/components/hermes-channels";
import { HermesSessionInspector } from "@/components/hermes-session-inspector";
import { HermesWebhooksPanel } from "@/components/hermes-webhooks";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  assertGatewayKey,
  friendlyProbeError,
  getMacSessionKey,
  inferGatewayPlace,
  normalizeGatewayUrl,
  saveHermesCustomEndpoint,
  setMacSessionKey,
  type ProbeCode,
} from "@/lib/gateway";
import { probeGateway } from "@/lib/hermes-client";
import {
  listHermesLive,
  mutateHermes,
  readHermesSessionMessages,
} from "@/lib/hermes-live";
import type { HermesMutation } from "@/lib/hermes-operations";
import {
  readHermesGateStatus,
  type HermesGateStatus,
} from "@/lib/hermes-connection";
import { advertisesHermesCapability } from "@/lib/gateway-contracts";
import { getDeviceSessionKey } from "@/lib/hermes-direct";
import { dateLocale, localizeError, type Locale } from "@/lib/i18n";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";
import { useHermes } from "@/lib/store";

export const Route = createFileRoute("/_app/connect")({
  component: ConnectPage,
});

function ConnectPage() {
  const t = useT();
  const locale = useLocale();
  const place = useHermes((s) => s.gatewayPlace);
  const setPlace = useHermes((s) => s.setGatewayPlace);
  const url = useHermes((s) => s.gatewayUrl);
  const setUrl = useHermes((s) => s.setGatewayUrl);
  const status = useHermes((s) => s.gatewayStatus);
  const meta = useHermes((s) => s.gatewayMeta);
  const profile = useHermes((s) => s.profile);
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
  const [editingConnection, setEditingConnection] = useState(false);
  const [endpointName, setEndpointName] = useState("");
  const [endpointUrl, setEndpointUrl] = useState("");
  const [endpointKey, setEndpointKey] = useState("");
  const [endpointModel, setEndpointModel] = useState("");
  const [endpointBusy, setEndpointBusy] = useState(false);
  const [endpointError, setEndpointError] = useState<string | null>(null);
  const [endpointOk, setEndpointOk] = useState(false);
  const liveState = useHermesLive();
  const [gate, setGate] = useState<HermesGateStatus | null>(null);
  const [connectionIssue, setConnectionIssue] = useState<ProbeCode | null>(
    null,
  );
  const [appOrigin, setAppOrigin] = useState(
    "https://alice-ten-phi.vercel.app",
  );
  const [commandCopied, setCommandCopied] = useState(false);

  useEffect(() => {
    setAppOrigin(window.location.origin);
    const ctrl = new AbortController();
    void readHermesGateStatus(ctrl.signal)
      .then((data) => {
        if (ctrl.signal.aborted) return;
        setGate(data);
        const state = useHermes.getState();
        if (
          data.hasKey &&
          data.url &&
          (data.place === "cloud" ||
            data.place === "mac" ||
            data.place === "device") &&
          (!state.gatewayOn ||
            !state.gatewayUrl ||
            state.gatewayUrl !== data.url ||
            state.gatewayPlace !== data.place)
        ) {
          state.restoreGateway({ url: data.url, place: data.place });
        }
      })
      .catch(() => {});
    return () => ctrl.abort();
  }, []);

  const live = on && status === "live";

  async function connect() {
    setBusy(true);
    setConnectionIssue(null);
    setCommandCopied(false);
    setChecking();
    try {
      let currentGate = gate;
      try {
        currentGate = await readHermesGateStatus();
        setGate(currentGate);
      } catch {
        // The last known state is still useful when the status request is unavailable.
      }
      const normalized = normalizeGatewayUrl(url);
      setUrl(normalized);
      const nextPlace = inferGatewayPlace(normalized, {
        owner: Boolean(currentGate?.owner),
        local: Boolean(currentGate?.local),
      });
      setPlace(nextPlace);
      const stored =
        nextPlace === "mac"
          ? getMacSessionKey()
          : nextPlace === "device"
            ? getDeviceSessionKey()
            : null;
      const enteredKey = key.trim();
      const token =
        nextPlace === "device"
          ? enteredKey
            ? assertGatewayKey(enteredKey)
            : stored || undefined
          : enteredKey
            ? assertGatewayKey(enteredKey)
            : undefined;
      if (!token && !currentGate?.hasKey && !live) {
        throw new Error("missing-key");
      }
      if (nextPlace === "mac" && token) setMacSessionKey(token);
      const result = await probeGateway({
        url: normalized,
        key: token,
        place: nextPlace,
        save: true,
      });
      if (result.ok) {
        setKey("");
        setEditingConnection(false);
        setGate((current) =>
          current
            ? {
                ...current,
                hasKey: true,
                url: normalized,
                place: nextPlace,
              }
            : current,
        );
        setLive({
          model: result.model,
          provider: result.provider,
          models: result.models,
          platform: result.platform,
          skills: result.skills,
          manifest: result.manifest,
          probedAt: Date.now(),
          mode: result.mode,
          place: nextPlace,
        });
      } else {
        setConnectionIssue(result.code);
        setDown(result.error);
      }
    } catch (e) {
      const code = (e as { code?: ProbeCode }).code;
      setConnectionIssue(code ?? "unreachable");
      setDown(friendlyProbeError(code));
    } finally {
      setBusy(false);
    }
  }

  const corsCommand = `hermes config set API_SERVER_CORS_ORIGINS ${appOrigin} && sudo hermes gateway restart`;

  async function copyCorsCommand() {
    try {
      await navigator.clipboard.writeText(corsCommand);
      setCommandCopied(true);
    } catch {
      setCommandCopied(false);
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
        profile: advertisesHermesCapability(meta?.manifest, "profiles")
          ? profile
          : undefined,
      });
      if (!result.ok) {
        setEndpointError(result.error || t("error.saveEndpoint"));
        return;
      }
      setEndpointKey("");
      setEndpointOk(true);
      if (result.models?.length) setGatewayModels(result.models);
      if (result.model) setModel(result.model, result.provider);
    } catch {
      setEndpointError(t("error.saveEndpoint"));
    } finally {
      setEndpointBusy(false);
    }
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-8 px-4 py-8 pb-20 sm:px-6">
        <PageHeader
          kicker={t("connect.kicker")}
          title={t("connect.title")}
          description={t("connect.description")}
        />

        {!live || editingConnection ? (
          <section className="space-y-3">
            <div className="flex flex-col gap-4 rounded-xl bg-card p-4 border border-border">
              {!live ? (
                <p className="text-sm text-muted-foreground">
                  {t("connect.setupHint")}
                </p>
              ) : null}
              <label className="flex flex-col gap-1.5 text-sm">
                {t("connect.address")}
                <Input
                  value={url}
                  onChange={(e) => {
                    setUrl(e.target.value);
                    setConnectionIssue(null);
                  }}
                  placeholder={t("connect.addressPlaceholder")}
                  autoComplete="off"
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("connect.key")}
                <Input
                  type="password"
                  value={key}
                  onChange={(e) => setKey(e.target.value)}
                  placeholder={
                    live || gate?.hasKey
                      ? t("connect.keyConnected")
                      : t("connect.keyPlaceholder")
                  }
                  autoComplete="off"
                />
              </label>
              {error ? (
                <p className="text-sm text-destructive">
                  {localizeError(locale, error)}
                </p>
              ) : null}
              {connectionIssue === "cors" ? (
                <div className="space-y-3 rounded-lg border border-border bg-background p-4">
                  <div className="space-y-1">
                    <h3 className="text-sm font-medium">
                      {t("connect.mobileCorsTitle")}
                    </h3>
                    <p className="text-sm text-muted-foreground">
                      {t("connect.mobileCorsHint")}
                    </p>
                  </div>
                  <code className="block overflow-x-auto whitespace-nowrap rounded-md bg-muted px-3 py-2.5 font-mono text-xs text-foreground">
                    {corsCommand}
                  </code>
                  <div className="flex flex-wrap items-center gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void copyCorsCommand()}
                    >
                      {commandCopied
                        ? t("connect.commandCopied")
                        : t("connect.copyCommand")}
                    </Button>
                    <span className="text-xs text-muted-foreground">
                      {t("connect.mobileCorsRetry")}
                    </span>
                  </div>
                </div>
              ) : null}
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  onClick={() => void connect()}
                  disabled={
                    busy ||
                    !url.trim() ||
                    (!key.trim() && !live && !gate?.hasKey)
                  }
                >
                  {busy
                    ? t("connect.checking")
                    : live
                      ? t("connect.reconnect")
                      : t("connect.connect")}
                </Button>
                {live ? (
                  <Button
                    variant="ghost"
                    onClick={() => setEditingConnection(false)}
                  >
                    {t("connect.cancel")}
                  </Button>
                ) : null}
              </div>
            </div>
          </section>
        ) : null}

        {live && meta ? (
          <section className="space-y-3">
            <h2 className="text-sm font-medium">{t("connect.status")}</h2>
            <div className="rounded-xl bg-card px-4 py-4 border border-border">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant="live">{t("connect.online")}</Badge>
                <span className="text-sm">{meta.model}</span>
              </div>
              <p className="mt-2 text-sm text-muted-foreground">
                {meta.platform ?? "Hermes"} ·{" "}
                {meta.place === "cloud"
                  ? t("connect.remote")
                  : t("connect.local")}
              </p>
              <p className="mt-2 text-sm text-muted-foreground">
                {t(
                  meta.place === "device"
                    ? "connect.savedForDevice"
                    : "connect.savedForAccount",
                )}
              </p>
              <div className="mt-4 flex flex-wrap gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setEditingConnection(true)}
                >
                  {t("connect.change")}
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    forget();
                    setGate((current) =>
                      current ? { ...current, hasKey: false } : current,
                    );
                  }}
                >
                  {t("connect.forget")}
                </Button>
              </div>
            </div>
          </section>
        ) : null}

        <HermesLiveSections
          loading={liveState.loading}
          error={liveState.error}
          data={liveState.data}
          setData={liveState.setData}
        />

        {live && place !== "device" ? (
          <details className="rounded-xl bg-card border border-border">
            <summary className="cursor-pointer px-4 py-3 text-sm font-medium">
              {t("connect.advanced")}
            </summary>
            <div className="flex flex-col gap-4 border-t border-border p-4">
              <p className="text-sm text-muted-foreground">
                {t("connect.providerHint")}
              </p>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("connect.name")}
                <Input
                  value={endpointName}
                  onChange={(e) => {
                    setEndpointName(e.target.value);
                    setEndpointOk(false);
                  }}
                  placeholder={t("connect.namePlaceholder")}
                  autoComplete="off"
                  disabled={!live}
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("connect.address")}
                <Input
                  value={endpointUrl}
                  onChange={(e) => {
                    setEndpointUrl(e.target.value);
                    setEndpointOk(false);
                  }}
                  placeholder={t("connect.endpointPlaceholder")}
                  autoComplete="off"
                  disabled={!live}
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("connect.key")}
                <Input
                  type="password"
                  value={endpointKey}
                  onChange={(e) => setEndpointKey(e.target.value)}
                  placeholder={t("connect.endpointKeyPlaceholder")}
                  autoComplete="off"
                  disabled={!live}
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm">
                {t("connect.model")}
                <Input
                  value={endpointModel}
                  onChange={(e) => setEndpointModel(e.target.value)}
                  placeholder={t("connect.modelPlaceholder")}
                  autoComplete="off"
                  disabled={!live}
                />
              </label>
              {endpointError ? (
                <p className="text-sm text-destructive">
                  {localizeError(locale, endpointError)}
                </p>
              ) : null}
              {endpointOk ? (
                <p className="text-sm text-muted-foreground">
                  {t("connect.saved")}
                </p>
              ) : null}
              <div>
                <Button
                  onClick={() => void addEndpoint()}
                  disabled={!live || endpointBusy || !endpointUrl.trim()}
                >
                  {endpointBusy
                    ? t("connect.saving")
                    : t("connect.addToHermes")}
                </Button>
              </div>
            </div>
          </details>
        ) : null}
      </div>
    </div>
  );
}

function HermesLiveSections({
  loading,
  error,
  data,
  setData,
}: {
  loading: boolean;
  error: string | null;
  data: ReturnType<typeof useHermesLive>["data"];
  setData: ReturnType<typeof useHermesLive>["setData"];
}) {
  const t = useT();
  const locale = useLocale();
  const navigate = useNavigate();
  const model = useHermes((state) => state.model);
  const provider = useHermes((state) => state.modelProvider);
  const profile = useHermes((state) => state.profile);
  const manifest = useHermes((state) => state.gatewayMeta?.manifest);
  const importHermesSession = useHermes((state) => state.importHermesSession);
  const [sessionBusy, setSessionBusy] = useState<string | null>(null);
  const [sessionError, setSessionError] = useState<string | null>(null);
  const [sessionNotice, setSessionNotice] = useState<string | null>(null);
  const [newSessionTitle, setNewSessionTitle] = useState("");
  const [editingSessionId, setEditingSessionId] = useState<string | null>(null);
  const [editingSessionTitle, setEditingSessionTitle] = useState("");
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
  const [pairingBusy, setPairingBusy] = useState<string | null>(null);
  const [pairingError, setPairingError] = useState<string | null>(null);
  const [pairingNotice, setPairingNotice] = useState<string | null>(null);
  const [confirmRevokeId, setConfirmRevokeId] = useState<string | null>(null);
  const [curatorBusy, setCuratorBusy] = useState(false);
  const [curatorError, setCuratorError] = useState<string | null>(null);
  const [curatorNotice, setCuratorNotice] = useState<string | null>(null);

  if (loading) {
    return (
      <p className="text-sm text-muted-foreground">
        {t("connect.readingLive")}
      </p>
    );
  }
  if (error) {
    return (
      <p className="text-sm text-muted-foreground">
        {localizeError(locale, error)}
      </p>
    );
  }
  if (!data) return null;

  const channels = data.channels;
  const pending = data.pairing;
  const approved = data.pairingApproved;
  const sessions = data.sessions;
  const webhooks = data.webhooks;
  const curator = data.curator;
  const canForkSessions = advertisesHermesCapability(manifest, "session_fork");
  const canCreateSessions = advertisesHermesCapability(
    manifest,
    "session_create",
  );
  const canUpdateSessions = advertisesHermesCapability(
    manifest,
    "session_update",
  );
  const canDeleteSessions = advertisesHermesCapability(
    manifest,
    "session_delete",
  );
  const canLockSessionModel = advertisesHermesCapability(
    manifest,
    "session_model_lock",
  );
  const canReadSessionMessages = advertisesHermesCapability(
    manifest,
    "session_messages",
  );
  const canContinueSessions =
    canReadSessionMessages &&
    advertisesHermesCapability(manifest, "session_chat_stream");
  const canManagePairing = advertisesHermesCapability(manifest, "pairing");
  const canManageChannels = advertisesHermesCapability(manifest, "channels");
  const canReadDiagnostics = advertisesHermesCapability(
    manifest,
    "health_detailed",
  );
  const canManageCurator = advertisesHermesCapability(manifest, "curator");
  const canManageWebhooks = advertisesHermesCapability(manifest, "webhooks");

  async function refreshLive() {
    const refreshed = await listHermesLive();
    if (refreshed.ok) setData(refreshed);
  }

  async function runCuratorAction(mutation: HermesMutation) {
    setCuratorBusy(true);
    setCuratorError(null);
    setCuratorNotice(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setCuratorError(
        result.error
          ? localizeError(locale, result.error)
          : t("connect.curatorError"),
      );
      setCuratorBusy(false);
      return;
    }
    const refreshed = await listHermesLive();
    if (refreshed.ok) setData(refreshed);
    setCuratorNotice(t("connect.curatorSaved"));
    setCuratorBusy(false);
  }

  async function runPairingAction(
    key: string,
    mutation: HermesMutation,
  ): Promise<boolean> {
    setPairingBusy(key);
    setPairingError(null);
    setPairingNotice(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setPairingError(
        result.error
          ? localizeError(locale, result.error)
          : t("connect.pairingError"),
      );
      setPairingBusy(null);
      return false;
    }
    const refreshed = await listHermesLive();
    if (refreshed.ok) setData(refreshed);
    setPairingNotice(t("connect.pairingSaved"));
    setPairingBusy(null);
    return true;
  }

  async function runSessionAction(
    key: string,
    mutation: HermesMutation,
  ): Promise<boolean> {
    setSessionBusy(key);
    setSessionError(null);
    setSessionNotice(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setSessionError(
        result.error
          ? localizeError(locale, result.error)
          : t("connect.sessionError"),
      );
      setSessionBusy(null);
      return false;
    }
    const refreshed = await listHermesLive();
    if (refreshed.ok) setData(refreshed);
    setSessionNotice(t("connect.sessionSaved"));
    setSessionBusy(null);
    return true;
  }

  async function continueSession(session: (typeof sessions)[number]) {
    setSessionBusy(`continue:${session.id}`);
    setSessionError(null);
    setSessionNotice(null);
    const result = await readHermesSessionMessages({ sessionId: session.id });
    if (!result.ok) {
      setSessionError(localizeError(locale, result.error));
      setSessionBusy(null);
      return;
    }
    importHermesSession({
      sessionId: result.sessionId,
      title: session.title || session.id,
      messages: result.messages,
      profile,
    });
    setSessionBusy(null);
    await navigate({ to: "/" });
  }

  return (
    <>
      {canReadDiagnostics ? <HermesDiagnosticsPanel /> : null}

      {canManageCurator && curator ? (
        <section className="space-y-3">
          <h2 className="text-sm font-medium">{t("connect.curator")}</h2>
          <div className="rounded-xl bg-card px-4 py-4 border border-border">
            <div className="flex flex-wrap items-center gap-2">
              <Badge
                variant={
                  curator.enabled && !curator.paused ? "live" : "outline"
                }
              >
                {curator.enabled
                  ? curator.paused
                    ? t("connect.curatorPaused")
                    : t("connect.active")
                  : t("connect.off")}
              </Badge>
              {curator.intervalHours !== undefined ? (
                <span className="text-sm text-muted-foreground">
                  {t("connect.curatorEvery", {
                    count: curator.intervalHours,
                  })}
                </span>
              ) : null}
            </div>
            {curator.lastRunAt ? (
              <p className="mt-2 text-sm text-muted-foreground">
                {t("connect.curatorLastRun", {
                  date: formatStamp(locale, curator.lastRunAt),
                })}
              </p>
            ) : null}
            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-2xs text-muted-foreground">
              {curator.minIdleHours !== undefined ? (
                <span>
                  {t("connect.curatorIdle", {
                    count: curator.minIdleHours,
                  })}
                </span>
              ) : null}
              {curator.staleAfterDays !== undefined ? (
                <span>
                  {t("connect.curatorStale", {
                    count: curator.staleAfterDays,
                  })}
                </span>
              ) : null}
              {curator.archiveAfterDays !== undefined ? (
                <span>
                  {t("connect.curatorArchive", {
                    count: curator.archiveAfterDays,
                  })}
                </span>
              ) : null}
            </div>
            {curatorError ? (
              <p className="mt-3 text-sm text-destructive" role="alert">
                {curatorError}
              </p>
            ) : null}
            {curatorNotice ? (
              <p className="mt-3 text-sm text-muted-foreground" role="status">
                {curatorNotice}
              </p>
            ) : null}
            {data.writable && curator.enabled ? (
              <div className="mt-4 flex flex-wrap gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  className="min-h-11 md:min-h-8"
                  disabled={curatorBusy}
                  onClick={() =>
                    void runCuratorAction({ action: "curator-run" })
                  }
                >
                  {t("connect.curatorRun")}
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  className="min-h-11 md:min-h-8"
                  disabled={curatorBusy}
                  onClick={() =>
                    void runCuratorAction({
                      action: "curator-pause",
                      paused: !curator.paused,
                    })
                  }
                >
                  {curator.paused
                    ? t("connect.curatorResume")
                    : t("connect.curatorPause")}
                </Button>
              </div>
            ) : null}
          </div>
        </section>
      ) : null}

      <HermesChannelsPanel
        channels={channels}
        writable={data.writable && canManageChannels}
        onChanged={refreshLive}
      />

      {pending.length > 0 || approved.length > 0 ? (
        <section className="space-y-3">
          <h2 className="text-sm font-medium">{t("connect.pairing")}</h2>
          {pairingError ? (
            <p className="text-sm text-destructive" role="alert">
              {pairingError}
            </p>
          ) : null}
          {pairingNotice ? (
            <p className="text-sm text-muted-foreground" role="status">
              {pairingNotice}
            </p>
          ) : null}
          <ul className="flex flex-col gap-2">
            {pending.map((row) => (
              <li
                key={`p-${row.platform}-${row.requestId ?? row.code ?? row.user ?? ""}`}
                className="rounded-xl bg-card px-4 py-4 border border-border"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-medium">{row.user || row.platform}</h3>
                  <Badge variant="warn">{t("connect.pending")}</Badge>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">
                  {prettyPlatform(row.platform)}
                  {row.code ? ` · ${row.code}` : ""}
                </p>
                {canManagePairing && (row.requestId || row.code) ? (
                  <Button
                    size="sm"
                    className="mt-3 min-h-11 md:min-h-8"
                    disabled={pairingBusy !== null}
                    onClick={() =>
                      void runPairingAction(
                        `approve:${row.platform}:${row.requestId ?? row.code}`,
                        {
                          action: "pairing-approve",
                          platform: row.platform,
                          ...(row.requestId
                            ? { requestId: row.requestId }
                            : { code: row.code }),
                        },
                      )
                    }
                  >
                    {t("connect.approvePairing")}
                  </Button>
                ) : null}
              </li>
            ))}
            {approved.map((row) => (
              <li
                key={`a-${row.platform}-${row.userId ?? row.user ?? row.code ?? ""}`}
                className="rounded-xl bg-card px-4 py-4 border border-border"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="font-medium">{row.user || row.platform}</h3>
                  <Badge variant="live">{t("connect.approved")}</Badge>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">
                  {prettyPlatform(row.platform)}
                </p>
                {canManagePairing && row.userId ? (
                  <Button
                    variant={
                      confirmRevokeId === row.userId ? "destructive" : "ghost"
                    }
                    size="sm"
                    className="mt-3 min-h-11 md:min-h-8"
                    disabled={pairingBusy !== null}
                    onClick={() => {
                      if (confirmRevokeId !== row.userId) {
                        setConfirmRevokeId(row.userId ?? null);
                        return;
                      }
                      void runPairingAction(
                        `revoke:${row.platform}:${row.userId}`,
                        {
                          action: "pairing-revoke",
                          platform: row.platform,
                          userId: row.userId as string,
                          confirm: true,
                        },
                      ).then((ok) => {
                        if (ok) setConfirmRevokeId(null);
                      });
                    }}
                  >
                    {confirmRevokeId === row.userId
                      ? t("connect.confirmRevokePairing")
                      : t("connect.revokePairing")}
                  </Button>
                ) : null}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="space-y-3">
        <h2 className="text-sm font-medium">{t("connect.sessions")}</h2>
        <p className="text-sm text-muted-foreground">
          {t("connect.sessionsHint")}
        </p>
        {canCreateSessions ? (
          <form
            className="flex flex-col gap-2 sm:flex-row"
            onSubmit={(event) => {
              event.preventDefault();
              const title = newSessionTitle.trim();
              if (!title) return;
              void runSessionAction("create", {
                action: "session-create",
                sessionId: `alice_${crypto.randomUUID()}`,
                title,
                ...(model ? { model } : {}),
                ...(provider ? { provider } : {}),
              }).then((ok) => {
                if (ok) setNewSessionTitle("");
              });
            }}
          >
            <Input
              value={newSessionTitle}
              onChange={(event) => setNewSessionTitle(event.target.value)}
              placeholder={t("connect.sessionTitle")}
              aria-label={t("connect.sessionTitle")}
              maxLength={512}
              disabled={sessionBusy !== null}
              className="min-h-11 md:min-h-10"
            />
            <Button
              type="submit"
              className="min-h-11 shrink-0 md:min-h-10"
              disabled={sessionBusy !== null || !newSessionTitle.trim()}
            >
              {t("connect.createSession")}
            </Button>
          </form>
        ) : null}
        {sessionError ? (
          <p className="text-sm text-destructive" role="alert">
            {sessionError}
          </p>
        ) : null}
        {sessionNotice ? (
          <p className="text-sm text-muted-foreground" role="status">
            {sessionNotice}
          </p>
        ) : null}
        {sessions.length === 0 ? (
          <div className="rounded-xl bg-card px-4 py-8 text-center text-sm text-muted-foreground border border-border">
            {t("connect.noSessions")}
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {sessions.map((session) => (
              <li
                key={session.id}
                className="rounded-xl bg-card px-4 py-4 border border-border"
              >
                {editingSessionId === session.id ? (
                  <form
                    className="flex flex-col gap-2 sm:flex-row"
                    onSubmit={(event) => {
                      event.preventDefault();
                      const title = editingSessionTitle.trim();
                      if (!title) return;
                      void runSessionAction(`rename:${session.id}`, {
                        action: "session-update",
                        sessionId: session.id,
                        title,
                      }).then((ok) => {
                        if (ok) setEditingSessionId(null);
                      });
                    }}
                  >
                    <Input
                      value={editingSessionTitle}
                      onChange={(event) =>
                        setEditingSessionTitle(event.target.value)
                      }
                      aria-label={t("connect.sessionTitle")}
                      maxLength={512}
                      autoFocus
                      disabled={sessionBusy !== null}
                      className="min-h-11 md:min-h-10"
                    />
                    <div className="flex gap-2">
                      <Button
                        type="submit"
                        size="sm"
                        className="min-h-11 md:min-h-8"
                        disabled={
                          sessionBusy !== null || !editingSessionTitle.trim()
                        }
                      >
                        {t("connect.saveSession")}
                      </Button>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="min-h-11 md:min-h-8"
                        disabled={sessionBusy !== null}
                        onClick={() => setEditingSessionId(null)}
                      >
                        {t("connect.cancelSession")}
                      </Button>
                    </div>
                  </form>
                ) : (
                  <h3 className="font-medium">{session.title || session.id}</h3>
                )}
                <p className="mt-1 text-2xs text-muted-foreground">
                  {session.source ? prettyPlatform(session.source) : "Hermes"}
                  {typeof session.messages === "number"
                    ? ` · ${t("connect.messages", { count: session.messages })}`
                    : ""}
                  {session.updatedAt
                    ? ` · ${formatStamp(locale, session.updatedAt)}`
                    : ""}
                </p>
                {canContinueSessions ||
                canForkSessions ||
                canLockSessionModel ||
                canUpdateSessions ||
                canDeleteSessions ||
                canReadSessionMessages ? (
                  <div className="mt-3 flex flex-wrap gap-2">
                    {canContinueSessions ? (
                      <Button
                        size="sm"
                        className="min-h-11 md:min-h-8"
                        disabled={sessionBusy !== null}
                        onClick={() => void continueSession(session)}
                      >
                        {sessionBusy === `continue:${session.id}`
                          ? t("connect.continuingSession")
                          : t("connect.continueSession")}
                      </Button>
                    ) : null}
                    {canForkSessions ? (
                      <Button
                        variant="outline"
                        size="sm"
                        className="min-h-11 md:min-h-8"
                        disabled={sessionBusy !== null}
                        onClick={() =>
                          void runSessionAction(`fork:${session.id}`, {
                            action: "session-fork",
                            sessionId: session.id,
                            forkId: `alice_${crypto.randomUUID()}`,
                          })
                        }
                      >
                        {t("connect.forkSession")}
                      </Button>
                    ) : null}
                    {canLockSessionModel && model ? (
                      <Button
                        variant="ghost"
                        size="sm"
                        className="min-h-11 md:min-h-8"
                        disabled={sessionBusy !== null}
                        onClick={() =>
                          void runSessionAction(`model:${session.id}`, {
                            action: "session-model-lock",
                            sessionId: session.id,
                            model,
                            ...(provider ? { provider } : {}),
                          })
                        }
                      >
                        {t("connect.lockModel")}
                      </Button>
                    ) : null}
                    {canUpdateSessions && editingSessionId !== session.id ? (
                      <>
                        <Button
                          variant="ghost"
                          size="sm"
                          className="min-h-11 md:min-h-8"
                          disabled={sessionBusy !== null}
                          onClick={() => {
                            setEditingSessionId(session.id);
                            setEditingSessionTitle(session.title);
                            setConfirmDeleteId(null);
                          }}
                        >
                          {t("connect.renameSession")}
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          className="min-h-11 md:min-h-8"
                          disabled={sessionBusy !== null}
                          onClick={() =>
                            void runSessionAction(`pin:${session.id}`, {
                              action: "session-update",
                              sessionId: session.id,
                              pinned: !session.pinned,
                            })
                          }
                        >
                          {session.pinned
                            ? t("connect.unpinSession")
                            : t("connect.pinSession")}
                        </Button>
                      </>
                    ) : null}
                    {canDeleteSessions ? (
                      <Button
                        variant={
                          confirmDeleteId === session.id
                            ? "destructive"
                            : "ghost"
                        }
                        size="sm"
                        className="min-h-11 md:min-h-8"
                        disabled={sessionBusy !== null}
                        onClick={() => {
                          if (confirmDeleteId !== session.id) {
                            setConfirmDeleteId(session.id);
                            setEditingSessionId(null);
                            return;
                          }
                          void runSessionAction(`delete:${session.id}`, {
                            action: "session-delete",
                            sessionId: session.id,
                            confirm: true,
                          }).then((ok) => {
                            if (ok) setConfirmDeleteId(null);
                          });
                        }}
                      >
                        {confirmDeleteId === session.id
                          ? t("connect.confirmDeleteSession")
                          : t("connect.deleteSession")}
                      </Button>
                    ) : null}
                    {canReadSessionMessages ? (
                      <HermesSessionInspector sessionId={session.id} />
                    ) : null}
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </section>

      {canManageWebhooks ? (
        <HermesWebhooksPanel
          state={webhooks}
          writable={data.writable}
          onChanged={refreshLive}
        />
      ) : null}
    </>
  );
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

function formatStamp(locale: Locale, value: string) {
  const n = Number(value);
  const d = new Date(
    !Number.isNaN(n) && n > 1_000_000_000 ? (n < 1e12 ? n * 1000 : n) : value,
  );
  if (Number.isNaN(d.getTime())) return value;
  return new Intl.DateTimeFormat(dateLocale(locale), {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(d);
}
