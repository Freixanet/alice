function normalizeUpdateIntent(value: string): string {
  return value
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase()
    .replace(/[¿?¡!.,;:]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Conservative command-intent detector for Hermes self-updates.
 *
 * This intentionally matches only standalone imperative requests. Questions,
 * troubleshooting messages and sentences that merely mention updating Hermes
 * must continue to the agent instead of starting a destructive maintenance
 * operation by accident.
 */
export function isHermesSelfUpdateIntent(value: string): boolean {
  const text = normalizeUpdateIntent(value);
  if (!text) return false;
  if (text === "/update") return true;

  const polite = "(?:por favor )?(?:puedes |podrias )?";
  const target = "(?:hermes(?: agent)?)";
  const suffix = "(?: a la ultima version)?";

  return new RegExp(
    `^${polite}(?:` +
      `actualizate${suffix}|` +
      `actualiza ${target}${suffix}|` +
      `update ${target}${suffix}|` +
      `upgrade ${target}${suffix}|` +
      `instala (?:la )?(?:ultima|nueva) actualizacion (?:de )?${target}` +
      `)$`,
  ).test(text);
}
