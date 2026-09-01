import { describe, expect, it } from "vitest";
import { OperationalAlertMonitor } from "./operational-alerts.server";

describe("operational alert monitor", () => {
  it("alerts immediately for a critical sync failure without details", () => {
    const alert = new OperationalAlertMonitor().observe({
      kind: "server_request",
      route: "/api/sync",
      status: 500,
      outcome: "server_error",
      latencyMs: 12,
    });
    expect(alert).toEqual({
      type: "alice_alert",
      code: "sync_failure",
      severity: "critical",
      count: 1,
      windowMs: 60_000,
      route: "/api/sync",
    });
  });

  it("requires a burst and applies cooldown to Hermes failures", () => {
    const monitor = new OperationalAlertMonitor();
    const event = {
      kind: "server_request" as const,
      route: "/api/hermes" as const,
      status: 502,
      outcome: "upstream_error" as const,
      latencyMs: 80,
    };
    expect(monitor.observe(event, 1_000)).toBeUndefined();
    expect(monitor.observe(event, 2_000)).toBeUndefined();
    expect(monitor.observe(event, 3_000)).toMatchObject({
      code: "hermes_connection_failure_burst",
      count: 3,
    });
    expect(monitor.observe(event, 4_000)).toBeUndefined();
    expect(monitor.observe(event, 64_000)).toBeUndefined();
    expect(monitor.observe(event, 65_000)).toBeUndefined();
    expect(monitor.observe(event, 66_000)).toMatchObject({ count: 3 });
  });

  it("uses current Core Web Vitals thresholds", () => {
    const monitor = new OperationalAlertMonitor();
    expect(
      monitor.observe({
        kind: "web_vital",
        route: "/",
        browser: "safari",
        viewport: "narrow",
        metric: "lcp",
        latencyMs: 2_501,
      }),
    ).toMatchObject({
      code: "web_vital_budget_exceeded",
      severity: "warning",
      metric: "lcp",
    });
  });

  it("does not let a warning cooldown suppress a later critical alert", () => {
    const monitor = new OperationalAlertMonitor();
    const base = {
      kind: "web_vital" as const,
      route: "/" as const,
      browser: "safari" as const,
      viewport: "narrow" as const,
      metric: "inp" as const,
    };
    expect(monitor.observe({ ...base, latencyMs: 201 }, 1_000)).toMatchObject({
      severity: "warning",
    });
    expect(monitor.observe({ ...base, latencyMs: 501 }, 2_000)).toMatchObject({
      severity: "critical",
    });
  });

  it("alerts after three direct Hermes connection regressions", () => {
    const monitor = new OperationalAlertMonitor();
    const event = {
      kind: "client_error" as const,
      route: "/" as const,
      browser: "safari" as const,
      viewport: "narrow" as const,
      code: "hermes_connection_error" as const,
    };
    expect(monitor.observe(event, 1_000)).toBeUndefined();
    expect(monitor.observe(event, 2_000)).toBeUndefined();
    expect(monitor.observe(event, 3_000)).toMatchObject({
      code: "hermes_connection_failure_burst",
      count: 3,
    });
  });

  it("does not alert on upstream latency or healthy events", () => {
    const monitor = new OperationalAlertMonitor();
    expect(
      monitor.observe({
        kind: "server_request",
        route: "/api/chat",
        status: 200,
        outcome: "ok",
        latencyMs: 60_000,
      }),
    ).toBeUndefined();
    expect(
      monitor.observe({
        kind: "web_vital",
        route: "/",
        browser: "chromium",
        viewport: "wide",
        metric: "cls",
        value: 0.1,
      }),
    ).toBeUndefined();
  });
});
