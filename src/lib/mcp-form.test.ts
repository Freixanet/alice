import { describe, expect, it } from "vitest";
import { mcpMutationFromDraft, type McpDraft } from "./mcp-form";

const base: McpDraft = {
  name: "Docs",
  transport: "http",
  url: "https://mcp.example.test/sse",
  command: "",
  args: "",
  env: "",
  auth: "oauth",
  bearerToken: "",
};

describe("MCP form contracts", () => {
  it("builds an HTTP OAuth server without leaking unused fields", () => {
    expect(mcpMutationFromDraft(base)).toEqual({
      ok: true,
      mutation: {
        action: "mcp-create",
        name: "Docs",
        url: "https://mcp.example.test/sse",
        args: [],
        env: {},
        auth: "oauth",
      },
    });
  });

  it("parses stdio arguments and environment values safely", () => {
    expect(
      mcpMutationFromDraft({
        ...base,
        transport: "stdio",
        command: "npx",
        args: "-y\n@scope/server",
        env: "TOKEN=a=b=c\nEMPTY=",
      }),
    ).toMatchObject({
      ok: true,
      mutation: {
        command: "npx",
        args: ["-y", "@scope/server"],
        env: { TOKEN: "a=b=c", EMPTY: "" },
      },
    });
  });

  it.each(["1TOKEN=value", "TOKEN", "BAD-NAME=value"])(
    "rejects an invalid environment assignment: %s",
    (env) => {
      expect(mcpMutationFromDraft({ ...base, env })).toEqual({
        ok: false,
        error: "env",
      });
    },
  );
});
