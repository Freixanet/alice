import { describe, expect, it } from "vitest";
import {
  mcpProbeCacheKey,
  mcpServerUsageCount,
  mcpUsagePrefix,
} from "./mcp-command-center";

describe("MCP command center", () => {
  it("uses the exact registry prefix normalization from Hermes", () => {
    expect(mcpUsagePrefix("GitHub Cloud/v2")).toBe("mcp__GitHub_Cloud_v2__");
  });

  it("counts only finite positive calls from the selected server", () => {
    expect(
      mcpServerUsageCount("github", {
        mcp__github__search: 4,
        mcp__github__read: 3,
        mcp__linear__search: 100,
        mcp__github__broken: Number.POSITIVE_INFINITY,
        mcp__github__negative: -1,
      }),
    ).toBe(7);
  });

  it("isolates probe caches by Hermes, profile and server", () => {
    expect(
      mcpProbeCacheKey({
        gatewayUrl: "https://hermes.example",
        profile: "research",
        serverName: "github",
      }),
    ).not.toBe(
      mcpProbeCacheKey({
        gatewayUrl: "https://hermes.example",
        profile: "default",
        serverName: "github",
      }),
    );
  });
});
