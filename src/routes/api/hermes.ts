import { createFileRoute } from "@tanstack/react-router";
import {
  jsonWithCookie,
  listHermesModelsServer,
  modelsFromEndpoints,
  probeHermes,
  resolveAliceGate,
  saveHermesCustomEndpointServer,
  sealGate,
  setHermesModelServer,
  upsertStoredEndpoint,
  fetchHermesMemory,
} from "@/lib/gateway.server";
import type { GatewayPlace } from "@/lib/gateway";
import { GatewayError } from "@/lib/gateway";

type Incoming = {
  action?: string;
  url?: string;
  key?: string;
  place?: GatewayPlace;
  model?: string;
  provider?: string;
  conversationId?: string;
  refresh?: boolean;
  endpointName?: string;
  endpointUrl?: string;
  endpointKey?: string;
  endpointModel?: string;
  name?: string;
  enabled?: boolean;
  jobId?: string;
};

const FAIL = "No se ha podido conectar.";

export const Route = createFileRoute("/api/hermes")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        let body: Incoming;
        try {
          body = (await request.json()) as Incoming;
        } catch {
          return jsonWithCookie({ ok: false, code: "invalid", error: FAIL }, 400);
        }

        const { saved, owner, local, userId } = await resolveAliceGate(request);
        if (!userId) {
          return jsonWithCookie({ ok: false, error: "Entra para continuar." }, 401);
        }
        const macOk = owner && local;

        if (body.action === "status") {
          return jsonWithCookie(
            {
              ok: true,
              hasKey: Boolean(saved?.k),
              url: saved?.u,
              place: saved?.p,
              owner,
              local,
              userId,
            },
            200,
          );
        }

        if (body.action === "forget") {
          return jsonWithCookie({ ok: true }, 200, null);
        }

        if (body.action === "memory") {
          try {
            const result = await fetchHermesMemory({
              url: saved?.u,
              key: saved?.k,
              place: saved?.p,
              local: macOk,
              signal: AbortSignal.any([request.signal, AbortSignal.timeout(12_000)]),
            });
            return jsonWithCookie(result, 200);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "No se ha podido leer la memoria de Hermes." },
              502,
            );
          }
        }

        if (body.action === "live") {
          try {
            const { fetchHermesLive } = await import("@/lib/hermes-live.server");
            const result = await fetchHermesLive({
              url: saved?.u,
              key: saved?.k,
              place: saved?.p,
              local: macOk,
              owner,
              signal: AbortSignal.any([request.signal, AbortSignal.timeout(20_000)]),
            });
            return jsonWithCookie(result, 200);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "No se ha podido leer el estado de Hermes." },
              502,
            );
          }
        }

        if (
          body.action === "toggle-skill" ||
          body.action === "toggle-toolset" ||
          body.action === "toggle-mcp" ||
          body.action === "cron-pause" ||
          body.action === "cron-resume"
        ) {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie({ ok: false, error: "Conecta tu Hermes primero." }, 400);
          }
          try {
            const { mutateHermesLive } = await import("@/lib/hermes-live.server");
            const ok = await mutateHermesLive(
              {
                url: saved.u,
                key: saved.k,
                place: saved.p,
                signal: AbortSignal.any([request.signal, AbortSignal.timeout(12_000)]),
              },
              body.action,
              {
                name: typeof body.name === "string" ? body.name : undefined,
                enabled: body.enabled,
                jobId: typeof body.jobId === "string" ? body.jobId : undefined,
              },
            );
            return jsonWithCookie(
              ok ? { ok: true } : { ok: false, error: "Hermes no ha podido guardar el cambio." },
              ok ? 200 : 502,
            );
          } catch {
            return jsonWithCookie({ ok: false, error: "Hermes no ha podido guardar el cambio." }, 502);
          }
        }

        if (body.action === "models") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie({ ok: false, models: [] }, 400);
          }
          try {
            const listed = await listHermesModelsServer(
              saved.u,
              saved.k,
              AbortSignal.any([request.signal, AbortSignal.timeout(20_000)]),
              Boolean(body.refresh),
              saved.p,
            );
            const extra = modelsFromEndpoints(saved.ep);
            const models = [...listed.models];
            for (const item of extra) {
              if (!models.some((row) => row.id === item.id && row.provider === item.provider)) {
                models.push(item);
              }
            }
            return jsonWithCookie({ ok: true, ...listed, models }, 200);
          } catch {
            const extra = modelsFromEndpoints(saved.ep);
            if (extra.length) return jsonWithCookie({ ok: true, models: extra }, 200);
            return jsonWithCookie({ ok: false, models: [] }, 502);
          }
        }

        if (body.action === "set-model") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie({ ok: false }, 400);
          }
          const model = typeof body.model === "string" ? body.model.trim() : "";
          if (!model) return jsonWithCookie({ ok: false }, 400);
          const provider = typeof body.provider === "string" ? body.provider : undefined;
          try {
            const result = await setHermesModelServer({
              url: saved.u,
              key: saved.k,
              model,
              provider,
              conversationId:
                typeof body.conversationId === "string" ? body.conversationId : undefined,
              signal: AbortSignal.any([request.signal, AbortSignal.timeout(12_000)]),
              place: saved.p,
            });
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie({ ok: false }, 502);
          }
        }

        if (body.action === "custom-endpoint") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie({ ok: false, error: "Conecta tu Hermes primero." }, 400);
          }
          const endpointUrl = typeof body.endpointUrl === "string" ? body.endpointUrl.trim() : "";
          if (!endpointUrl) {
            return jsonWithCookie({ ok: false, error: "Falta la dirección." }, 400);
          }
          try {
            const result = await saveHermesCustomEndpointServer({
              url: saved.u,
              key: saved.k,
              place: saved.p,
              name: typeof body.endpointName === "string" ? body.endpointName : "",
              baseUrl: endpointUrl,
              apiKey: typeof body.endpointKey === "string" ? body.endpointKey : "",
              model: typeof body.endpointModel === "string" ? body.endpointModel : undefined,
              signal: AbortSignal.any([request.signal, AbortSignal.timeout(20_000)]),
            });
            if (!result.ok || !result.persist) {
              return jsonWithCookie(result, result.ok ? 200 : 502);
            }
            const token = sealGate({
              k: saved.k,
              u: saved.u,
              p: saved.p,
              ep: upsertStoredEndpoint(saved.ep, result.persist),
              ...(userId ? { uid: userId } : {}),
            });
            return jsonWithCookie(
              { ok: true, model: result.model, provider: result.provider, models: result.models },
              200,
              token,
            );
          } catch (e) {
            if (e instanceof GatewayError) {
              const message =
                e.code === "private"
                  ? "Tu Hermes es local. Elige «En este Mac»."
                  : e.code === "unauthorized"
                    ? "La clave de Hermes no es correcta."
                    : "Hermes no responde. Vuelve a conectarlo arriba.";
              return jsonWithCookie({ ok: false, error: message }, 502);
            }
            return jsonWithCookie(
              { ok: false, error: "Hermes no responde. Vuelve a conectarlo arriba." },
              502,
            );
          }
        }

        if (body.action !== "probe" && body.action !== "connect") {
          return jsonWithCookie({ ok: false, code: "invalid", error: FAIL }, 400);
        }

        const url = typeof body.url === "string" && body.url.trim() ? body.url : saved?.u;
        const key = typeof body.key === "string" && body.key.trim() ? body.key : saved?.k;
        if (!url || !key) {
          return jsonWithCookie({ ok: false, code: "invalid", error: FAIL }, 400);
        }

        const place: GatewayPlace = body.place === "mac" ? "mac" : "cloud";
        if (place === "mac" && !macOk) {
          return jsonWithCookie(
            {
              ok: false,
              code: "private",
              error: "Conecta tu Hermes con una dirección pública.",
            },
            400,
          );
        }
        const result = await probeHermes(
          url,
          key,
          AbortSignal.any([request.signal, AbortSignal.timeout(12_000)]),
          place,
        );

        const status = result.ok
          ? 200
          : result.code === "unauthorized"
            ? 401
            : result.code === "private" || result.code === "invalid"
              ? 400
              : 502;

        if (body.action === "connect" && result.ok) {
          if (!userId) {
            return jsonWithCookie({ ok: false, error: "Entra para continuar." }, 401);
          }
          const token = sealGate({
            k: key,
            u: url,
            p: place,
            ep: saved?.ep,
            ...(userId ? { uid: userId } : {}),
          });
          return jsonWithCookie(result, 200, token);
        }

        return jsonWithCookie(result, status);
      },
    },
  },
});
