import { z } from "zod";

const bounded = (max: number) => z.string().trim().min(1).max(max);
const optionalBounded = (max: number) => z.string().trim().max(max).optional();

const action = <T extends string>(name: T) =>
  z.strictObject({ action: z.literal(name) });

export const hermesRequestSchema = z.discriminatedUnion("action", [
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
    action: z.literal("toggle-skill"),
    name: bounded(128),
    enabled: z.boolean(),
  }),
  z.strictObject({
    action: z.literal("toggle-toolset"),
    name: bounded(128),
    enabled: z.boolean(),
  }),
  z.strictObject({
    action: z.literal("toggle-mcp"),
    name: bounded(128),
    enabled: z.boolean(),
  }),
  z.strictObject({
    action: z.literal("cron-pause"),
    jobId: bounded(128),
  }),
  z.strictObject({
    action: z.literal("cron-resume"),
    jobId: bounded(128),
  }),
  z.strictObject({
    action: z.literal("cron-create"),
    prompt: bounded(8_000),
    schedule: bounded(256),
  }),
  z.strictObject({
    action: z.literal("project-create"),
    path: bounded(1_024),
    description: optionalBounded(2_000),
  }),
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
});

export type HermesRequest = z.infer<typeof hermesRequestSchema>;
export type ChatRequest = z.infer<typeof chatRequestSchema>;
