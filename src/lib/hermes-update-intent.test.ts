import { describe, expect, it } from "vitest";
import { isHermesSelfUpdateIntent } from "./hermes-update-intent";

describe("Hermes self-update intent", () => {
  it.each([
    "/update",
    "actualízate",
    "Actualízate a la última versión",
    "actualiza Hermes",
    "por favor actualiza Hermes Agent",
    "¿puedes actualizar Hermes?",
    "update hermes",
    "upgrade Hermes Agent",
    "instala la última actualización de Hermes",
    "instala la nueva actualizacion de hermes agent",
  ])("accepts explicit update commands: %s", (value) => {
    expect(isHermesSelfUpdateIntent(value)).toBe(true);
  });

  it.each([
    "¿cómo actualizo Hermes?",
    "he intentado actualizar Hermes",
    "por qué no se actualiza Hermes",
    "comprueba si Hermes tiene actualizaciones",
    "actualiza este archivo de Hermes",
    "quiero que Alice pueda actualizar Hermes",
    "actualiza Hermes y luego cambia mi modelo",
    "",
  ])("does not hijack ordinary discussion: %s", (value) => {
    expect(isHermesSelfUpdateIntent(value)).toBe(false);
  });
});
