import { whenDefined } from "./exact-optional";

export type HermesRoomMember = {
  id: string;
  profile: string;
  handle: string;
};

export type HermesRoom = {
  id: string;
  name: string;
  members: HermesRoomMember[];
  updatedAt?: number;
  latestSeq: number;
  disbanded: boolean;
};

export type HermesRoomsResult =
  | { ok: true; supported: boolean; rooms: HermesRoom[] }
  | { ok: false; error: string };

export type HermesRoomMutationResult =
  | { ok: true; room?: HermesRoom; accepted?: boolean }
  | { ok: false; error: string };

export type HermesRoomEvent = {
  seq: number;
  kind: string;
  actor: string;
  text: string;
  createdAt?: number;
};

export type HermesRoomLogResult =
  | { ok: true; events: HermesRoomEvent[]; cursor: number; hasMore: boolean }
  | { ok: false; error: string };

export function roomLogFromRpc(
  raw: unknown,
): Omit<HermesRoomLogResult & { ok: true }, "ok"> | null {
  const root = record(raw);
  if (!root) return null;
  const events = list(root.events)
    .map((value) => {
      const event = record(value);
      const payload = record(event?.payload);
      const actor = record(event?.actor);
      const seq = finite(event?.seq);
      const kind = text(event?.kind);
      if (!seq || !kind) return null;
      const createdAt = finite(event?.created_at);
      return {
        seq,
        kind,
        actor:
          text(actor?.display_name) ||
          text(actor?.profile) ||
          text(actor?.id) ||
          text(actor?.kind) ||
          "Hermes",
        text: text(payload?.text) || text(payload?.error) || kind,
        ...(createdAt ? { createdAt } : {}),
      };
    })
    .filter((event): event is HermesRoomEvent => event !== null);
  return {
    events,
    cursor: finite(root.cursor),
    hasMore: root.has_more === true,
  };
}

export function roomsFromRpc(raw: unknown): HermesRoom[] {
  const root = record(raw);
  return list(root?.rooms)
    .map(roomFromRpc)
    .filter((room): room is HermesRoom => room !== null)
    .slice(0, 100);
}

export function roomFromRpc(raw: unknown): HermesRoom | null {
  const row = record(raw);
  const id = text(row?.room_id);
  if (!id) return null;
  return {
    id,
    name: text(row?.name) || id,
    members: list(row?.members)
      .map((value) => {
        const member = record(value);
        const profile = text(member?.profile);
        if (!profile) return null;
        return {
          id: text(member?.member_id) || profile,
          profile,
          handle: text(member?.handle) || profile,
        };
      })
      .filter((member): member is HermesRoomMember => member !== null),
    ...whenDefined("updatedAt", finite(row?.updated_at) || undefined),
    latestSeq: finite(row?.latest_seq),
    disbanded: row?.disbanded_at !== null && row?.disbanded_at !== undefined,
  };
}

export async function hermesGatewayRpcDirect(opts: {
  url: string;
  key: string;
  method: string;
  params?: Record<string, unknown>;
  profile?: string;
  signal?: AbortSignal;
}): Promise<unknown> {
  const base = new URL(opts.url);
  base.protocol = base.protocol === "https:" ? "wss:" : "ws:";
  base.pathname = `${base.pathname.replace(/\/$/, "")}/api/ws`;
  base.search = "";
  base.searchParams.set("token", opts.key);
  if (opts.profile) base.searchParams.set("profile", opts.profile);
  return rpcOverSocket(base.toString(), opts.method, opts.params, opts.signal);
}

export function rpcOverSocket(
  url: string,
  method: string,
  params: Record<string, unknown> = {},
  signal?: AbortSignal,
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID();
    const socket = new WebSocket(url);
    let settled = false;
    const timeout = window.setTimeout(
      () => finish(new Error("Hermes RPC timed out.")),
      8_000,
    );

    function finish(error?: Error, value?: unknown) {
      if (settled) return;
      settled = true;
      window.clearTimeout(timeout);
      signal?.removeEventListener("abort", abort);
      socket.close();
      if (error) reject(error);
      else resolve(value);
    }

    function abort() {
      finish(new DOMException("Aborted", "AbortError"));
    }

    signal?.addEventListener("abort", abort, { once: true });
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
    socket.addEventListener("message", (event) => {
      try {
        const body = JSON.parse(String(event.data)) as Record<string, unknown>;
        if (body.id !== id) return;
        const error = record(body.error);
        if (error) {
          finish(
            new Error(text(error.message) || "Hermes rejected the request."),
          );
          return;
        }
        finish(undefined, body.result);
      } catch {
        // Events and unrelated frames are expected on this socket.
      }
    });
    socket.addEventListener("error", () =>
      finish(new Error("Couldn’t open the Hermes realtime gateway.")),
    );
  });
}

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function finite(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
