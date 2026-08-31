import { beforeEach, describe, expect, it } from "vitest";
import { rememberRecentModel, useHermes } from "./store";

beforeEach(() => {
  useHermes.setState({
    model: "old-model",
    modelProvider: "old-provider",
    recentModels: [],
    gatewayMeta: {
      model: "old-model",
      provider: "old-provider",
      models: [{ id: "old-model", label: "Old", provider: "old-provider" }],
      mode: "proxy",
      probedAt: Date.now(),
    },
  });
});

describe("recent model history", () => {
  it("keeps the latest five unique provider and model pairs", () => {
    let recent = rememberRecentModel([], { id: "model-a", provider: "one" });
    recent = rememberRecentModel(recent, { id: "model-b", provider: "one" });
    recent = rememberRecentModel(recent, { id: "model-a", provider: "two" });
    recent = rememberRecentModel(recent, { id: "model-c", provider: "one" });
    recent = rememberRecentModel(recent, { id: "model-d", provider: "one" });
    recent = rememberRecentModel(recent, { id: "model-e", provider: "one" });
    recent = rememberRecentModel(recent, { id: "model-b", provider: "one" });

    expect(recent).toEqual([
      { id: "model-b", provider: "one" },
      { id: "model-e", provider: "one" },
      { id: "model-d", provider: "one" },
      { id: "model-c", provider: "one" },
      { id: "model-a", provider: "two" },
    ]);
  });

  it("records model selections in persistent state", () => {
    useHermes.getState().setModel("new-model", "new-provider");

    expect(useHermes.getState().recentModels).toEqual([
      { id: "new-model", provider: "new-provider" },
    ]);
  });
});

describe("profile-scoped model inventory", () => {
  it("replaces stale provider rows and applies the selected profile default", () => {
    useHermes
      .getState()
      .setGatewayModels(
        [{ id: "new-model", label: "New", provider: "new-provider" }],
        { model: "new-model", provider: "new-provider" },
      );

    expect(useHermes.getState()).toMatchObject({
      model: "new-model",
      modelProvider: "new-provider",
      gatewayMeta: {
        models: [{ id: "new-model", label: "New", provider: "new-provider" }],
      },
    });
  });
});
