import type { ChatEvent } from "./gateway-contracts";
import type { HermesRunStatus } from "./gateway-contracts";
import type { Message, MessagePatch } from "./types";
import { uid } from "./utils";

export type ChatStreamAccumulator = {
  content: string;
  tools: NonNullable<Message["tools"]>;
  runStatus?: HermesRunStatus;
  modelFallbackSeen?: boolean;
};

export type ChatStreamReduction = {
  patch: MessagePatch;
  stop: boolean;
  activeRun?: { runId: string; terminal: boolean };
};

export function reduceChatStreamEvent(
  accumulator: ChatStreamAccumulator,
  event: ChatEvent,
  createId: () => string = uid,
): ChatStreamReduction {
  if (event.type === "delta") {
    const chunk = accumulator.content
      ? event.text
      : event.text.replace(/^\s+/, "");
    if (!chunk) return { patch: {}, stop: false };
    accumulator.content += chunk;
    return {
      patch: {
        content: accumulator.content,
        pending: true,
        ...(!accumulator.modelFallbackSeen ? { modelFallback: undefined } : {}),
      },
      stop: false,
    };
  }

  if (event.type === "tool") {
    mergeToolEvent(accumulator.tools, event, createId);
    return {
      patch: {
        tools: [...accumulator.tools],
        pending: true,
        ...(!accumulator.modelFallbackSeen ? { modelFallback: undefined } : {}),
      },
      stop: false,
    };
  }

  if (event.type === "run") {
    accumulator.runStatus = event.status;
    if (event.output !== undefined) accumulator.content = event.output;
    const terminal =
      event.status === "completed" ||
      event.status === "failed" ||
      event.status === "cancelled";
    return {
      patch: {
        runId: event.runId,
        runStatus: event.status,
        ...(event.output !== undefined ? { content: event.output } : {}),
        pending: !terminal,
        ...(event.status === "cancelled" ? { incomplete: true } : {}),
        ...(event.status === "running" || terminal
          ? { approval: undefined }
          : {}),
        ...(!accumulator.modelFallbackSeen ? { modelFallback: undefined } : {}),
      },
      stop: false,
      activeRun: { runId: event.runId, terminal },
    };
  }

  if (event.type === "approval") {
    return {
      patch: {
        runId: event.runId,
        runStatus: "waiting_for_approval",
        pending: true,
        approval: {
          title: event.title,
          ...(event.detail === undefined ? {} : { detail: event.detail }),
          ...(event.command === undefined ? {} : { command: event.command }),
          choices: event.choices,
        },
        ...(!accumulator.modelFallbackSeen ? { modelFallback: undefined } : {}),
      },
      stop: false,
      activeRun: { runId: event.runId, terminal: false },
    };
  }

  if (event.type === "model-fallback") {
    accumulator.modelFallbackSeen = true;
    const { type: _type, ...modelFallback } = event;
    return {
      patch: { modelFallback, pending: true },
      stop: false,
    };
  }

  return {
    patch: {
      pending: false,
      error: event.message,
      ...(event.limit ? { errorLimit: event.limit } : {}),
      incomplete: undefined,
      content: accumulator.content || event.message,
      ...(!accumulator.modelFallbackSeen ? { modelFallback: undefined } : {}),
    },
    stop: true,
  };
}

function mergeToolEvent(
  tools: NonNullable<Message["tools"]>,
  event: Extract<ChatEvent, { type: "tool" }>,
  createId: () => string,
) {
  if (event.status === "start" && event.callId) {
    const existing = tools.find((tool) => tool.callId === event.callId);
    if (existing) {
      if (event.detail) existing.detail = event.detail;
      return;
    }
  }
  if (event.type === "tool" && event.status === "done") {
    const running = [...tools]
      .reverse()
      .find(
        (tool) =>
          tool.status === "start" &&
          (event.callId
            ? tool.callId === event.callId
            : tool.name === event.name),
      );
    if (running) {
      running.status = "done";
      if (event.detail) running.detail = event.detail;
      return;
    }
  }
  tools.push({
    id: createId(),
    name: event.name,
    status: event.status,
    ...(event.callId === undefined ? {} : { callId: event.callId }),
    ...(event.detail === undefined ? {} : { detail: event.detail }),
  });
}
