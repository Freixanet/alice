import { createFileRoute } from "@tanstack/react-router";
import { observeApiRequest } from "@/lib/operational-telemetry.server";
import { tailnetHttpsOrigin } from "@/lib/tailnet.server";

export const Route = createFileRoute("/api/phone")({
  server: {
    handlers: {
      GET: observeApiRequest("/api/phone", () => {
        if (process.env.VERCEL) {
          return Response.json({ origin: null, install: null, online: false });
        }
        const origin = tailnetHttpsOrigin();
        if (!origin) {
          return Response.json({ origin: null, install: null, online: false });
        }
        return Response.json({
          origin,
          install: `${origin}/?install=1`,
          online: true,
        });
      }),
    },
  },
});
