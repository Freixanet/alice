import { useState } from "react";
import { mutateHermes, type HermesMutationResult } from "./hermes-live";
import type { HermesMutation } from "./hermes-operations";
import { localizeError } from "./i18n";
import { useLocale } from "./use-i18n";

export function useHermesMutation(onChanged: () => Promise<void>) {
  const locale = useLocale();
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  async function run(
    key: string,
    mutation: HermesMutation,
  ): Promise<HermesMutationResult> {
    setBusy(key);
    setError(null);
    setNotice(null);
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      setError(localizeError(locale, result.error));
      setBusy(null);
      return result;
    }
    await onChanged();
    setBusy(null);
    return result;
  }

  return { busy, error, notice, run, setError, setNotice };
}
