import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);
const verifier = fileURLToPath(
  new URL("../../scripts/verify-release.mjs", import.meta.url),
);
const expectedSha = "0123456789abcdef0123456789abcdef01234567";
const version = expectedSha.slice(0, 12);

type StatusFixture = {
  bodyVersion?: string;
  headerVersion?: string;
  status?: number;
  expected?: string;
};

async function verify(fixture: StatusFixture) {
  const server = createServer((request, response) => {
    if (request.url !== "/api/status") {
      response.writeHead(404).end();
      return;
    }
    response.statusCode = fixture.status ?? 200;
    response.setHeader("Content-Type", "application/json");
    if (fixture.headerVersion !== undefined) {
      response.setHeader("X-Alice-Version", fixture.headerVersion);
    }
    response.end(
      JSON.stringify({
        status: "ok",
        release: {
          version: fixture.bodyVersion,
          environment: "production",
          source: "vercel",
        },
      }),
    );
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("No test server address");
    }
    const env = { ...process.env };
    delete env.ALICE_EXPECTED_SHA;
    if (fixture.expected !== undefined)
      env.ALICE_EXPECTED_SHA = fixture.expected;
    try {
      const { stdout } = await execFileAsync(
        process.execPath,
        [verifier, `http://127.0.0.1:${address.port}`],
        { env, timeout: 20_000 },
      );
      return { ok: true, message: stdout };
    } catch (error) {
      const failed = error as Error & { stderr?: string };
      return { ok: false, message: failed.stderr ?? failed.message };
    }
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  }
}

describe("deployment release verifier", () => {
  it("keeps the URL-only verification compatible", async () => {
    expect(
      await verify({ bodyVersion: version, headerVersion: version }),
    ).toMatchObject({
      ok: true,
    });
  });

  it("accepts a release matching the full expected SHA", async () => {
    const result = await verify({
      bodyVersion: version,
      headerVersion: version,
      expected: expectedSha,
    });
    expect(result.ok).toBe(true);
    expect(result.message).toContain(version);
  });

  it("rejects a healthy but incorrect deployed version", async () => {
    const result = await verify({
      bodyVersion: "ffffffffffff",
      headerVersion: "ffffffffffff",
      expected: expectedSha,
    });
    expect(result.ok).toBe(false);
    expect(result.message).toContain("expected Git commit");
  });

  it.each([
    {
      name: "missing header",
      bodyVersion: version,
      message: "Release metadata is missing or inconsistent",
    },
    {
      name: "missing body version",
      headerVersion: version,
      message: "Release metadata is missing or inconsistent",
    },
    {
      name: "mismatched header",
      bodyVersion: version,
      headerVersion: "ffffffffffff",
      message: "Release metadata is missing or inconsistent",
    },
    {
      name: "empty version",
      bodyVersion: "",
      headerVersion: "",
      message: "Release metadata is missing or inconsistent",
    },
    {
      name: "invalid version",
      bodyVersion: "wrong version",
      headerVersion: "wrong version",
      message: "Release metadata is missing or inconsistent",
    },
    {
      name: "HTTP error",
      bodyVersion: version,
      headerVersion: version,
      status: 503,
      message: "Release check failed with HTTP 503",
    },
  ])("rejects $name", async (fixture) => {
    const result = await verify(fixture);
    expect(result.ok).toBe(false);
    expect(result.message).toContain(fixture.message);
  });

  it.each(["", "abc", "g".repeat(40), "0".repeat(41)])(
    "rejects invalid expected SHA %s",
    async (expected) => {
      const result = await verify({
        bodyVersion: version,
        headerVersion: version,
        expected,
      });
      expect(result.ok).toBe(false);
      expect(result.message).toContain("ALICE_EXPECTED_SHA");
    },
  );
});
