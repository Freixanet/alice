import {
  createJSONStorage,
  type StateStorage,
  type StorageValue,
} from "zustand/middleware";

/** Avoid serializing all conversation history for a change to transient state.
 * Zustand partializes each update, including typing and connection probes.
 * Persisted state uses immutable updates; compare its field references first.
 */
export function createSelectiveJSONStorage<S extends object>(
  getStorage: () => StateStorage,
  scope: () => string | null,
) {
  const storage = createJSONStorage<S>(getStorage);
  if (!storage) return undefined;
  let last:
    | {
        name: string;
        scope: string | null;
        value: StorageValue<S>;
        completion: Promise<void>;
      }
    | undefined;
  return {
    getItem(name: string) {
      last = undefined;
      return storage.getItem(name);
    },
    setItem(name: string, value: StorageValue<S>) {
      const account = scope();
      if (
        last &&
        last.name === name &&
        last.scope === account &&
        last.value.version === value.version &&
        sameFields(last.value.state, value.state)
      ) {
        return last.completion;
      }
      const entry = {
        name,
        scope: account,
        value,
        completion: Promise.resolve(),
      };
      // A synchronous failure must not cache a state that was never saved.
      const result = storage.setItem(name, value);
      last = entry;
      entry.completion = Promise.resolve(result)
        .then(() => undefined)
        .catch((error: unknown) => {
          if (last === entry) last = undefined;
          throw error;
        });
      return entry.completion;
    },
    removeItem(name: string) {
      last = undefined;
      return storage.removeItem(name);
    },
  };
}

function sameFields(left: object, right: object): boolean {
  const entries = Object.entries(left);
  const candidate = right as Record<string, unknown>;
  return (
    entries.length === Object.keys(right).length &&
    entries.every(
      ([key, value]) =>
        Object.hasOwn(candidate, key) && Object.is(value, candidate[key]),
    )
  );
}
