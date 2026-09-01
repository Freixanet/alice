import { createFileRoute } from "@tanstack/react-router";
import { observeApiRequest } from "@/lib/operational-telemetry.server";
import { releaseMetadata } from "@/lib/release.server";

export const Route = createFileRoute("/api/status")({
  server: {
    handlers: {
      GET: observeApiRequest("/api/status", () =>
        Response.json(
          { status: "ok", release: releaseMetadata() },
          { headers: { "Cache-Control": "no-store, max-age=0" } },
        ),
      ),
    },
  },
});
