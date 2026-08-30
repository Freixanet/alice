import { z } from "zod";

const name = z.string().trim().min(1).max(128);
const id = z.string().trim().min(1).max(160);
const optionalText = (max: number) => z.string().trim().max(max).optional();
const text = (max: number) => z.string().trim().min(1).max(max);
const envName = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/);

const cronCreateSchema = z
  .strictObject({
    action: z.literal("cron-create"),
    name,
    prompt: z.string().max(8_000),
    schedule: text(256),
    deliver: optionalText(128),
    skills: z.array(name).max(32).optional(),
    model: optionalText(256),
    provider: optionalText(128),
    script: optionalText(16_000),
    workdir: optionalText(1_024),
    enabledToolsets: z.array(name).max(32).optional(),
    noAgent: z.boolean().optional(),
  })
  .refine((value) => !value.noAgent || Boolean(value.script), {
    message: "Script-only jobs require a script.",
    path: ["script"],
  });

export const hermesMutationSchema = z.discriminatedUnion("action", [
  z.strictObject({
    action: z.literal("toggle-skill"),
    name,
    enabled: z.boolean(),
  }),
  z.strictObject({
    action: z.literal("toggle-toolset"),
    name,
    enabled: z.boolean(),
  }),
  z.strictObject({
    action: z.literal("toggle-mcp"),
    name,
    enabled: z.boolean(),
  }),
  cronCreateSchema,
  z.strictObject({
    action: z.literal("cron-update"),
    jobId: id,
    updates: z.strictObject({
      name: optionalText(128),
      prompt: z.string().max(8_000).optional(),
      schedule: optionalText(256),
      deliver: optionalText(128),
      skills: z.array(name).max(32).optional(),
      model: optionalText(256),
      provider: optionalText(128),
      script: optionalText(16_000),
      workdir: optionalText(1_024),
      enabledToolsets: z.array(name).max(32).optional(),
      noAgent: z.boolean().optional(),
    }),
  }),
  z.strictObject({ action: z.literal("cron-pause"), jobId: id }),
  z.strictObject({ action: z.literal("cron-resume"), jobId: id }),
  z.strictObject({ action: z.literal("cron-run"), jobId: id }),
  z.strictObject({
    action: z.literal("cron-delete"),
    jobId: id,
    confirm: z.literal(true),
  }),
  z.strictObject({ action: z.literal("skill-install"), identifier: text(512) }),
  z.strictObject({
    action: z.literal("skill-uninstall"),
    name,
    confirm: z.literal(true),
  }),
  z.strictObject({ action: z.literal("skills-update") }),
  z.strictObject({
    action: z.literal("skill-create"),
    name,
    content: text(128_000),
    category: optionalText(128),
  }),
  z.strictObject({
    action: z.literal("skill-edit"),
    name,
    content: text(128_000),
  }),
  z
    .strictObject({
      action: z.literal("mcp-create"),
      name,
      url: optionalText(1_024),
      command: optionalText(1_024),
      args: z.array(z.string().max(1_024)).max(64).optional(),
      env: z.record(envName, z.string().max(8_192)).optional(),
      auth: z.enum(["none", "oauth", "header"]).optional(),
      bearerToken: optionalText(4_096),
    })
    .refine((value) => Boolean(value.url) !== Boolean(value.command), {
      message: "Choose exactly one MCP transport.",
      path: ["url"],
    })
    .refine((value) => !value.url || /^https?:\/\//i.test(value.url), {
      message: "MCP URLs must use HTTP or HTTPS.",
      path: ["url"],
    }),
  z.strictObject({
    action: z.literal("mcp-delete"),
    name,
    confirm: z.literal(true),
  }),
  z.strictObject({ action: z.literal("mcp-test"), name }),
  z.strictObject({
    action: z.literal("pairing-approve"),
    platform: name,
    requestId: optionalText(256),
    code: optionalText(64),
  }),
  z.strictObject({
    action: z.literal("pairing-revoke"),
    platform: name,
    userId: id,
    confirm: z.literal(true),
  }),
  z.strictObject({
    action: z.literal("pairing-clear"),
    confirm: z.literal(true),
  }),
  z.strictObject({ action: z.literal("curator-pause"), paused: z.boolean() }),
  z.strictObject({ action: z.literal("curator-run") }),
  z.strictObject({
    action: z.literal("session-fork"),
    sessionId: id,
    title: optionalText(512),
  }),
  z.strictObject({
    action: z.literal("session-model-lock"),
    sessionId: id,
    model: text(256),
    provider: optionalText(128),
  }),
  z.strictObject({
    action: z.literal("session-delete"),
    sessionId: id,
    confirm: z.literal(true),
  }),
  z.strictObject({
    action: z.literal("session-update"),
    sessionId: id,
    title: optionalText(512),
    archived: z.boolean().optional(),
    hidden: z.boolean().optional(),
    pinned: z.boolean().optional(),
    unread: z.boolean().optional(),
  }),
  z.strictObject({
    action: z.literal("project-create"),
    name,
    path: text(1_024),
    description: optionalText(2_000),
  }),
]);

export type HermesMutation = z.infer<typeof hermesMutationSchema>;
export type HermesOperation = {
  path: string;
  method: "POST" | "PUT" | "PATCH" | "DELETE";
  body?: unknown;
};

export function hermesOperationFor(
  input: HermesMutation,
): HermesOperation | null {
  const encodedName = "name" in input ? encodeURIComponent(input.name) : "";
  const encodedJob = "jobId" in input ? encodeURIComponent(input.jobId) : "";
  switch (input.action) {
    case "toggle-skill":
      return {
        path: "/api/skills/toggle",
        method: "PUT",
        body: { name: input.name, enabled: input.enabled },
      };
    case "toggle-toolset":
      return {
        path: `/api/tools/toolsets/${encodedName}`,
        method: "PUT",
        body: { enabled: input.enabled },
      };
    case "toggle-mcp":
      return {
        path: `/api/mcp/servers/${encodedName}/enabled`,
        method: "PUT",
        body: { enabled: input.enabled },
      };
    case "cron-create":
      return {
        path: "/api/cron/jobs",
        method: "POST",
        body: cronPayload(input),
      };
    case "cron-update":
      return {
        path: `/api/cron/jobs/${encodedJob}`,
        method: "PUT",
        body: { updates: cronPayload(input.updates) },
      };
    case "cron-pause":
      return { path: `/api/cron/jobs/${encodedJob}/pause`, method: "POST" };
    case "cron-resume":
      return { path: `/api/cron/jobs/${encodedJob}/resume`, method: "POST" };
    case "cron-run":
      return { path: `/api/cron/jobs/${encodedJob}/trigger`, method: "POST" };
    case "cron-delete":
      return { path: `/api/cron/jobs/${encodedJob}`, method: "DELETE" };
    case "skill-install":
      return {
        path: "/api/skills/hub/install",
        method: "POST",
        body: { identifier: input.identifier },
      };
    case "skill-uninstall":
      return {
        path: "/api/skills/hub/uninstall",
        method: "POST",
        body: { name: input.name },
      };
    case "skills-update":
      return { path: "/api/skills/hub/update", method: "POST", body: {} };
    case "skill-create":
      return {
        path: "/api/skills",
        method: "POST",
        body: {
          name: input.name,
          content: input.content,
          category: input.category,
        },
      };
    case "skill-edit":
      return {
        path: "/api/skills/content",
        method: "PUT",
        body: { name: input.name, content: input.content },
      };
    case "mcp-create":
      return {
        path: "/api/mcp/servers",
        method: "POST",
        body: {
          name: input.name,
          url: input.url,
          command: input.command,
          args: input.args ?? [],
          env: input.env ?? {},
          auth: input.auth,
          bearer_token: input.bearerToken,
        },
      };
    case "mcp-delete":
      return { path: `/api/mcp/servers/${encodedName}`, method: "DELETE" };
    case "mcp-test":
      return { path: `/api/mcp/servers/${encodedName}/test`, method: "POST" };
    case "pairing-approve":
      return {
        path: "/api/pairing/approve",
        method: "POST",
        body: {
          platform: input.platform,
          request_id: input.requestId,
          code: input.code,
        },
      };
    case "pairing-revoke":
      return {
        path: "/api/pairing/revoke",
        method: "POST",
        body: { platform: input.platform, user_id: input.userId },
      };
    case "pairing-clear":
      return { path: "/api/pairing/clear-pending", method: "POST" };
    case "curator-pause":
      return {
        path: "/api/curator/paused",
        method: "PUT",
        body: { paused: input.paused },
      };
    case "curator-run":
      return { path: "/api/curator/run", method: "POST" };
    case "session-fork":
      return {
        path: `/api/sessions/${encodeURIComponent(input.sessionId)}/fork`,
        method: "POST",
        body: { title: input.title },
      };
    case "session-model-lock":
      return {
        path: `/api/sessions/${encodeURIComponent(input.sessionId)}/model`,
        method: "POST",
        body: {
          model: input.model,
          provider: input.provider,
          require_model_lock: true,
        },
      };
    case "session-delete":
      return {
        path: `/api/sessions/${encodeURIComponent(input.sessionId)}`,
        method: "DELETE",
      };
    case "session-update":
      return {
        path: `/api/sessions/${encodeURIComponent(input.sessionId)}`,
        method: "PATCH",
        body: {
          title: input.title,
          archived: input.archived,
          hidden: input.hidden,
          pinned: input.pinned,
          unread: input.unread,
        },
      };
    case "project-create":
      return null;
  }
}

function cronPayload(value: Record<string, unknown>) {
  const { enabledToolsets, noAgent, ...rest } = value;
  return { ...rest, enabled_toolsets: enabledToolsets, no_agent: noAgent };
}
