import { describe, expect, it } from "vitest";
import { applyCommandDefaults } from "../../scripts/with-app-env.mjs";

describe("development environment defaults", () => {
  it("uses restart-safe in-memory PGlite for the Vite dev preview", () => {
    expect(applyCommandDefaults("vite", ["dev"], {})).toMatchObject({
      ALICE_PGLITE_MEMORY: "1",
    });
  });

  it("preserves an explicitly configured persistent PGlite directory", () => {
    expect(
      applyCommandDefaults("vite", ["dev"], {
        ALICE_PGLITE_DIR: "/data/alice",
      }),
    ).toEqual({ ALICE_PGLITE_DIR: "/data/alice" });
  });

  it("does not change production builds", () => {
    expect(applyCommandDefaults("vite", ["build"], {})).toEqual({});
  });
});
