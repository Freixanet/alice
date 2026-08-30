import { afterEach, describe, expect, it, vi } from "vitest";
import { readHermesSessionMessagesDirect } from "./hermes-direct";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Hermes session message transport", () => {
  it("scopes and encodes the official endpoint and parses its bounded result", async () => {
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL) =>
        new Response(
          JSON.stringify({
            session_id: "session/one",
            data: [{ id: "m1", role: "assistant", content: "Hello" }],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      readHermesSessionMessagesDirect({
        url: "http://127.0.0.1:8642",
        key: "test-key-123",
        sessionId: "session/one",
      }),
    ).resolves.toEqual({
      ok: true,
      sessionId: "session/one",
      messages: [
        {
          id: "m1",
          role: "assistant",
          content: "Hello",
          timestamp: undefined,
          toolName: undefined,
        },
      ],
    });
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "http://127.0.0.1:8642/api/sessions/session%2Fone/messages?limit=50&order=latest",
    );
  });

  it("fails closed when Hermes returns no usable response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("", { status: 404 })),
    );
    await expect(
      readHermesSessionMessagesDirect({
        url: "https://hermes.example.test",
        key: "test-key-123",
        sessionId: "missing",
      }),
    ).resolves.toEqual({
      ok: false,
      error: "Couldn’t read this Hermes session.",
    });
  });
});
