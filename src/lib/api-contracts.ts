import { z } from "zod";
import { hermesMutationSchema } from "./hermes-operations";

const bounded = (max: number) => z.string().trim().min(1).max(max);
const optionalBounded = (max: number) => z.string().trim().max(max).optional();

const action = <T extends string>(name: T) =>
  z.strictObject({ action: z.literal(name) });

const hermesControlRequestSchema = z.discriminatedUnion("action", [
  action("status"),
  action("device-secret"),
  z.strictObject({
    action: z.literal("store-device"),
    url: bounded(512),
    key: bounded(256),
  }),
  action("forget"),
  action("memory"),
  action("live"),
  z.strictObject({
    action: z.literal("models"),
    refresh: z.boolean().optional(),
  }),
  z.strictObject({
    action: z.literal("set-model"),
    model: bounded(256),
    provider: optionalBounded(128),
    conversationId: optionalBounded(128),
  }),
  z.strictObject({
    action: z.literal("run-status"),
    runId: bounded(160),
    conversationId: optionalBounded(128),
  }),
  z.strictObject({
    action: z.literal("run-stop"),
    runId: bounded(160),
  }),
  z.strictObject({
    action: z.literal("run-approval"),
    runId: bounded(160),
    choice: z.enum(["once", "session", "always", "deny"]),
    resolveAll: z.boolean().optional(),
  }),
  z.strictObject({
    action: z.literal("run-steer"),
    runId: bounded(160),
    input: bounded(8_000),
  }),
  z.strictObject({
    action: z.literal("custom-endpoint"),
    endpointName: optionalBounded(64),
    endpointUrl: bounded(512),
    endpointKey: z.string().max(512).optional(),
    endpointModel: optionalBounded(256),
  }),
  z.strictObject({
    action: z.literal("probe"),
    url: optionalBounded(512),
    key: z.string().max(256).optional(),
    place: z.enum(["cloud", "mac"]).optional(),
  }),
  z.strictObject({
    action: z.literal("connect"),
    url: optionalBounded(512),
    key: z.string().max(256).optional(),
    place: z.enum(["cloud", "mac"]).optional(),
  }),
]);

export const hermesRequestSchema = z.union([
  hermesControlRequestSchema,
  hermesMutationSchema,
]);

const textPartSchema = z.strictObject({
  type: z.literal("text"),
  text: z.string().min(1).max(8_000),
});

const imagePartSchema = z.strictObject({
  type: z.literal("image_url"),
  image_url: z.strictObject({
    url: z
      .string()
      .max(10 * 1024 * 1024)
      .refine(
        (value) => /^data:image\//i.test(value) || /^https?:\/\//i.test(value),
        "Unsupported image URL",
      ),
    detail: z.enum(["auto", "low", "high"]).optional(),
  }),
});

const chatContentSchema = z.union([
  z.string().min(1).max(8_000),
  z
    .array(z.discriminatedUnion("type", [textPartSchema, imagePartSchema]))
    .min(1)
    .max(8),
]);

export const chatRequestSchema = z.strictObject({
  messages: z
    .array(
      z.strictObject({
        role: z.enum(["user", "assistant"]),
        content: chatContentSchema,
      }),
    )
    .min(1)
    .max(16),
  context: z.string().max(16_000).optional(),
  model: optionalBounded(256),
  provider: optionalBounded(128),
  conversationId: optionalBounded(128),
  preferRuns: z.boolean().optional(),
});

export type HermesRequest = z.infer<typeof hermesRequestSchema>;
export type ChatRequest = z.infer<typeof chatRequestSchema>;
