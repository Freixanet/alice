import type {
  ChatEvent,
  HermesApprovalChoice,
  HermesChatContent,
  HermesRunStatus,
} from "./gateway-contracts";

export type HermesRunTurn = {
  role: "user" | "assistant";
  content: HermesChatContent;
};

export type HermesRunSnapshot = {
  runId: string;
  status: HermesRunStatus;
  output?: string;
  error?: string;
};

const RUN_STATUSES = new Set<HermesRunStatus>([
  "started",
  "queued",
  "running",
  "waiting_for_approval",
  "stopping",
  "completed",
  "failed",
  "cancelled",
]);

const APPROVAL_CHOICES = new Set<HermesApprovalChoice>([
  "once",
  "session",
  "always",
  "deny",
]);

export function buildHermesRunRequest(opts: {
  messages: HermesRunTurn[];
  conversationId?: string;
  model?: string;
  provider?: string;
}): Record<string, unknown> | null {
  let userIndex = -1;
  for (let index = opts.messages.length - 1; index >= 0; index -= 1) {
    if (opts.messages[index]?.role === "user") {
      userIndex = index;
      break;
    }
  }
  const current = opts.messages[userIndex];
  if (!current) return null;
  const model = bounded(opts.model, 256);
  const provider = bounded(opts.provider, 128);
  const sessionId = bounded(opts.conversationId, 128);
  return {
    input: current.content,
    conversation_history: opts.messages.slice(0, userIndex),
    ...(sessionId ? { session_id: sessionId } : {}),
    ...(model ? { model } : {}),
    ...(provider ? { provider } : {}),
  };
}

export function parseHermesRunStart(value: unknown): HermesRunSnapshot | null {
  const record = asRecord(value);
  const runId = bounded(record?.run_id, 160);
  if (!runId) return null;
  return {
    runId,
    status: runStatus(record?.status) ?? "started",
  };
}

export function parseHermesRunSnapshot(
  value: unknown,
): HermesRunSnapshot | null {
  const record = asRecord(value);
  const runId = bounded(record?.run_id, 160);
  const status = runStatus(record?.status);
  if (!runId || !status) return null;
  const output = limitedText(record?.output, 1_000_000);
  const error = bounded(record?.error, 8_000);
  return {
    runId,
    status,
    ...(output ? { output } : {}),
    ...(error ? { error } : {}),
  };
}

export function eventsFromHermesRunChunk(chunk: string): ChatEvent[] {
  try {
    return eventsFromHermesRunValue(JSON.parse(chunk));
  } catch {
    return [];
  }
}

export function eventsFromHermesRunValue(value: unknown): ChatEvent[] {
  const record = asRecord(value);
  if (!record) return [];
  const event = bounded(record.event ?? record.type, 96);
  const runId = bounded(record.run_id, 160);
  if (!event || !runId) return [];

  if (event === "run.started") {
    return [{ type: "run", runId, status: "running" }];
  }

  if (event === "message.delta" || event === "assistant.delta") {
    const text = limitedText(record.delta, 1_000_000);
    return text ? [{ type: "delta", text }] : [];
  }

  if (event === "tool.started") {
    const name = bounded(record.tool ?? record.tool_name, 256);
    if (!name) return [];
    return [
      {
        type: "tool",
        name,
        status: "start",
        detail: bounded(record.preview, 8_000),
        callId: bounded(record.call_id ?? record.tool_call_id, 160),
      },
    ];
  }

  if (event === "tool.completed" || event === "tool.failed") {
    const name = bounded(record.tool ?? record.tool_name, 256);
    if (!name) return [];
    return [
      {
        type: "tool",
        name,
        status: "done",
        detail:
          bounded(record.preview, 8_000) ||
          (event === "tool.failed" || record.error === true
            ? "Tool failed"
            : undefined),
        callId: bounded(record.call_id ?? record.tool_call_id, 160),
      },
    ];
  }

  if (event === "subagent.start" || event === "subagent.complete") {
    const detail =
      bounded(record.summary, 8_000) ||
      bounded(record.goal, 8_000) ||
      bounded(record.preview, 8_000);
    return [
      {
        type: "tool",
        name: "delegate_task",
        status: event === "subagent.start" ? "start" : "done",
        detail,
        callId: bounded(record.subagent_id ?? record.child_session_id, 160),
      },
    ];
  }

  if (event === "approval.request") {
    const choices = Array.isArray(record.choices)
      ? record.choices
          .map((choice) => bounded(choice, 16))
          .filter((choice): choice is HermesApprovalChoice =>
            APPROVAL_CHOICES.has(choice as HermesApprovalChoice),
          )
      : [];
    return [
      {
        type: "run",
        runId,
        status: "waiting_for_approval",
      },
      {
        type: "approval",
        runId,
        title:
          bounded(record.tool ?? record.title, 256) || "Hermes needs approval",
        detail: bounded(
          record.description ?? record.preview ?? record.reason,
          8_000,
        ),
        command: bounded(record.command, 8_000),
        choices: choices.length ? choices : ["once", "deny"],
      },
    ];
  }

  if (event === "approval.responded" || event === "run.steered") {
    return [{ type: "run", runId, status: "running" }];
  }

  if (event === "run.completed") {
    return [
      {
        type: "run",
        runId,
        status: "completed",
        output: limitedText(record.output, 1_000_000),
      },
    ];
  }
  if (event === "run.cancelled") {
    return [{ type: "run", runId, status: "cancelled" }];
  }
  if (event === "run.failed") {
    const message = bounded(record.error, 8_000) || "Hermes couldn’t finish.";
    return [
      { type: "run", runId, status: "failed" },
      { type: "error", message },
    ];
  }

  return [];
}

export function eventsFromHermesRunSnapshot(
  snapshot: HermesRunSnapshot,
): ChatEvent[] {
  const events: ChatEvent[] = [
    {
      type: "run",
      runId: snapshot.runId,
      status: snapshot.status,
      output: snapshot.output,
    },
  ];
  if (snapshot.status === "failed") {
    events.push({
      type: "error",
      message: snapshot.error || "Hermes couldn’t finish.",
    });
  }
  return events;
}

export function isTerminalHermesRunStatus(status: HermesRunStatus): boolean {
  return (
    status === "completed" || status === "failed" || status === "cancelled"
  );
}

function runStatus(value: unknown): HermesRunStatus | null {
  const status = bounded(value, 32) as HermesRunStatus;
  return RUN_STATUSES.has(status) ? status : null;
}

function bounded(value: unknown, max: number): string | undefined {
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, max)
    : undefined;
}

function limitedText(value: unknown, max: number): string | undefined {
  return typeof value === "string" && value.length
    ? value.slice(0, max)
    : undefined;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}
