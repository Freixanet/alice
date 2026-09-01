import { createFileRoute } from "@tanstack/react-router";
import { clientOperationalEventSchema } from "@/lib/operational-telemetry";
import {
  consumeOperationalEventCapacity,
  observeApiRequest,
  recordOperationalEvent,
} from "@/lib/operational-telemetry.server";
import { parseJsonRequest, requestErrorResponse } from "@/lib/http.server";

const noContent = () =>
  new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });

export const Route = createFileRoute("/api/telemetry")({
  server: {
    handlers: {
      POST: observeApiRequest(
        "/api/telemetry",
        async ({ request }) => {
          try {
            const event = await parseJsonRequest(
              request,
              clientOperationalEventSchema,
              1_024,
            );
            if (!consumeOperationalEventCapacity()) {
              return new Response(null, {
                status: 429,
                headers: { "Cache-Control": "no-store", "Retry-After": "60" },
              });
            }
            recordOperationalEvent(event);
            return noContent();
          } catch (error) {
            return requestErrorResponse(error) ?? noContent();
          }
        },
        { record: false },
      ),
    },
  },
});
