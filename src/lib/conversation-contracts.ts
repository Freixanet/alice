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

export const conversationSchema = z.strictObject({
  id: z.string().min(1).max(160),
  title: z.string().max(512),
  createdAt: z.number().int().nonnegative().safe(),
  updatedAt: z.number().int().nonnegative().safe(),
  pinned: z.boolean().optional(),
  messages: z
    .array(
      z.strictObject({
        id: z.string().min(1).max(160),
        role: z.enum(["user", "assistant"]),
        content: z.string().max(1_000_000),
        createdAt: z.number().int().nonnegative().safe(),
        pending: z.boolean().optional(),
        error: z.string().max(8_000).optional(),
        incomplete: z.boolean().optional(),
        attachments: z.array(attachmentSchema).max(8).optional(),
        tools: z.array(toolSchema).max(256).optional(),
      }),
    )
    .max(20_000),
});
