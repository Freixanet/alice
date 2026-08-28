import { useEffect } from "react";
import type { Locale, MsgKey } from "./i18n";
import { t } from "./i18n";
import { useHermes } from "./store";

export function useT() {
  const locale = useHermes((s) => s.locale);
  return (key: MsgKey, vars?: Record<string, string | number>) => t(locale, key, vars);
}

export function useLocale(): Locale {
  return useHermes((s) => s.locale);
}

export function LocaleDocumentLang() {
  const locale = useLocale();
  useEffect(() => {
    document.documentElement.lang = locale;
  }, [locale]);
  return null;
}
