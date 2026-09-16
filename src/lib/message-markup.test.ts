import { describe, expect, it } from "vitest";
import { prepareMessageMarkup } from "./message-markup";

describe("prepareMessageMarkup", () => {
  it("labels the five callouts Alice draws", () => {
    expect(prepareMessageMarkup("> [!WARNING]\n> Cuidado")).toContain(
      "> **Warning**",
    );
    expect(prepareMessageMarkup("> [!WARNING]\n> Cuidado")).toContain(
      "> Cuidado",
    );
  });

  it("drops an unknown [!KIND] instead of leaving the tag in a quote", () => {
    expect(prepareMessageMarkup("> [!TIMELINE]\n> Ayer, luego hoy.")).toBe(
      "\nAyer, luego hoy.",
    );
    expect(prepareMessageMarkup("> [!quiz] Elige una")).toBe("Elige una");
    expect(prepareMessageMarkup("> [!stat]")).toBe("");
  });

  it("does not unwrap a known callout as if it were unknown", () => {
    const out = prepareMessageMarkup("> [!NOTE]\n> Hecho");
    expect(out).toContain("> **Note**");
    expect(out).not.toBe("\nHecho");
  });
});
