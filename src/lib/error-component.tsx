import type { ErrorComponentProps } from "@tanstack/react-router";
import { TriangleAlert } from "lucide-react";
import { localizeError } from "@/lib/i18n";
import { useLocale, useT } from "@/lib/use-i18n";

export function AppErrorComponent({ error }: ErrorComponentProps) {
  const t = useT();
  const locale = useLocale();
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-3 bg-background px-6 text-center text-foreground">
      <span className="text-destructive" aria-hidden="true">
        <TriangleAlert className="size-10" strokeWidth={1.75} />
      </span>
      <h1 className="text-lg font-medium">{t("error.pageTitle")}</h1>
      <p className="max-w-md text-sm break-words text-muted-foreground">
        {error.message
          ? localizeError(locale, error.message)
          : t("error.pageHint")}
      </p>
    </main>
  );
}

export function AppNotFoundComponent() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-3 bg-background px-6 text-center text-foreground">
      <p className="font-serif text-3xl">Alice</p>
      <h1 className="text-lg font-medium">Page not found</h1>
      <a className="text-sm text-muted-foreground underline" href="/">
        Return to chat
      </a>
    </main>
  );
}
