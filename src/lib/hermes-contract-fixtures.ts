/**
 * Normalized excerpts of the official Hermes API-server capability contract.
 * Version is supplied by /health/detailed; the capability endpoint itself
 * omits it. Runtime-dependent values represent an authenticated fixture.
 * Sources are pinned to release tags and commits so upstream main-branch drift
 * cannot silently change what Alice claims to support.
 */

const stableFeatures = {
  chat_completions: true,
  chat_completions_streaming: true,
  responses_api: true,
  responses_streaming: true,
  run_submission: true,
  run_status: true,
  run_events_sse: true,
  run_stop: true,
  run_steer: true,
  run_approval_response: true,
  tool_progress_events: true,
  approval_events: true,
  session_resources: true,
  model_options: true,
  session_chat: true,
  session_chat_streaming: true,
  session_fork: true,
  session_model_lock: true,
  admin_config_rw: false,
  jobs_admin: false,
  memory_write_api: false,
  skills_api: true,
  audio_api: false,
  realtime_voice: false,
  session_continuity_header: "X-Hermes-Session-Id",
  session_key_header: "X-Hermes-Session-Key",
} as const;

const stableEndpoints = {
  health: { method: "GET", path: "/health" },
  health_detailed: { method: "GET", path: "/health/detailed" },
  models: { method: "GET", path: "/v1/models" },
  model_options: { method: "GET", path: "/api/model/options" },
  chat_completions: { method: "POST", path: "/v1/chat/completions" },
  responses: { method: "POST", path: "/v1/responses" },
  runs: { method: "POST", path: "/v1/runs" },
  run_status: { method: "GET", path: "/v1/runs/{run_id}" },
  run_events: { method: "GET", path: "/v1/runs/{run_id}/events" },
  run_approval: { method: "POST", path: "/v1/runs/{run_id}/approval" },
  run_steer: { method: "POST", path: "/v1/runs/{run_id}/steer" },
  run_stop: { method: "POST", path: "/v1/runs/{run_id}/stop" },
  skills: { method: "GET", path: "/v1/skills" },
  toolsets: { method: "GET", path: "/v1/toolsets" },
  sessions: { method: "GET", path: "/api/sessions" },
  session_create: { method: "POST", path: "/api/sessions" },
  session: { method: "GET", path: "/api/sessions/{session_id}" },
  session_update: { method: "PATCH", path: "/api/sessions/{session_id}" },
  session_delete: { method: "DELETE", path: "/api/sessions/{session_id}" },
  session_messages: {
    method: "GET",
    path: "/api/sessions/{session_id}/messages",
  },
  session_fork: {
    method: "POST",
    path: "/api/sessions/{session_id}/fork",
  },
  session_chat: {
    method: "POST",
    path: "/api/sessions/{session_id}/chat",
  },
  session_chat_stream: {
    method: "POST",
    path: "/api/sessions/{session_id}/chat/stream",
  },
  session_model_lock: {
    method: "POST",
    path: "/api/sessions/{session_id}/model",
  },
  browser_control_register: {
    method: "POST",
    path: "/v1/browser-control/register",
  },
  browser_control_ws: { method: "GET", path: "/v1/browser-control/ws" },
  artifact_upload: { method: "POST", path: "/v1/artifacts/upload" },
  artifact_download: {
    method: "GET",
    path: "/v1/artifacts/download/{artifact_id}",
  },
} as const;

export type HermesContractFixture = Readonly<{
  source: Readonly<{
    tag: string;
    commit: string;
    packageVersion: string;
    apiServerSource: string;
  }>;
  capabilities: Readonly<Record<string, unknown>>;
}>;

const legacyFixtures = [
  {
    source: {
      tag: "v2026.8.31",
      commit: "29112bef099274229cadff79cdff7bf7b99c4b77",
      packageVersion: "0.21.0",
      apiServerSource:
        "https://github.com/NousResearch/hermes-agent/blob/v2026.8.31/gateway/platforms/api_server.py",
    },
    capabilities: {
      version: "0.21.0",
      object: "hermes.api_server.capabilities",
      platform: "hermes-agent",
      model: "hermes-agent",
      auth: { type: "bearer", required: true },
      runtime: {
        mode: "server_agent",
        tool_execution: "server",
        split_runtime: false,
      },
      features: {
        ...stableFeatures,
        runs_idempotency: {
          header: "Idempotency-Key",
          durable: true,
          conflict_status: 409,
          replay_status: 202,
        },
      },
      endpoints: stableEndpoints,
    },
  },
  {
    source: {
      tag: "v2026.8.27",
      commit: "5fc308a70719a83cccdbba4c0e39c23f5a8239d5",
      packageVersion: "0.20.6",
      apiServerSource:
        "https://github.com/NousResearch/hermes-agent/blob/v2026.8.27/gateway/platforms/api_server.py",
    },
    capabilities: {
      version: "0.20.6",
      object: "hermes.api_server.capabilities",
      platform: "hermes-agent",
      model: "hermes-agent",
      auth: { type: "bearer", required: true },
      runtime: {
        mode: "server_agent",
        tool_execution: "server",
        split_runtime: false,
      },
      features: stableFeatures,
      endpoints: stableEndpoints,
    },
  },
] as const satisfies readonly HermesContractFixture[];

// _STATIC_FEATURE_FLAGS and _CAPABILITY_ENDPOINTS were compared directly in
// gateway/platforms/api_server.py at both tags; these primitive routes match
// the 0.21.0 contract. Dynamic browser settings are not claimed by this excerpt.
export const HERMES_CONTRACT_FIXTURES = [
  ...[
    {
      tag: "v2026.9.14",
      commit: "345cd2b057a452236de401d3534b8502a7465e8d",
      packageVersion: "0.21.3",
    },
    {
      tag: "v2026.9.11",
      commit: "939e45c91d751fadd94dcd1b873ac3cb44846213",
      packageVersion: "0.21.2",
    },
  ].map((source) => ({
    source: {
      ...source,
      apiServerSource: `https://github.com/NousResearch/hermes-agent/blob/${source.tag}/gateway/platforms/api_server.py`,
    },
    capabilities: {
      ...legacyFixtures[0].capabilities,
      version: source.packageVersion,
    },
  })),
  ...legacyFixtures,
] as const satisfies readonly HermesContractFixture[];
