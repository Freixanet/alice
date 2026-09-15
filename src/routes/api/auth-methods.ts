import { createFileRoute } from "@tanstack/react-router";
import { configuredSignInMethods } from "@/lib/auth/methods";

export const Route = createFileRoute("/api/auth-methods")({
  server: {
    handlers: {
      GET: () =>
        Response.json(
          { providers: configuredSignInMethods(process.env) },
          { headers: { "Cache-Control": "no-store" } },
        ),
    },
  },
});
