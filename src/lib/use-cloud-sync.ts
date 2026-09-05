import { useEffect } from "react";
import { useCurrentUser } from "./auth/use-current-user";
import {
  applyMergedReplicaState,
  bootstrapSyncQueue,
  buildLocalReplica,
  clearPendingDeletedThrough,
  clearPendingThrough,
  loadSyncAccountState,
  queueLocalConversationChanges,
  resetCloudSyncRuntimeStatus,
  setCloudSyncRuntimeStatus,
  syncBackoffDelay,
} from "./cloud-sync-runtime";
import { loadMasterSecretForDevice } from "./sync-device-key";
import { SyncKeyMismatchError } from "./sync-client";
import {
  CloudSyncHttpError,
  CloudSyncNetworkError,
  CloudSyncQuotaError,
  pullConversationReplicas,
  pushConversationReplicas,
  type RemoteReplicaRecord,
} from "./sync-runtime-client";
import { mergeConversationReplicas } from "./sync-replica";
import { seedBlankChat, useHermes } from "./store";
import { uid } from "./utils";

const REMOTE_POLL_MS = 30_000;
const TERMINAL_RECHECK_MS = 60_000;
const LOCAL_DEBOUNCE_MS = 750;

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

/** The connection as it is now, past any narrowing of an earlier check. */
function isOffline(): boolean {
  return typeof navigator !== "undefined" && navigator.onLine === false;
}

export function useCloudSync() {
  const user = useCurrentUser();
  const accountId = user?.id;
  const enabled = useHermes((state) => state.cloudSyncEnabled);

  useEffect(() => {
    // A string by declaration, not by inference. The account id is optional
    // out in the component, and a narrowing made there does not reach inside
    // `run()` — a function declared now and called later — so every use in it
    // was `string | undefined` and the file did not typecheck. The build
    // passed regardless: Vite strips types rather than checking them, so
    // `tsc` was the only thing that ever saw this.
    //
    // Empty stands for absent, and the guard below turns it away, so the
    // dependency list can keep watching the id rather than the user object,
    // which is a new reference on every render.
    const userId: string = accountId ?? "";
    if (!enabled || !userId) {
      resetCloudSyncRuntimeStatus();
      return;
    }

    const controller = new AbortController();
    let timer: number | undefined;
    let running = false;
    let rerun = false;
    let applyingRemote = false;
    let retryAttempt = 0;

    const schedule = (delay: number) => {
      if (controller.signal.aborted) return;
      if (timer !== undefined) window.clearTimeout(timer);
      timer = window.setTimeout(() => void run(), Math.max(0, delay));
    };

    const kick = (delay = LOCAL_DEBOUNCE_MS) => {
      if (controller.signal.aborted) return;
      if (running) {
        rerun = true;
        return;
      }
      schedule(delay);
    };

    const applyRemote = (remote: RemoteReplicaRecord[], cursor: string) => {
      if (!remote.length) {
        applyingRemote = true;
        try {
          useHermes.setState((state) => ({
            syncCursors: { ...state.syncCursors, [userId]: cursor },
          }));
        } finally {
          applyingRemote = false;
        }
        return;
      }

      const current = useHermes.getState();
      const byId = new Map(
        current.conversations.map((item) => [item.id, item]),
      );
      const nextTombstones = { ...current.conversationTombstones };
      const grouped = new Map<string, RemoteReplicaRecord[]>();
      for (const record of remote) {
        const list = grouped.get(record.id) ?? [];
        list.push(record);
        grouped.set(record.id, list);
      }

      for (const [conversationId, records] of grouped) {
        const local = byId.get(conversationId);
        let replica = local ? buildLocalReplica(userId, local) : null;
        let deletedAt = nextTombstones[conversationId] ?? 0;

        for (const record of records) {
          if (record.type === "tombstone") {
            deletedAt = Math.max(deletedAt, record.updatedAt);
          } else {
            replica = replica
              ? mergeConversationReplicas(replica, record.replica)
              : record.replica;
          }
        }

        if (replica && replica.updatedAt > deletedAt) {
          byId.set(conversationId, replica.conversation);
          delete nextTombstones[conversationId];
          applyMergedReplicaState(userId, replica);
        } else if (deletedAt > 0) {
          byId.delete(conversationId);
          nextTombstones[conversationId] = deletedAt;
          clearPendingDeletedThrough(userId, conversationId, deletedAt);
        }
      }

      const next = [...byId.values()].sort((a, b) => b.updatedAt - a.updatedAt);
      const list = next.length
        ? next
        : [{ ...seedBlankChat(), id: uid(), title: "New chat" }];

      applyingRemote = true;
      try {
        useHermes.setState((state) => ({
          conversations: list,
          conversationTombstones: nextTombstones,
          activeId: byId.has(state.activeId) ? state.activeId : list[0]!.id,
          syncCursors: { ...state.syncCursors, [userId]: cursor },
        }));
      } finally {
        applyingRemote = false;
      }
    };

    const unsubscribe = useHermes.subscribe((state, previous) => {
      if (applyingRemote || state.conversations === previous.conversations)
        return;
      queueLocalConversationChanges({
        userId,
        previous: previous.conversations,
        next: state.conversations,
        tombstones: state.conversationTombstones,
      });
      setCloudSyncRuntimeStatus(userId, "pending");
      kick();
    });

    const onOnline = () => {
      retryAttempt = 0;
      setCloudSyncRuntimeStatus(userId, "pending");
      kick(0);
    };
    const onOffline = () => setCloudSyncRuntimeStatus(userId, "offline");
    const onFocus = () => kick(0);
    const onVisibility = () => {
      if (document.visibilityState === "visible") kick(0);
    };

    window.addEventListener("online", onOnline);
    window.addEventListener("offline", onOffline);
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibility);

    async function run() {
      if (controller.signal.aborted) return;
      if (running) {
        rerun = true;
        return;
      }
      if (navigator.onLine === false) {
        setCloudSyncRuntimeStatus(userId, "offline");
        schedule(REMOTE_POLL_MS);
        return;
      }

      running = true;
      rerun = false;
      const before = loadSyncAccountState(userId);
      setCloudSyncRuntimeStatus(
        userId,
        Object.keys(before.pending).length ? "pending" : "syncing",
      );

      try {
        const master = await loadMasterSecretForDevice(userId);
        controller.signal.throwIfAborted();
        if (!master) throw new SyncKeyMismatchError();

        // Always read first. Besides making a wrong key fail before any write,
        // this merges another device's work into the local replica before a
        // pending local snapshot is encrypted and uploaded.
        const localState = useHermes.getState();
        const pulled = await pullConversationReplicas({
          userId,
          master,
          cursor: localState.syncCursors[userId],
          signal: controller.signal,
        });
        controller.signal.throwIfAborted();
        applyRemote(pulled.remote, pulled.cursor);

        const afterPull = useHermes.getState();
        bootstrapSyncQueue({
          userId,
          conversations: afterPull.conversations,
          tombstones: afterPull.conversationTombstones,
        });

        const account = loadSyncAccountState(userId);
        const latest = useHermes.getState();
        const conversations = new Map(
          latest.conversations.map((conversation) => [
            conversation.id,
            conversation,
          ]),
        );
        const replicas = [];
        const deletions: Array<{ id: string; updatedAt: number }> = [];
        const sent: Record<string, number> = {};

        for (const [id, pending] of Object.entries(account.pending)) {
          controller.signal.throwIfAborted();
          if (pending.tombstone) {
            deletions.push({ id, updatedAt: pending.version });
            sent[id] = pending.version;
            continue;
          }
          const conversation = conversations.get(id);
          if (!conversation) continue;
          const replica = buildLocalReplica(userId, conversation);
          replica.updatedAt = Math.max(replica.updatedAt, pending.version);
          replicas.push(replica);
          sent[id] = pending.version;
        }

        await pushConversationReplicas({
          userId,
          master,
          replicas,
          deletions,
          signal: controller.signal,
        });
        controller.signal.throwIfAborted();

        const completedAt = Date.now();
        clearPendingThrough(userId, sent, completedAt);
        retryAttempt = 0;
        const remaining = loadSyncAccountState(userId);
        if (Object.keys(remaining.pending).length) {
          setCloudSyncRuntimeStatus(userId, "pending");
          schedule(0);
        } else {
          setCloudSyncRuntimeStatus(userId, "synced");
          schedule(REMOTE_POLL_MS);
        }
      } catch (error) {
        if (isAbortError(error) || controller.signal.aborted) return;

        retryAttempt += 1;
        if (error instanceof SyncKeyMismatchError) {
          setCloudSyncRuntimeStatus(userId, "key-mismatch");
          schedule(TERMINAL_RECHECK_MS);
        } else if (error instanceof CloudSyncQuotaError) {
          setCloudSyncRuntimeStatus(userId, "quota-exceeded");
          schedule(TERMINAL_RECHECK_MS);
        } else if (
          error instanceof CloudSyncNetworkError ||
          // Read again, not remembered. `run()` checks this on the way in and
          // the compiler took that check as settled for the rest of the
          // function — but a device can lose its connection during the very
          // request being handled here, which is the case this branch is for.
          isOffline()
        ) {
          setCloudSyncRuntimeStatus(userId, "offline");
          schedule(syncBackoffDelay(retryAttempt - 1));
        } else if (
          error instanceof CloudSyncHttpError &&
          error.status === 429
        ) {
          setCloudSyncRuntimeStatus(userId, "pending");
          schedule(syncBackoffDelay(retryAttempt - 1));
        } else {
          setCloudSyncRuntimeStatus(userId, "error");
          schedule(syncBackoffDelay(retryAttempt - 1));
        }
      } finally {
        running = false;
        if (rerun && !controller.signal.aborted) schedule(0);
      }
    }

    setCloudSyncRuntimeStatus(userId, "pending");
    schedule(0);

    return () => {
      controller.abort();
      unsubscribe();
      if (timer !== undefined) window.clearTimeout(timer);
      window.removeEventListener("online", onOnline);
      window.removeEventListener("offline", onOffline);
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [accountId, enabled]);
}
