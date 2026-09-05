import { useEffect } from "react";
import { useCurrentUser } from "./auth/use-current-user";
import { loadMasterSecretForDevice } from "./sync-device-key";
import { syncEncryptedConversations } from "./sync-client";
import { seedBlankChat, useHermes } from "./store";
import { uid } from "./utils";

export function useCloudSync() {
  const user = useCurrentUser();
  const enabled = useHermes((state) => state.cloudSyncEnabled);
  const conversations = useHermes((state) => state.conversations);
  const tombstones = useHermes((state) => state.conversationTombstones);

  useEffect(() => {
    if (!enabled || !user) return;
    const controller = new AbortController();
    const timeout = window.setTimeout(() => {
      void loadMasterSecretForDevice(user.id)
        .then(async (master) => {
          if (controller.signal.aborted) return;
          if (!master) {
            useHermes.getState().setCloudSyncEnabled(false);
            return;
          }
          const { remote, cursor } = await syncEncryptedConversations({
            userId: user.id,
            master,
            conversations,
            tombstones,
            cursor: useHermes.getState().syncCursors[user.id],
            signal: controller.signal,
          });
          // Aborted: the records were never applied, so the position must not
          // move either.
          if (controller.signal.aborted) return;
          // Nothing to apply, but the walk did finish: keep the position so
          // the next run does not re-read pages it has already caught up with.
          if (!remote.length) {
            useHermes.setState((state) => ({
              syncCursors: { ...state.syncCursors, [user.id]: cursor },
            }));
            return;
          }
          useHermes.setState((state) => {
            const byId = new Map(
              state.conversations.map((item) => [item.id, item]),
            );
            const nextTombstones = { ...state.conversationTombstones };
            for (const item of remote) {
              if (item.tombstone) {
                const current = byId.get(item.id);
                if (!current || current.updatedAt <= item.updatedAt)
                  byId.delete(item.id);
                nextTombstones[item.id] = Math.max(
                  nextTombstones[item.id] ?? 0,
                  item.updatedAt,
                );
              } else {
                const deletedAt = nextTombstones[item.id] ?? 0;
                const current = byId.get(item.id);
                if (
                  item.conversation.updatedAt > deletedAt &&
                  (!current || item.conversation.updatedAt > current.updatedAt)
                ) {
                  byId.set(item.id, item.conversation);
                  delete nextTombstones[item.id];
                }
              }
            }
            const next = [...byId.values()].sort(
              (a, b) => b.updatedAt - a.updatedAt,
            );
            // A deletion that empties the list is still a deletion. Returning
            // the old state here kept the conversation another device had
            // deleted — and threw away the tombstones that recorded it — so a
            // device holding only that one went on showing it for ever. The
            // interface wants a conversation to exist; the way to give it one
            // is a new one, as deleting the last chat by hand already does.
            const list = next.length
              ? next
              : [{ ...seedBlankChat(), id: uid(), title: "New chat" }];
            return {
              conversations: list,
              conversationTombstones: nextTombstones,
              activeId: byId.has(state.activeId) ? state.activeId : list[0]!.id,
              // In the same update as the records it describes. Both are
              // persisted together, so IndexedDB either has the conversations
              // and the position that accounts for them, or has neither —
              // never a position for records that were lost on the way.
              syncCursors: { ...state.syncCursors, [user.id]: cursor },
            };
          });
        })
        .catch(() => undefined);
    }, 1_000);
    return () => {
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [conversations, enabled, tombstones, user]);
}
