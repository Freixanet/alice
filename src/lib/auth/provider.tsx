import { useEffect, type ReactNode } from "react";
import { authHeaders } from "./client";
import { setCockpitIdentity } from "./cockpit-user";
import { useCurrentUser } from "./use-current-user";
import { useHermes } from "../store";

/**
 * App-wide client provider mounted once near the root (in `src/routes/__root.tsx`):
 *
 *   <AuthProvider><Outlet /></AuthProvider>
 *
 * Better Auth's React client (`@/lib/auth/client`) needs NO context provider —
 * its `useSession()` works standalone. This also binds the cockpit store to the
 * signed-in user so chats and Hermes connection stay per account.
 */
export function AuthProvider({ children }: { children: ReactNode }) {
  const user = useCurrentUser();
  const userId = user?.id ?? null;
  const isDevFallback = Boolean(user?.isDevFallback);

  useEffect(() => {
    if (!userId || isDevFallback) {
      setCockpitIdentity({ id: isDevFallback ? userId : null, owner: isDevFallback });
      if (isDevFallback) void useHermes.persist.rehydrate();
      return;
    }
    setCockpitIdentity({ id: userId, owner: false });
    const ctrl = new AbortController();
    void fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "status" }),
      signal: ctrl.signal,
    })
      .then(
        (res) =>
          res.json() as Promise<{
            owner?: boolean;
            hasKey?: boolean;
            url?: string;
            place?: "cloud" | "mac";
          }>,
      )
      .then(async (data) => {
        if (ctrl.signal.aborted) return;
        setCockpitIdentity({ id: userId, owner: Boolean(data.owner) });
        await useHermes.persist.rehydrate();
        if (ctrl.signal.aborted) return;
        const state = useHermes.getState();
        if (
          data.hasKey &&
          data.url &&
          (data.place === "cloud" || data.place === "mac") &&
          (!state.gatewayOn || !state.gatewayUrl)
        ) {
          state.restoreGateway({ url: data.url, place: data.place });
        }
      })
      .catch(() => {
        if (ctrl.signal.aborted) return;
        void useHermes.persist.rehydrate();
      });
    return () => ctrl.abort();
  }, [userId, isDevFallback]);

  return <>{children}</>;
}
