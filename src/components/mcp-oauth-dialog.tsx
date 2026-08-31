import { ExternalLink } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import type { HermesMcpOAuthFlow } from "@/lib/hermes-live-types";
import { useT } from "@/lib/use-i18n";

export function McpOAuthDialog({
  flow,
  pending,
  onCancel,
  onClose,
}: {
  flow: HermesMcpOAuthFlow | null;
  pending: boolean;
  onCancel: () => void;
  onClose: () => void;
}) {
  const t = useT();
  const complete = flow?.status === "approved";
  return (
    <Dialog
      open={Boolean(flow)}
      onOpenChange={(open) => {
        if (!open && !pending) (complete ? onClose : onCancel)();
      }}
    >
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t("addons.oauthTitle", { name: flow?.serverName ?? "MCP" })}
          </DialogTitle>
          <DialogDescription>
            {complete
              ? t("addons.oauthComplete")
              : t("addons.oauthDescription")}
          </DialogDescription>
        </DialogHeader>
        {flow?.error ? (
          <p className="text-sm text-destructive">{flow.error}</p>
        ) : null}
        {!complete && flow?.authorizationUrl ? (
          <Button asChild>
            <a href={flow.authorizationUrl} target="_blank" rel="noreferrer">
              {t("addons.oauthOpen")}
              <ExternalLink />
            </a>
          </Button>
        ) : null}
        {!complete ? (
          <p className="text-xs text-muted-foreground">
            {t("addons.oauthWaiting")}
          </p>
        ) : null}
        <div className="flex justify-end">
          <Button
            variant={complete ? "default" : "ghost"}
            disabled={pending}
            onClick={complete ? onClose : onCancel}
          >
            {complete ? t("addons.oauthDone") : t("projects.cancel")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
