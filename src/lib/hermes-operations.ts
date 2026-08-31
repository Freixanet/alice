import { z } from "zod";
import { HERMES_PROFILE_NAME_PATTERN } from "./hermes-profile";

const name = z.string().trim().min(1).max(128);
const id = z.string().trim().min(1).max(160);
const optionalText = (max: number) => z.string().trim().max(max).optional();
const text = (max: number) => z.string().trim().min(1).max(max);
const envName = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/);
const platformId = z
  .string()
  .trim()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9][A-Za-z0-9_-]*$/);
const projectBoardSlug = z
  .string()
  .trim()
  .max(64)
  .refine(
    (value) => !value || /^[a-z0-9][a-z0-9_-]{0,63}$/.test(value),
    "Invalid board slug.",
  );
const webhookName = z
  .string()
  .trim()
  .min(1)
  .max(128)
  .regex(/^[a-z0-9][a-z0-9_-]*$/);
export const hermesProfileNameSchema = z
  .string()
  .trim()
  .min(1)
  .max(64)
  .regex(HERMES_PROFILE_NAME_PATTERN);
const webhookCreateSchema = z
  .strictObject({
    action: z.literal("webhook-create"),
    name: webhookName,
    description: optionalText(2_000),
    events: z.array(text(128)).max(64).optional(),
    prompt: optionalText(8_000),
    skills: z.array(name).max(32).optional(),
    deliver: optionalText(128),
    deliverOnly: z.boolean().optional(),
    deliverChatId: optionalText(256),
  })
  .refine(
    (value) =>
      !value.deliverOnly || Boolean(value.deliver && value.deliver !== "log"),
    {
      message: "Direct delivery requires a real destination.",
      path: ["deliver"],
    },
  );
const channelUpdateSchema = z
  .strictObject({
    action: z.literal("channel-update"),
    platformId,
    enabled: z.boolean().optional(),
    env: z.record(envName, text(8_192)).optional(),
    clearEnv: z.array(envName).max(64).optional(),
  })
  .refine(
    (value) =>
      value.enabled !== undefined ||
      Boolean(Object.keys(value.env ?? {}).length) ||
      Boolean(value.clearEnv?.length),
    { message: "At least one channel change is required." },
  )
  .refine(
    (value) =>
      !value.clearEnv?.some((key) => Object.hasOwn(value.env ?? {}, key)),
    { message: "A variable cannot be set and cleared together." },
  );

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
  channelUpdateSchema,
  z.strictObject({ action: z.literal("channel-test"), platformId }),
  z.strictObject({ action: z.literal("webhook-enable") }),
  webhookCreateSchema,
  z.strictObject({
    action: z.literal("webhook-toggle"),
    name: webhookName,
    enabled: z.boolean(),
  }),
  z.strictObject({
    action: z.literal("webhook-delete"),
    name: webhookName,
    confirm: z.literal(true),
  }),
  z.strictObject({
    action: z.literal("profile-create"),
    name: hermesProfileNameSchema,
    cloneFrom: hermesProfileNameSchema.optional(),
    cloneAll: z.boolean().optional(),
    noSkills: z.boolean().optional(),
    description: optionalText(2_000),
  }),
  z.strictObject({
    action: z.literal("profile-activate"),
    name: hermesProfileNameSchema,
  }),
  z.strictObject({
    action: z.literal("profile-rename"),
    name: hermesProfileNameSchema,
    newName: hermesProfileNameSchema,
  }),
  z.strictObject({
    action: z.literal("profile-description"),
    name: hermesProfileNameSchema,
    description: z.string().trim().max(2_000),
  }),
  z.strictObject({
    action: z.literal("profile-soul-update"),
    name: hermesProfileNameSchema,
    content: z.string().max(128_000),
  }),
  z.strictObject({
    action: z.literal("profile-delete"),
    name: hermesProfileNameSchema,
    confirm: z.literal(true),
  }),
  z.strictObject({
    action: z.literal("session-create"),
    sessionId: id,
    title: text(512),
    model: optionalText(256),
    provider: optionalText(128),
  }),
  z.strictObject({
    action: z.literal("session-fork"),
    sessionId: id,
    forkId: id,
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
  z.strictObject({
    action: z.literal("project-rename"),
    projectId: id,
    name,
  }),
  z.strictObject({
    action: z.literal("project-add-folder"),
    projectId: id,
    path: text(1_024),
    label: optionalText(128),
    primary: z.boolean().optional(),
  }),
  z.strictObject({
    action: z.literal("project-remove-folder"),
    projectId: id,
    path: text(1_024),
    confirm: z.literal(true),
  }),
  z.strictObject({
    action: z.literal("project-set-primary"),
    projectId: id,
    path: text(1_024),
  }),
  z.strictObject({
    action: z.literal("project-activate"),
    projectId: id,
  }),
  z.strictObject({
    action: z.literal("project-archive"),
    projectId: id,
    confirm: z.literal(true),
  }),
  z.strictObject({
    action: z.literal("project-restore"),
    projectId: id,
  }),
  z.strictObject({
    action: z.literal("project-bind-board"),
    projectId: id,
    board: projectBoardSlug,
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
    case "channel-update":
      return {
        path: `/api/messaging/platforms/${encodeURIComponent(input.platformId)}`,
        method: "PUT",
        body: {
          enabled: input.enabled,
          env: input.env,
          clear_env: input.clearEnv,
        },
      };
    case "channel-test":
      return {
        path: `/api/messaging/platforms/${encodeURIComponent(input.platformId)}/test`,
        method: "POST",
      };
    case "webhook-enable":
      return { path: "/api/webhooks/enable", method: "POST" };
    case "webhook-create":
      return {
        path: "/api/webhooks",
        method: "POST",
        body: {
          name: input.name,
          description: input.description,
          events: input.events,
          prompt: input.prompt,
          skills: input.skills,
          deliver: input.deliver,
          deliver_only: input.deliverOnly,
          deliver_chat_id: input.deliverChatId,
        },
      };
    case "webhook-toggle":
      return {
        path: `/api/webhooks/${encodedName}/enabled`,
        method: "PUT",
        body: { enabled: input.enabled },
      };
    case "webhook-delete":
      return { path: `/api/webhooks/${encodedName}`, method: "DELETE" };
    case "profile-create":
      return {
        path: "/api/profiles",
        method: "POST",
        body: {
          name: input.name,
          clone_from: input.cloneFrom,
          clone_all: input.cloneAll,
          no_skills: input.noSkills,
          description: input.description,
        },
      };
    case "profile-activate":
      return {
        path: "/api/profiles/active",
        method: "POST",
        body: { name: input.name },
      };
    case "profile-rename":
      return {
        path: `/api/profiles/${encodedName}`,
        method: "PATCH",
        body: { new_name: input.newName },
      };
    case "profile-description":
      return {
        path: `/api/profiles/${encodedName}/description`,
        method: "PUT",
        body: { description: input.description },
      };
    case "profile-soul-update":
      return {
        path: `/api/profiles/${encodedName}/soul`,
        method: "PUT",
        body: { content: input.content },
      };
    case "profile-delete":
      return { path: `/api/profiles/${encodedName}`, method: "DELETE" };
    case "session-create":
      return {
        path: "/api/sessions",
        method: "POST",
        body: {
          id: input.sessionId,
          title: input.title,
          source: "alice",
          model: input.model,
          provider: input.provider,
          require_model_lock: Boolean(input.model),
        },
      };
    case "session-fork":
      return {
        path: `/api/sessions/${encodeURIComponent(input.sessionId)}/fork`,
        method: "POST",
        body: { id: input.forkId, title: input.title },
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
    case "project-rename":
    case "project-add-folder":
    case "project-remove-folder":
    case "project-set-primary":
    case "project-activate":
    case "project-archive":
    case "project-restore":
    case "project-bind-board":
      return null;
  }
}

export function hermesScopedOperationFor(
  input: HermesMutation,
  profile?: string,
): HermesOperation | null {
  const operation = hermesOperationFor(input);
  if (!operation || !profile || input.action.startsWith("profile-")) {
    return operation;
  }
  const separator = operation.path.includes("?") ? "&" : "?";
  return {
    ...operation,
    path: `${operation.path}${separator}profile=${encodeURIComponent(profile)}`,
  };
}

/**
 * Official `hermes project` argv for the project lifecycle Hermes exposes only
 * through its CLI. Keeping this pure makes the local adapter testable without
 * starting a subprocess and prevents Alice from inventing dashboard routes.
 */
export function hermesProjectCliArgsFor(
  input: HermesMutation,
): string[] | null {
  switch (input.action) {
    case "project-create": {
      const args = [
        "project",
        "create",
        input.name,
        input.path,
        "--primary",
        input.path,
      ];
      if (input.description) args.push("--description", input.description);
      return args;
    }
    case "project-rename":
      return ["project", "rename", input.projectId, input.name];
    case "project-add-folder": {
      const args = ["project", "add-folder", input.projectId, input.path];
      if (input.label) args.push("--label", input.label);
      if (input.primary) args.push("--primary");
      return args;
    }
    case "project-remove-folder":
      return ["project", "remove-folder", input.projectId, input.path];
    case "project-set-primary":
      return ["project", "set-primary", input.projectId, input.path];
    case "project-activate":
      return ["project", "use", input.projectId];
    case "project-archive":
      return ["project", "archive", input.projectId];
    case "project-restore":
      return ["project", "restore", input.projectId];
    case "project-bind-board":
      return ["project", "bind-board", input.projectId, input.board];
    default:
      return null;
  }
}

function cronPayload(value: Record<string, unknown>) {
  const { enabledToolsets, noAgent, ...rest } = value;
  return { ...rest, enabled_toolsets: enabledToolsets, no_agent: noAgent };
}
