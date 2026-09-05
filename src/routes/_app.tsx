import { lazy, Suspense } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { AppShell } from "@/components/shell";
import { authEnabled } from "@/lib/auth/client";
import { RedirectToSignIn } from "@/lib/auth/gates";
import { AuthProvider } from "@/lib/auth/provider";
import { SessionBoundary } from "@/lib/auth/session-boundary";
import { useCurrentUserState } from "@/lib/auth/use-current-user";
import { useT } from "@/lib/use-i18n";

const CloudSync = lazy(() =>
  import("@/components/cloud-sync").then(({ CloudSync }) => ({
    default: CloudSync,
  })),
);

export const Route = createFileRoute("/_app")({
  component: AppBoundary,
});

function AppBoundary() {
  return (
    <SessionBoundary>
      <AuthProvider>
        <AppGate />
      </AuthProvider>
    </SessionBoundary>
  );
}

function AppContent() {
  return (
    <>
      <AppShell />
      <Suspense fallback={null}>
        <CloudSync />
      </Suspense>
    </>
  );
}

function AppGate() {
  const t = useT();
  const { user, isPending } = useCurrentUserState();
  if (!authEnabled) return <AppContent />;
  if (isPending) {
    return (
      <div className="grid min-h-svh place-items-center text-sm text-muted-foreground">
        {t("app.loading")}
      </div>
    );
  }
  if (!user) return <RedirectToSignIn />;
  return <AppContent />;
}
