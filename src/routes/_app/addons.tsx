import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { CatalogPage } from "@/components/catalog-page";
import { McpServerDialog } from "@/components/mcp-server-dialog";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { listHermesLive, mutateHermes } from "@/lib/hermes-live";
import { localizeError } from "@/lib/i18n";
import type { HermesMutation } from "@/lib/hermes-operations";
import { useHermesLive } from "@/lib/use-hermes-live";
import { useLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/_app/addons")({
  component: AddonsPage,
});

function AddonsPage() {
  const t = useT();
  const locale = useLocale();
  const navigate = useNavigate();
  const { data, error, loading, setData } = useHermesLive();
  const rows = data?.mcp ?? [];
  const [addOpen, setAddOpen] = useState(false);
  const [deleteName, setDeleteName] = useState<string | null>(null);
  const [busyName, setBusyName] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<string | null>(null);

  async function refresh(): Promise<boolean> {
    const fresh = await listHermesLive();
    if (fresh.ok) {
      setData(fresh);
      return true;
    }
    setFeedback(localizeError(locale, fresh.error));
    return false;
  }

  async function saveServer(
    mutation: Extract<HermesMutation, { action: "mcp-create" }>,
  ): Promise<string | null> {
    const result = await mutateHermes(mutation);
    if (!result.ok) {
      return localizeError(
        locale,
        result.error || "Hermes couldn’t save the change.",
      );
    }
    return (await refresh()) ? null : t("addons.descOff");
  }

  async function testServer(name: string) {
    if (busyName) return;
    setBusyName(name);
    setFeedback(null);
    const result = await mutateHermes({ action: "mcp-test", name });
    setBusyName(null);
    setFeedback(
      result.ok
        ? t("addons.testOk")
        : localizeError(
            locale,
            result.error || "Hermes couldn’t save the change.",
          ),
    );
  }

  async function deleteServer() {
    if (!deleteName || busyName) return;
    const name = deleteName;
    setBusyName(name);
    setFeedback(null);
    const result = await mutateHermes({
      action: "mcp-delete",
      name,
      confirm: true,
    });
    if (!result.ok) {
      setFeedback(
        localizeError(
          locale,
          result.error || "Hermes couldn’t save the change.",
        ),
      );
      setBusyName(null);
      return;
    }
    await refresh();
    setBusyName(null);
    setDeleteName(null);
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      {loading ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">
          {t("addons.loading")}
        </p>
      ) : error ? (
        <p className="px-6 py-8 text-sm text-muted-foreground">
          {localizeError(locale, error)}
        </p>
      ) : (
        <CatalogPage
          kicker={t("addons.kicker")}
          title={t("addons.title")}
          description={
            data?.writable ? t("addons.descOn") : t("addons.descOff")
          }
          action={
            <Button
              onClick={() =>
                data?.writable
                  ? setAddOpen(true)
                  : void navigate({ to: "/connect" })
              }
              disabled={loading}
            >
              <Plus />
              {t("addons.add")}
            </Button>
          }
          groups={[{ id: "mcp", label: "MCP" }]}
          empty={t("addons.empty")}
          rows={rows.map((server) => ({
            id: server.id,
            title: server.name,
            name: server.name,
            description: server.detail,
            group: "mcp",
            groupLabel: server.transport.toUpperCase(),
            meta:
              server.auth && server.auth !== "none"
                ? server.auth.toUpperCase()
                : undefined,
            enabled: server.enabled,
          }))}
          onToggle={
            data?.writable
              ? (id) => {
                  const row = rows.find((server) => server.id === id);
                  if (!row || !data) return;
                  const enabled = !row.enabled;
                  setData({
                    ...data,
                    mcp: data.mcp.map((server) =>
                      server.id === id ? { ...server, enabled } : server,
                    ),
                  });
                  void mutateHermes({
                    action: "toggle-mcp",
                    name: row.name,
                    enabled,
                  }).then((result) => {
                    if (result.ok) return;
                    setData({
                      ...data,
                      mcp: data.mcp.map((server) =>
                        server.id === id
                          ? { ...server, enabled: row.enabled }
                          : server,
                      ),
                    });
                  });
                }
              : undefined
          }
          rowActions={
            data?.writable
              ? (row) => (
                  <>
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={Boolean(busyName)}
                      onClick={() => void testServer(row.name)}
                    >
                      {t("addons.test")}
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      disabled={Boolean(busyName)}
                      aria-label={t("addons.delete")}
                      onClick={() => setDeleteName(row.name)}
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </>
                )
              : undefined
          }
          chatPrompt={(row) => t("addons.prompt", { title: row.title })}
        />
      )}

      {feedback ? (
        <p
          role="status"
          className="fixed right-4 bottom-4 z-40 rounded-md bg-popover px-3 py-2 text-sm shadow-border"
        >
          {feedback}
        </p>
      ) : null}

      <McpServerDialog
        open={addOpen}
        onOpenChange={setAddOpen}
        onSave={saveServer}
      />

      <Dialog
        open={Boolean(deleteName)}
        onOpenChange={(next) => !next && !busyName && setDeleteName(null)}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t("addons.deleteTitle", { name: deleteName ?? "" })}
            </DialogTitle>
            <DialogDescription>
              {t("addons.deleteDescription")}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(busyName)}
              onClick={() => setDeleteName(null)}
            >
              {t("projects.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={Boolean(busyName)}
              onClick={() => void deleteServer()}
            >
              {busyName ? t("addons.removing") : t("addons.confirmDelete")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
