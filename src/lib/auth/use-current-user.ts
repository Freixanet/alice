import {
  useSharedSession,
  type AppUser,
  type CurrentUserState,
} from "./session-context";

export { DEV_USER } from "./session-context";
export type { AppUser, CurrentUserState };

export function useCurrentUserState(): CurrentUserState {
  const shared = useSharedSession();
  if (shared) return shared;
  // No boundary above: treat the session as still loading rather than
  // reporting a signed-out user, which would bounce the app to /login.
  return { user: null, isPending: true };
}

export function useCurrentUser(): AppUser | null {
  return useCurrentUserState().user;
}
