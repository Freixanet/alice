import { createFileRoute } from "@tanstack/react-router";
import { tailnetHttpsOrigin } from "@/lib/tailnet.server";

export const Route = createFileRoute("/api/phone")({
  server: {
    handlers: {
      GET: () => {
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
      },
    },
  },
});
