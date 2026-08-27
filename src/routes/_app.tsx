import { createFileRoute } from "@tanstack/react-router";
import { AppShell } from "@/components/shell";
import { authEnabled } from "@/lib/auth/client";
import { RedirectToSignIn } from "@/lib/auth/gates";
import { useCurrentUserState } from "@/lib/auth/use-current-user";

export const Route = createFileRoute("/_app")({
  component: AppGate,
});

function AppGate() {
  const { user, isPending } = useCurrentUserState();
  if (!authEnabled) return <AppShell />;
  if (isPending) {
    return (
      <div className="grid min-h-svh place-items-center text-sm text-muted-foreground">
        Un momento…
      </div>
    );
  }
  if (!user) return <RedirectToSignIn />;
  return <AppShell />;
}
