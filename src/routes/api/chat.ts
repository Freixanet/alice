import { createFileRoute } from "@tanstack/react-router";
import { GatewayError, type ChatEvent } from "@/lib/gateway";
import { ndjsonResponse, readGateCookie, streamHermesProxy } from "@/lib/gateway.server";

const SYSTEM = `Eres Hermes, el agente de Nous Research que crece con la persona que te usa.
Hablas en español de España, de tú, con frases cortas. Una idea por párrafo. Sin relleno, sin emojis, sin teatro de “como IA”.
El usuario tiene ADHD y perfeccionismo: sé preciso, no enumeres diez opciones si bastan dos, no preguntes de más.
Conoces este cockpit: Chat, Habilidades, Herramientas, Complementos, Memoria, Conectar y Ajustes.
Si pide instalar o aprender una skill, confirma en una frase y describe qué harás.
No inventes que has ejecutado comandos reales fuera de este chat.
Si pregunta cómo conectar su Hermes, dile que vaya a Conectar y elija si está en la nube o en este Mac.`;

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

        const gate = readGateCookie(request);
        if (gate?.u && gate.k) {
          try {
            return await streamHermesProxy({
              url: gate.u,
              key: gate.k,
              messages: clean,
              conversationId: typeof body.conversationId === "string" ? body.conversationId : undefined,
              model: typeof body.model === "string" ? body.model : undefined,
              provider: typeof body.provider === "string" ? body.provider : undefined,
              signal: request.signal,
            });
          } catch (e) {
            const status = e instanceof GatewayError && (e.code === "private" || e.code === "invalid") ? 400 : 502;
            return ndjsonResponse(async (send) => {
              send({ type: "error", message: FAIL } satisfies ChatEvent);
            }, status);
          }
        }

        const apiKey = process.env.XAI_API_KEY;
        if (!apiKey) {
          return ndjsonResponse(async (send) => {
            send({
              type: "error",
              message: "Conecta tu Hermes para hablar con él.",
            } satisfies ChatEvent);
          }, 503);
        }

        const model =
          typeof body.model === "string" && body.model.startsWith("grok")
            ? body.model
            : "grok-4.5";

        const context =
          typeof body.context === "string" ? body.context.slice(0, 4000) : "";

        const xai = await fetch("https://api.x.ai/v1/chat/completions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${apiKey}`,
          },
          body: JSON.stringify({
            model,
            stream: true,
            temperature: 0.55,
            max_tokens: 800,
            messages: [
              {
                role: "system",
                content: context ? `${SYSTEM}\n\nEstado actual:\n${context}` : SYSTEM,
              },
              ...clean,
            ],
          }),
          signal: request.signal,
        });

        if (!xai.ok || !xai.body) {
          return ndjsonResponse(async (send) => {
            send({ type: "error", message: "No se ha podido responder." } satisfies ChatEvent);
          }, 502);
        }

        const decoder = new TextDecoder();
        return ndjsonResponse(async (send) => {
          const reader = xai.body!.getReader();
          let buf = "";
          try {
            while (true) {
              const { done, value } = await reader.read();
              if (done) break;
              buf += decoder.decode(value, { stream: true });
              const lines = buf.split("\n");
              buf = lines.pop() ?? "";
              for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed.startsWith("data:")) continue;
                const data = trimmed.slice(5).trim();
                if (!data || data === "[DONE]") continue;
                try {
                  const json = JSON.parse(data) as {
                    choices?: Array<{ delta?: { content?: string } }>;
                  };
                  const delta = json.choices?.[0]?.delta?.content;
                  if (delta) send({ type: "delta", text: delta } satisfies ChatEvent);
                } catch {
                  // ignore malformed chunks
                }
              }
            }
          } finally {
            reader.releaseLock();
          }
        });
      },
    },
  },
});
