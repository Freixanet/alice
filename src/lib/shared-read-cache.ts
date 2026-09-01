type CacheEntry<T> = { value: T; updatedAt: number };

type PendingRead<T> = {
  controller: AbortController;
  promise: Promise<T>;
  subscribers: number;
  settled: boolean;
};

export type SharedReadOptions = {
  force?: boolean;
  signal?: AbortSignal;
  now?: number;
};

function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("Aborted", "AbortError");
}

function settleWithAbort<T>(
  promise: Promise<T>,
  signal: AbortSignal,
): Promise<T> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(abortReason(signal));
      return;
    }
    const onAbort = () => reject(abortReason(signal));
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener("abort", onAbort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}

/**
 * Deduplicates idempotent reads without coupling one caller's lifetime to
 * another. The shared transport is aborted only after every subscriber leaves.
 */
export class SharedReadCache<T> {
  private readonly entries = new Map<string, CacheEntry<T>>();
  private readonly pending = new Map<string, PendingRead<T>>();

  constructor(
    private readonly ttlMs: number,
    private readonly cacheable: (value: T) => boolean = () => true,
  ) {}

  read(
    key: string,
    load: (signal: AbortSignal) => Promise<T>,
    options: SharedReadOptions = {},
  ): Promise<T> {
    if (options.signal?.aborted) {
      return Promise.reject(abortReason(options.signal));
    }
    const now = options.now ?? Date.now();
    const cached = this.entries.get(key);
    if (
      !options.force &&
      cached &&
      now - cached.updatedAt >= 0 &&
      now - cached.updatedAt < this.ttlMs
    ) {
      return Promise.resolve(cached.value);
    }

    let request = this.pending.get(key);
    if (!request) {
      const controller = new AbortController();
      const promise = Promise.resolve()
        .then(() => settleWithAbort(load(controller.signal), controller.signal))
        .then((value) => {
          if (
            !controller.signal.aborted &&
            this.pending.get(key)?.controller === controller &&
            this.cacheable(value)
          ) {
            this.entries.set(key, {
              value,
              updatedAt: options.now ?? Date.now(),
            });
          }
          return value;
        })
        .finally(() => {
          const active = this.pending.get(key);
          if (active?.controller !== controller) return;
          active.settled = true;
          this.pending.delete(key);
        });
      const created = { controller, promise, subscribers: 0, settled: false };
      this.pending.set(key, created);
      request = created;
    }
    return this.subscribe(key, request, options.signal);
  }

  invalidate(key: string): void {
    this.entries.delete(key);
    const request = this.pending.get(key);
    if (!request) return;
    this.pending.delete(key);
    request.controller.abort();
  }

  clear(): void {
    this.entries.clear();
    for (const request of this.pending.values()) request.controller.abort();
    this.pending.clear();
  }

  private subscribe(
    key: string,
    request: PendingRead<T>,
    signal?: AbortSignal,
  ): Promise<T> {
    request.subscribers += 1;
    return new Promise<T>((resolve, reject) => {
      let active = true;
      const finish = (complete: () => void) => {
        if (!active) return;
        active = false;
        signal?.removeEventListener("abort", onAbort);
        request.subscribers -= 1;
        complete();
        if (
          request.subscribers === 0 &&
          !request.settled &&
          this.pending.get(key) === request
        ) {
          request.controller.abort();
        }
      };
      const onAbort = () => finish(() => reject(abortReason(signal!)));
      signal?.addEventListener("abort", onAbort, { once: true });
      request.promise.then(
        (value) => finish(() => resolve(value)),
        (error: unknown) => finish(() => reject(error)),
      );
    });
  }
}
