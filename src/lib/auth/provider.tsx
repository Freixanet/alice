import { useEffect, type ReactNode } from "react";
import { setCockpitIdentity } from "./cockpit-user";
import { useCurrentUser } from "./use-current-user";
import {
  gatewayRestoreDelay,
  readHermesGateStatus,
  savedGatewayFromStatus,
} from "../hermes-connection";
import {
  loadSavedDeviceConnection,
  setDeviceSessionKey,
} from "../hermes-direct";
import { clearHermesLiveCache } from "../hermes-live-cache";
import { resetHermesAccountState, useHermes } from "../store";

let identityGeneration = 0;
let hydrationQueue = Promise.resolve();

function prepareIdentity(id: string | null, owner: boolean) {
  identityGeneration += 1;
  clearHermesLiveCache();
  setCockpitIdentity({ id: null, owner: false });
  resetHermesAccountState();
  setCockpitIdentity({ id, owner });
  return identityGeneration;
}

function hydratePreparedIdentity(generation: number) {
  hydrationQueue = hydrationQueue
    .catch(() => undefined)
    .then(async () => {
      if (generation !== identityGeneration) return;
      await useHermes.persist.rehydrate();
    })
    .catch(() => {
      if (generation === identityGeneration) {
        useHermes.getState().setHydrated();
      }
    });
  return hydrationQueue;
}

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
    const generation = prepareIdentity(userId, isDevFallback);
    if (!userId) {
      setDeviceSessionKey(null);
      useHermes.getState().setHydrated();
      return;
    }
    setCockpitIdentity({ id: userId, owner: isDevFallback });
    const ctrl = new AbortController();
    let retryTimer: number | undefined;
    let hydrated = false;

    async function hydrateOnce() {
      if (hydrated) return;
      hydrated = true;
      await hydratePreparedIdentity(generation);
    }

    async function restore(attempt: number) {
      try {
        const data = await readHermesGateStatus(ctrl.signal);
        if (ctrl.signal.aborted) return;
        setCockpitIdentity({ id: userId, owner: data.owner });
        const saved = savedGatewayFromStatus(data);
        if (saved?.place === "device") {
          await loadSavedDeviceConnection({
            url: saved.url,
            signal: ctrl.signal,
          });
        }
        if (ctrl.signal.aborted) return;
        await hydrateOnce();
        if (ctrl.signal.aborted || !saved) return;
        const state = useHermes.getState();
        if (
          !state.gatewayOn ||
          !state.gatewayUrl ||
          state.gatewayUrl !== saved.url ||
          state.gatewayPlace !== saved.place
        ) {
          state.restoreGateway(saved);
        }
      } catch {
        if (ctrl.signal.aborted) return;
        await hydrateOnce();
        if (ctrl.signal.aborted) return;
        retryTimer = window.setTimeout(
          () => void restore(attempt + 1),
          gatewayRestoreDelay(attempt),
        );
      }
    }

    void restore(0);
    return () => {
      ctrl.abort();
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
    };
  }, [userId, isDevFallback]);

  return <>{children}</>;
}
