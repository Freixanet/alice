import type { ReactNode } from "react";
import { authClient, authEnabled } from "./client";
import {
  SessionContext,
  DEV_USER,
  type CurrentUserState,
} from "./session-context";

/** Subscribes to Better Auth once and shares the result with the subtree. */
export function SessionBoundary({ children }: { children: ReactNode }) {
  return (
    <SessionContext.Provider value={useResolvedSession()}>
      {children}
    </SessionContext.Provider>
  );
}

function useResolvedSession(): CurrentUserState {
  // Hook order stays stable: `authEnabled` is a build-time constant.
  if (!authEnabled) return { user: DEV_USER, isPending: false };
  const { data, isPending } = authClient.useSession();
  const user = data?.user;
  return {
    user: user
      ? {
          id: user.id,
          displayName: user.name ?? null,
          primaryEmail: user.email ?? null,
          profileImageUrl: user.image ?? null,
          isDevFallback: false,
        }
      : null,
    isPending,
  };
}
