// @vitest-environment jsdom
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useGatewayHealth } from "./use-gateway-health";

const mocks = vi.hoisted(() => ({
  probe: vi.fn(),
  models: vi.fn(),
  down: vi.fn(),
  live: vi.fn(),
  checking: vi.fn(),
  setModels: vi.fn(),
}));
vi.mock("./auth/client", () => ({ authHeaders: () => ({}) }));
vi.mock("./gateway", () => ({ getMacSessionKey: () => null }));
vi.mock("./hermes-direct", () => ({ getDeviceSessionKey: () => "fixture" }));
vi.mock("./hermes-client", () => ({
  probeGateway: mocks.probe,
  listHermesModels: mocks.models,
}));
vi.mock("./operational-telemetry-client", () => ({
  reportClientError: vi.fn(),
}));
vi.mock("./store", () => {
  const state = {
    hydrated: true,
    gatewayOn: true,
    gatewayUrl: "https://hermes.example.test",
    gatewayPlace: "device",
    gatewayStatus: "live",
    setGatewayDown: mocks.down,
    setGatewayLive: mocks.live,
    setGatewayChecking: mocks.checking,
    setGatewayModels: mocks.setModels,
  };
  return {
    useHermes: Object.assign(
      (selector: (s: typeof state) => unknown) => selector(state),
      { getState: () => state },
    ),
  };
});

beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  mocks.models.mockResolvedValue({ ok: true, models: [] });
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("gateway health", () => {
  it("stops claiming to be connected after a failed probe and recovers", async () => {
    mocks.probe
      .mockResolvedValueOnce({
        ok: false,
        code: "unreachable",
        error: "Disconnected",
      })
      .mockResolvedValue({ ok: true });
    renderHook(useGatewayHealth);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(mocks.down).toHaveBeenCalledWith("Disconnected");
    await act(async () => {
      await vi.advanceTimersByTimeAsync(15_000);
    });
    expect(mocks.live).toHaveBeenCalledOnce();
  });

  it("retries unexpected failures without leaving an unhandled rejection", async () => {
    mocks.probe.mockRejectedValue(new Error("storage unavailable"));
    renderHook(useGatewayHealth);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(mocks.down).toHaveBeenCalledOnce();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(15_000);
    });
    expect(mocks.probe).toHaveBeenCalledTimes(2);
  });

  it("ignores an old probe after unmount and cancels its retries", async () => {
    let resolve!: (result: unknown) => void;
    mocks.probe.mockReturnValue(
      new Promise((done) => {
        resolve = done;
      }),
    );
    const { unmount } = renderHook(useGatewayHealth);
    unmount();
    await act(async () => {
      resolve({ ok: false, error: "Disconnected" });
      await vi.advanceTimersByTimeAsync(60_000);
    });
    expect(mocks.down).not.toHaveBeenCalled();
    expect(mocks.probe).toHaveBeenCalledOnce();
  });
});
