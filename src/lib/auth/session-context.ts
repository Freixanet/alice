import { createContext, useContext } from "react";

export type AppUser = {
  id: string;
  displayName: string | null;
  primaryEmail: string | null;
  profileImageUrl: string | null;
  isDevFallback: boolean;
};

export const DEV_USER: AppUser = {
  id: "dev-user",
  displayName: "Dev User",
  primaryEmail: "dev@example.com",
  profileImageUrl: null,
  isDevFallback: true,
};

export type CurrentUserState = {
  user: AppUser | null;
  isPending: boolean;
};

/**
 * One session subscription per tree.
 *
 * `authClient.useSession()` issues its own `/api/auth/get-session` request per
 * calling component, so the eight call sites in the app produced roughly that
 * many DB-backed session lookups on every load. `SessionBoundary` reads the
 * session once and publishes it here, collapsing them into a single request.
 *
 * Every consumer of `useCurrentUserState` must sit under a boundary; the two
 * roots (`/_app` and `/login`) both mount one.
 *
 * Types live here rather than in `use-current-user` so the dependency runs one
 * way: context → hook → components.
 */
export const SessionContext = createContext<CurrentUserState | null>(null);

/**
 * Returns null when no boundary is mounted above, so callers can decide what a
 * missing session means rather than crashing the tree.
 */
export function useSharedSession(): CurrentUserState | null {
  return useContext(SessionContext);
}
