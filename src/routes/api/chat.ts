import { createFileRoute } from "@tanstack/react-router";
import {
  GatewayError,
  type ChatEvent,
  type GatewayPlace,
  type HermesChatContent,
} from "@/lib/gateway";
import {
  hermesDashboardGet,
  hermesDashboardSendJson,
  ndjsonResponse,
  resolveAliceGate,
  streamHermesProxy,
  streamHermesSessionProxy,
} from "@/lib/gateway.server";
import { chatRequestSchema } from "@/lib/api-contracts";
import { isHermesSelfUpdateIntent } from "@/lib/hermes-update-intent";
import {
  assertSameOriginRequest,
  parseJsonRequest,
  requestErrorResponse,
} from "@/lib/http.server";
import {
  consumeSharedRateLimit,
  rateLimitResponse,
} from "@/lib/rate-limit.server";
import { observeApiRequest } from "@/lib/operational-telemetry.server";
import { whenDefined } from "@/lib/exact-optional";

const FAIL = "Couldn’t connect.";

export const Route = createFileRoute("/api/chat")({
  server: {
    handlers: {
      POST: observeApiRequest("/api/chat", async ({ request }) => {
        try {
          assertSameOriginRequest(request);
        } catch (error) {
          return (
            requestErrorResponse(error) ??
            Response.json({ error: "bad_request" }, { status: 400 })
          );
        }
        const { saved: gate, userId } = await resolveAliceGate(request);
        if (!userId) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }
        const rate = await consumeSharedRateLimit("chat", userId, 60, 60_000);
        if (!rate.ok) return rateLimitResponse(rate);

        let body;
        try {
          body = await parseJsonRequest(
            request,
            chatRequestSchema,
            10 * 1024 * 1024 + 65_536,
          );
        } catch (error) {
          return (
            requestErrorResponse(error) ??
            Response.json({ error: "bad_request" }, { status: 400 })
          );
        }

        const clean = body.messages
          .map((m) => ({
            role: m.role,
            content: cleanChatContent(m.content),
          }))
          .filter(
            (
              m,
            ): m is {
              role: "user" | "assistant";
              content: HermesChatContent;
            } =>
              typeof m.content === "string"
                ? Boolean(m.content.trim())
                : m.content.length > 0,
          );

        if (clean.length === 0) {
          return Response.json({ error: "empty" }, { status: 400 });
        }

        if (gate?.u && gate.k) {
          try {
            const latestUser = [...clean]
              .reverse()
              .find((message) => message.role === "user");
            if (
              latestUser &&
              typeof latestUser.content === "string" &&
              isHermesSelfUpdateIntent(latestUser.content)
            ) {
              return await startHermesSelfUpdate({
                url: gate.u,
                key: gate.k,
                place: gate.p,
                requestSignal: request.signal,
              });
            }
            if (body.hermesSessionId) {
              if (!latestUser) {
                return Response.json({ error: "empty" }, { status: 400 });
              }
              return await streamHermesSessionProxy({
                url: gate.u,
                key: gate.k,
                sessionId: body.hermesSessionId,
                message: latestUser.content,
                ...whenDefined("conversationId", body.conversationId),
                ...whenDefined("model", body.model),
                ...whenDefined("provider", body.provider),
                signal: request.signal,
                place: gate.p,
                ...whenDefined("profile", body.profile),
              });
            }
            return await streamHermesProxy({
              url: gate.u,
              key: gate.k,
              messages: clean,
              ...whenDefined("conversationId", body.conversationId),
              ...whenDefined("model", body.model),
              ...whenDefined("provider", body.provider),
              ...whenDefined("preferRuns", body.preferRuns),
              ...whenDefined("runIdempotency", body.runIdempotency),
              ...whenDefined("endpoints", gate.ep),
              signal: request.signal,
              place: gate.p,
              ...whenDefined("profile", body.profile),
            });
          } catch (e) {
            const status =
              e instanceof GatewayError &&
              (e.code === "private" || e.code === "invalid")
                ? 400
                : 502;
            return ndjsonResponse(async (send) => {
              send({ type: "error", message: FAIL } satisfies ChatEvent);
            }, status);
          }
        }

        return ndjsonResponse(async (send) => {
          send({
            type: "error",
            message: "Go back to Connect and paste the Hermes key.",
          } satisfies ChatEvent);
        }, 400);
      }),
    },
  },
});

async function startHermesSelfUpdate(opts: {
  url: string;
  key: string;
  place: GatewayPlace;
  requestSignal: AbortSignal;
}): Promise<Response> {
  const reply = (text: string) =>
    ndjsonResponse(async (send) => {
      send({ type: "delta", text } satisfies ChatEvent);
    });
  const fail = (message: string) =>
    ndjsonResponse(async (send) => {
      send({ type: "error", message } satisfies ChatEvent);
    }, 502);

  let check: Record<string, unknown> | null = null;
  try {
    const raw = await hermesDashboardGet(
      {
        url: opts.url,
        key: opts.key,
        place: opts.place,
        signal: AbortSignal.any([
          opts.requestSignal,
          AbortSignal.timeout(20_000),
        ]),
      },
      "/api/hermes/update/check?force=true",
    );
    check = asRecord(raw);
  } catch (error) {
    if (opts.requestSignal.aborted) throw error;
    // A failed preview must not block an explicitly requested update. The
    // apply endpoint performs its own admission checks and fetches upstream.
  }

  if (check?.can_apply === false) {
    const message = stringField(check, "message");
    const command = stringField(check, "update_command");
    return reply(
      [
        message || "Esta instalación de Hermes no admite actualizaciones desde Alice.",
        command && command !== "managed outside dashboard"
          ? `Actualízala con: ${command}`
          : "",
      ]
        .filter(Boolean)
        .join("\n\n"),
    );
  }

  if (check?.update_available === false && check.behind === 0) {
    return reply("Hermes ya está actualizado.");
  }

  let raw: unknown;
  try {
    raw = await hermesDashboardSendJson(
      {
        url: opts.url,
        key: opts.key,
        place: opts.place,
        signal: AbortSignal.any([
          opts.requestSignal,
          AbortSignal.timeout(20_000),
        ]),
      },
      "/api/hermes/update",
      "POST",
    );
  } catch (error) {
    if (opts.requestSignal.aborted) throw error;
    return fail("No pude iniciar la actualización de Hermes.");
  }

  const started = asRecord(raw);
  if (started?.ok !== true) {
    return fail(
      stringField(started, "message") ||
        stringField(started, "error") ||
        "Hermes rechazó la actualización.",
    );
  }

  if (started.already_running === true) {
    return reply(
      "La actualización de Hermes ya estaba en curso. Se está ejecutando en segundo plano.",
    );
  }

  return reply(
    "Actualización de Hermes iniciada en segundo plano. No tienes que mantener este turno abierto; Hermes reiniciará los gateways al terminar y Alice puede desconectarse unos segundos durante el reinicio.",
  );
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function stringField(
  value: Record<string, unknown> | null,
  key: string,
): string {
  const field = value?.[key];
  return typeof field === "string" ? field.trim() : "";
}

function cleanChatContent(value: unknown): HermesChatContent {
  if (typeof value === "string") return value.slice(0, 8000);
  if (!Array.isArray(value)) return "";
  const parts: Exclude<HermesChatContent, string> = [];
  for (const raw of value.slice(0, 8)) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
    const part = raw as Record<string, unknown>;
    if (
      part.type === "text" &&
      typeof part.text === "string" &&
      part.text.trim()
    ) {
      parts.push({ type: "text", text: part.text.slice(0, 8000) });
      continue;
    }
    if (part.type !== "image_url") continue;
    const image = part.image_url;
    if (!image || typeof image !== "object" || Array.isArray(image)) continue;
    const url = (image as Record<string, unknown>).url;
    if (
      typeof url === "string" &&
      url.length <= 12_000_000 &&
      (/^data:image\//i.test(url) || /^https?:\/\//i.test(url))
    ) {
      parts.push({ type: "image_url", image_url: { url, detail: "auto" } });
    }
  }
  return parts;
}
