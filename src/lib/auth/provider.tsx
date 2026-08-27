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

  useEffect(() => {
    if (!user || user.isDevFallback) {
      setCockpitIdentity({ id: user?.isDevFallback ? user.id : null, owner: Boolean(user?.isDevFallback) });
      if (user?.isDevFallback) void useHermes.persist.rehydrate();
      return;
    }
    setCockpitIdentity({ id: user.id, owner: false });
    const ctrl = new AbortController();
    void fetch("/api/hermes", {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "status" }),
      signal: ctrl.signal,
    })
      .then((res) => res.json() as Promise<{ owner?: boolean }>)
      .then((data) => {
        if (ctrl.signal.aborted) return;
        setCockpitIdentity({ id: user.id, owner: Boolean(data.owner) });
        void useHermes.persist.rehydrate();
      })
      .catch(() => {
        if (ctrl.signal.aborted) return;
        void useHermes.persist.rehydrate();
      });
    return () => ctrl.abort();
  }, [user?.id, user?.isDevFallback]);

  return <>{children}</>;
}
