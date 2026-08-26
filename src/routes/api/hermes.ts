import { createFileRoute } from "@tanstack/react-router";
import {
  jsonWithCookie,
  listHermesModelsServer,
  probeHermes,
  readGateCookie,
  sealGate,
  setHermesModelServer,
} from "@/lib/gateway.server";
import type { GatewayPlace } from "@/lib/gateway";

type Incoming = {
  action?: string;
  url?: string;
  key?: string;
  place?: GatewayPlace;
  model?: string;
  provider?: string;
  conversationId?: string;
  refresh?: boolean;
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

        const saved = readGateCookie(request);

        if (body.action === "status") {
          return jsonWithCookie(
            {
              ok: true,
              hasKey: Boolean(saved?.k),
              url: saved?.u,
              place: saved?.p,
            },
            200,
          );
        }

        if (body.action === "forget") {
          return jsonWithCookie({ ok: true }, 200, null);
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
            );
            return jsonWithCookie({ ok: true, ...listed }, 200);
          } catch {
            return jsonWithCookie({ ok: false, models: [] }, 502);
          }
        }

        if (body.action === "set-model") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie({ ok: false }, 400);
          }
          const model = typeof body.model === "string" ? body.model.trim() : "";
          if (!model) return jsonWithCookie({ ok: false }, 400);
          try {
            const result = await setHermesModelServer({
              url: saved.u,
              key: saved.k,
              model,
              provider: typeof body.provider === "string" ? body.provider : undefined,
              conversationId:
                typeof body.conversationId === "string" ? body.conversationId : undefined,
              signal: AbortSignal.any([request.signal, AbortSignal.timeout(12_000)]),
            });
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie({ ok: false }, 502);
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

        const result = await probeHermes(
          url,
          key,
          AbortSignal.any([request.signal, AbortSignal.timeout(12_000)]),
        );

        const status = result.ok
          ? 200
          : result.code === "unauthorized"
            ? 401
            : result.code === "private" || result.code === "invalid"
              ? 400
              : 502;

        if (body.action === "connect" && result.ok) {
          const place: GatewayPlace = body.place === "mac" ? "mac" : "cloud";
          const token = sealGate({ k: key, u: url, p: place });
          return jsonWithCookie(result, 200, token);
        }

        return jsonWithCookie(result, status);
      },
    },
  },
});
