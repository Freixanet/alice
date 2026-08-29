import { createFileRoute } from "@tanstack/react-router";
import {
  GatewayError,
  type ChatEvent,
  type HermesChatContent,
} from "@/lib/gateway";
import {
  ndjsonResponse,
  resolveAliceGate,
  streamHermesProxy,
} from "@/lib/gateway.server";

const FAIL = "Couldn’t connect.";

type Incoming = {
  messages?: Array<{ role: string; content: unknown }>;
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
          .filter((m) => m.role === "user" || m.role === "assistant")
          .slice(-16)
          .map((m) => ({
            role: m.role as "user" | "assistant",
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
              conversationId:
                typeof body.conversationId === "string"
                  ? body.conversationId
                  : undefined,
              model: typeof body.model === "string" ? body.model : undefined,
              provider:
                typeof body.provider === "string" ? body.provider : undefined,
              endpoints: gate.ep,
              signal: request.signal,
              place: gate.p,
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
      },
    },
  },
});

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
