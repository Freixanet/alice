import { z } from "zod";
import {
  hermesMutationSchema,
  hermesProfileNameSchema,
} from "./hermes-operations";

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
  z.strictObject({
    action: z.literal("live"),
    profile: hermesProfileNameSchema.optional(),
  }),
  action("profiles"),
  z.strictObject({
    action: z.literal("profile-soul"),
    name: hermesProfileNameSchema,
  }),
  z.strictObject({
    action: z.literal("skill-content"),
    name: bounded(128),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("toolset-details"),
    name: bounded(128),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("system-tools"),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("mcp-catalog"),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("mcp-probe"),
    name: bounded(128),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("mcp-oauth-start"),
    name: bounded(128),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("mcp-oauth-status"),
    flowId: bounded(256),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("mcp-usage"),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("skills-search"),
    query: bounded(256),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("action-status"),
    name: bounded(256),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("mutate"),
    profile: hermesProfileNameSchema.optional(),
    mutation: hermesMutationSchema,
  }),
  action("diagnostics"),
  z.strictObject({
    action: z.literal("session-messages"),
    sessionId: bounded(160),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("models"),
    refresh: z.boolean().optional(),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("set-model"),
    model: bounded(256),
    provider: optionalBounded(128),
    conversationId: optionalBounded(128),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("run-status"),
    runId: bounded(160),
    conversationId: optionalBounded(128),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("run-stop"),
    runId: bounded(160),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("run-approval"),
    runId: bounded(160),
    choice: z.enum(["once", "session", "always", "deny"]),
    resolveAll: z.boolean().optional(),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("run-steer"),
    runId: bounded(160),
    input: bounded(8_000),
    profile: hermesProfileNameSchema.optional(),
  }),
  z.strictObject({
    action: z.literal("custom-endpoint"),
    endpointName: optionalBounded(64),
    endpointUrl: bounded(512),
    endpointKey: z.string().max(512).optional(),
    endpointModel: optionalBounded(256),
    profile: hermesProfileNameSchema.optional(),
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
  hermesSessionId: bounded(160).optional(),
  preferRuns: z.boolean().optional(),
  runIdempotency: z.boolean().optional(),
  profile: hermesProfileNameSchema.optional(),
});

export type HermesRequest = z.infer<typeof hermesRequestSchema>;
export type ChatRequest = z.infer<typeof chatRequestSchema>;
