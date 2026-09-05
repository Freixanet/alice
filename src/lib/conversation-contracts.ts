import { z } from "zod";

const attachmentSchema = z.strictObject({
  id: z.string().min(1).max(160),
  name: z.string().max(512),
  mime: z.string().max(256),
  kind: z.enum(["image", "file"]),
  dataUrl: z.string().max(14_000_000).optional(),
});

const toolSchema = z.strictObject({
  id: z.string().min(1).max(160),
  callId: z.string().max(160).optional(),
  name: z.string().max(256),
  status: z.enum(["start", "done"]),
  detail: z.string().max(8_000).optional(),
});

const runStatusSchema = z.enum([
  "started",
  "queued",
  "running",
  "waiting_for_approval",
  "stopping",
  "completed",
  "failed",
  "cancelled",
]);

const approvalSchema = z.strictObject({
  title: z.string().min(1).max(256),
  detail: z.string().max(8_000).optional(),
  command: z.string().max(8_000).optional(),
  choices: z.array(z.enum(["once", "session", "always", "deny"])).max(4),
  resolving: z.boolean().optional(),
  error: z.string().max(8_000).optional(),
});

const modelLimitSchema = z.strictObject({
  kind: z.enum(["quota", "rateLimit", "auth"]),
  retryAfterSeconds: z.number().nonnegative().finite().optional(),
  scope: z.string().max(256).optional(),
});

export const conversationSchema = z.strictObject({
  id: z.string().min(1).max(160),
  title: z.string().max(512),
  createdAt: z.number().int().nonnegative().safe(),
  updatedAt: z.number().int().nonnegative().safe(),
  pinned: z.boolean().optional(),
  hermesSessionId: z.string().trim().min(1).max(160).optional(),
  hermesProfile: z.string().trim().min(1).max(160).optional(),
  messages: z
    .array(
      z.strictObject({
        id: z.string().min(1).max(160),
        role: z.enum(["user", "assistant"]),
        content: z.string().max(1_000_000),
        createdAt: z.number().int().nonnegative().safe(),
        pending: z.boolean().optional(),
        error: z.string().max(8_000).optional(),
        errorLimit: modelLimitSchema.optional(),
        incomplete: z.boolean().optional(),
        runId: z.string().min(1).max(160).optional(),
        runStatus: runStatusSchema.optional(),
        approval: approvalSchema.optional(),
        attachments: z.array(attachmentSchema).max(8).optional(),
        tools: z.array(toolSchema).max(256).optional(),
      }),
    )
    .max(20_000),
});
