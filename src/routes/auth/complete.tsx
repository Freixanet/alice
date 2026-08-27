import { useEffect } from "react";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { setBearerToken } from "@/lib/auth/client";

export const Route = createFileRoute("/auth/complete")({
  validateSearch: (search: Record<string, unknown>) => ({
    token: typeof search.token === "string" ? search.token : undefined,
  }),
  component: AuthCompletePage,
});

function AuthCompletePage() {
  const { token } = Route.useSearch();
  const navigate = useNavigate();

  useEffect(() => {
    if (!token) {
      void navigate({ to: "/login" });
      return;
    }
    setBearerToken(token);
    try {
      window.history.replaceState(null, "", "/auth/complete");
    } catch {
      /* ignore */
    }
    window.location.replace("/");
  }, [token, navigate]);

  return (
    <div className="grid min-h-svh place-items-center text-sm text-muted-foreground">
      Un momento…
    </div>
  );
}
