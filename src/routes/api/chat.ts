import { createFileRoute } from "@tanstack/react-router";
import { GatewayError, type ChatEvent } from "@/lib/gateway";
import { ndjsonResponse, resolveAliceGate, streamHermesProxy } from "@/lib/gateway.server";

const FAIL = "No se ha podido conectar.";

type Incoming = {
  messages?: Array<{ role: string; content: string }>;
  context?: string;
  model?: string;
  provider?: string;
  conversationId?: string;
};

export const Route = createFileRoute("/api/chat")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        let body: Incoming;
        try {
          body = (await request.json()) as Incoming;
        } catch {
          return Response.json({ error: "bad_request" }, { status: 400 });
        }

        const messages = Array.isArray(body.messages) ? body.messages : [];
        const clean = messages
          .filter(
            (m) =>
              (m.role === "user" || m.role === "assistant") &&
              typeof m.content === "string" &&
              m.content.trim().length > 0,
          )
          .slice(-16)
          .map((m) => ({
            role: m.role as "user" | "assistant",
            content: m.content.slice(0, 8000),
          }));

        if (clean.length === 0) {
          return Response.json({ error: "empty" }, { status: 400 });
        }

        const { saved: gate, userId } = await resolveAliceGate(request);
        if (!userId) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }
        if (gate?.u && gate.k) {
          try {
            return await streamHermesProxy({
              url: gate.u,
              key: gate.k,
              messages: clean,
              conversationId: typeof body.conversationId === "string" ? body.conversationId : undefined,
              model: typeof body.model === "string" ? body.model : undefined,
              provider: typeof body.provider === "string" ? body.provider : undefined,
              endpoints: gate.ep,
              signal: request.signal,
              place: gate.p,
            });
          } catch (e) {
            const status = e instanceof GatewayError && (e.code === "private" || e.code === "invalid") ? 400 : 502;
            return ndjsonResponse(async (send) => {
              send({ type: "error", message: FAIL } satisfies ChatEvent);
            }, status);
          }
        }

        return ndjsonResponse(async (send) => {
          send({
            type: "error",
            message: "Conecta tu Hermes para hablar con él.",
          } satisfies ChatEvent);
        }, 400);
      },
    },
  },
});
