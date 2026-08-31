import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  assertGatewayKey,
  advertisesHermesCapability,
  isPrivateHostname,
  normalizeGatewayUrl,
  normalizeLlmBaseUrl,
  parseHermesCapabilityManifest,
  parseHermesModelOptions,
  scopeHermesGatewayBase,
  scopeHermesManagementPath,
} from "./gateway";

describe("gateway input invariants", () => {
  it.each([
    ["example.com", "https://example.com"],
    ["https://example.com/", "https://example.com"],
    ["http://127.0.0.1:8642/", "http://127.0.0.1:8642"],
  ])("normalizes %s", (input, expected) => {
    expect(normalizeGatewayUrl(input)).toBe(expected);
  });

  it("rejects credentials, paths and unsupported protocols", () => {
    for (const input of [
      "ftp://example.com",
      "https://user:pass@example.com",
    ]) {
      expect(() => normalizeGatewayUrl(input)).toThrow();
    }
  });

  it("accepts OpenAI base paths and removes duplicate suffixes", () => {
    expect(normalizeLlmBaseUrl("https://api.example.com/v1/")).toBe(
      "https://api.example.com/v1",
    );
  });

  it("uses Hermes' fail-closed multiplex prefix for a selected profile", () => {
    expect(scopeHermesGatewayBase("http://127.0.0.1:8642", "research")).toBe(
      "http://127.0.0.1:8642/p/research",
    );
    expect(scopeHermesGatewayBase("http://127.0.0.1:8642", undefined)).toBe(
      "http://127.0.0.1:8642",
    );
  });

  it("adds a profile to management routes without replacing query fields", () => {
    expect(
      scopeHermesManagementPath(
        "/api/model/options?include_unconfigured=1",
        "research",
      ),
    ).toBe("/api/model/options?include_unconfigured=1&profile=research");
    expect(
      scopeHermesManagementPath(
        "/api/model/options?profile=research",
        "default",
      ),
    ).toBe("/api/model/options?profile=research");
  });

  it("never accepts control characters in a gateway key", () => {
    fc.assert(
      fc.property(fc.string(), (value) => {
        const clean = [...value.trim()].every((char) => {
          const code = char.charCodeAt(0);
          return code > 31 && code !== 127;
        });
        if (clean && value.trim().length >= 8 && value.trim().length <= 256)
          return;
        expect(() => assertGatewayKey(value)).toThrow();
      }),
      { numRuns: 10_000 },
    );
  });

  it.each(["localhost", "127.0.0.1", "::1", "10.0.0.2", "192.168.1.4"])(
    "classifies %s as private",
    (host) => expect(isPrivateHostname(host)).toBe(true),
  );
});

describe("Hermes model parsing", () => {
  it("deduplicates malformed model payloads without throwing", () => {
    const result = parseHermesModelOptions({
      current_model: "m1",
      data: [
        { id: "m1", provider: "nous" },
        { id: "m1", provider: "nous" },
        null,
        { id: "" },
      ],
    });
    expect(result.currentModel).toBe("m1");
    expect(result.models).toHaveLength(1);
  });

  it("is total for arbitrary JSON values", () => {
    fc.assert(
      fc.property(fc.jsonValue(), (value) => {
        expect(() => parseHermesModelOptions(value)).not.toThrow();
      }),
      { numRuns: 10_000 },
    );
  }, 15_000);
});

describe("Hermes capability negotiation", () => {
  it("recognizes the current and previous stable versions", () => {
    expect(
      parseHermesCapabilityManifest({
        version: "0.20.6",
        capabilities: ["streaming", "cronjob", "delegate_task"],
      }),
    ).toMatchObject({
      compatibility: "current",
      capabilities: {
        "chat.streaming": true,
        cron: true,
        delegation: true,
      },
    });
    expect(
      parseHermesCapabilityManifest({ hermes_version: "v0.20.5" })
        .compatibility,
    ).toBe("previous");
  });

  it("degrades unknown versions by independently advertised capability", () => {
    expect(
      parseHermesCapabilityManifest({
        version: "99.0.0",
        features: { skills: true, cron: false, execute_code: true },
      }),
    ).toMatchObject({
      compatibility: "unknown",
      capabilities: { skills: true, code_execution: true },
    });
  });

  it("understands the official runs and session capability document", () => {
    expect(
      parseHermesCapabilityManifest({
        version: "0.20.6",
        features: {
          chat_completions_streaming: true,
          run_submission: true,
          run_status: true,
          run_events_sse: true,
          run_stop: true,
          run_steer: true,
          run_approval_response: true,
          approval_events: true,
          tool_progress_events: true,
          session_resources: true,
          model_options: true,
          skills_api: true,
        },
        endpoints: {
          health_detailed: {
            method: "GET",
            path: "/health/detailed",
          },
          session_fork: {
            method: "POST",
            path: "/api/sessions/{session_id}/fork",
          },
          ignored: { method: "POST" },
        },
      }),
    ).toMatchObject({
      compatibility: "current",
      capabilities: {
        "chat.streaming": true,
        "chat.runs": true,
        "chat.cancel": true,
        "chat.steer": true,
        "chat.approvals": true,
        "chat.tools": true,
        sessions: true,
        models: true,
        skills: true,
        diagnostics: true,
      },
    });
  });

  it("does not enable run controls from a partial capability advertisement", () => {
    expect(
      parseHermesCapabilityManifest({
        features: {
          run_events_sse: true,
          approval_events: true,
        },
      }).capabilities,
    ).toEqual({ "chat.streaming": true });
  });

  it("requires an exact normalized advertisement for optional controls", () => {
    const manifest = parseHermesCapabilityManifest({
      endpoints: {
        "session.fork": {
          method: "POST",
          path: "/api/sessions/{session_id}/fork",
        },
      },
    });
    expect(advertisesHermesCapability(manifest, "session_fork")).toBe(true);
    expect(advertisesHermesCapability(manifest, "session_model_lock")).toBe(
      false,
    );
  });

  it("is total for arbitrary capability documents", () => {
    fc.assert(
      fc.property(fc.jsonValue(), (value) => {
        expect(() => parseHermesCapabilityManifest(value)).not.toThrow();
      }),
      { numRuns: 10_000 },
    );
  }, 15_000);
});
