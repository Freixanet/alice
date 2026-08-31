import { beforeEach, describe, expect, it } from "vitest";
import { useHermes } from "./store";

beforeEach(() => {
  useHermes.setState({
    model: "old-model",
    modelProvider: "old-provider",
    gatewayMeta: {
      model: "old-model",
      provider: "old-provider",
      models: [{ id: "old-model", label: "Old", provider: "old-provider" }],
      mode: "proxy",
      probedAt: Date.now(),
    },
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
