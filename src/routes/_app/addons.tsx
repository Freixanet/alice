import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Download, Plus, RefreshCw, Trash2 } from "lucide-react";
import { useState } from "react";
import { CatalogPage } from "@/components/catalog-page";
import { McpServerDialog } from "@/components/mcp-server-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
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
  const plugins = data?.plugins ?? [];
  const pluginsSupported = data?.pluginsSupported === true;
  const [addOpen, setAddOpen] = useState(false);
  const [pluginOpen, setPluginOpen] = useState(false);
  const [pluginIdentifier, setPluginIdentifier] = useState("");
  const [deleteName, setDeleteName] = useState<string | null>(null);
  const [deletePluginName, setDeletePluginName] = useState<string | null>(null);
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

  async function installPlugin() {
    const identifier = pluginIdentifier.trim();
    if (!identifier || busyName) return;
    setBusyName(identifier);
    setFeedback(null);
    const result = await mutateHermes({
      action: "plugin-install",
      identifier,
      enable: true,
    });
    if (result.ok && (await refresh())) {
      setPluginIdentifier("");
      setPluginOpen(false);
      setFeedback(t("addons.pluginInstalled"));
    } else if (!result.ok) {
      setFeedback(localizeError(locale, result.error));
    }
    setBusyName(null);
  }

  async function updatePlugin(name: string) {
    if (busyName) return;
    setBusyName(name);
    setFeedback(null);
    const result = await mutateHermes({ action: "plugin-update", name });
    if (result.ok) {
      await refresh();
      setFeedback(t("addons.pluginUpdated"));
    } else setFeedback(localizeError(locale, result.error));
    setBusyName(null);
  }

  async function deletePlugin() {
    if (!deletePluginName || busyName) return;
    const name = deletePluginName;
    setBusyName(name);
    setFeedback(null);
    const result = await mutateHermes({
      action: "plugin-delete",
      name,
      confirm: true,
    });
    if (result.ok) {
      await refresh();
      setDeletePluginName(null);
    } else setFeedback(localizeError(locale, result.error));
    setBusyName(null);
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
            <div className="flex flex-wrap gap-2">
              {pluginsSupported ? (
                <Button
                  variant="outline"
                  onClick={() =>
                    data?.writable
                      ? setPluginOpen(true)
                      : void navigate({ to: "/connect" })
                  }
                  disabled={loading}
                >
                  <Download />
                  {t("addons.installPlugin")}
                </Button>
              ) : null}
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
            </div>
          }
          groups={[
            ...(pluginsSupported
              ? [{ id: "plugins", label: t("addons.plugins") }]
              : []),
            { id: "mcp", label: "MCP" },
          ]}
          empty={t("addons.empty")}
          rows={[
            ...plugins.map((plugin) => ({
              id: plugin.id,
              title: plugin.name,
              name: plugin.name,
              description: plugin.description,
              group: "plugins",
              groupLabel: plugin.source,
              version: plugin.version,
              meta: plugin.authRequired
                ? t("addons.pluginNeedsAuth")
                : plugin.status,
              enabled: plugin.enabled,
            })),
            ...rows.map((server) => ({
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
            })),
          ]}
          onToggle={
            data?.writable
              ? (id) => {
                  const plugin = plugins.find((item) => item.id === id);
                  if (plugin && data) {
                    const enabled = !plugin.enabled;
                    setData({
                      ...data,
                      plugins: data.plugins.map((item) =>
                        item.id === id
                          ? {
                              ...item,
                              enabled,
                              status: enabled ? "enabled" : "disabled",
                            }
                          : item,
                      ),
                    });
                    void mutateHermes({
                      action: "toggle-plugin",
                      name: plugin.name,
                      enabled,
                    }).then((result) => {
                      if (result.ok) return;
                      setData(data);
                      setFeedback(localizeError(locale, result.error));
                    });
                    return;
                  }
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
                    {row.group === "plugins" ? (
                      <>
                        {plugins.find((item) => item.name === row.name)
                          ?.canUpdate ? (
                          <Button
                            variant="ghost"
                            size="icon-sm"
                            disabled={Boolean(busyName)}
                            aria-label={t("addons.updatePlugin", {
                              name: row.name,
                            })}
                            onClick={() => void updatePlugin(row.name)}
                          >
                            <RefreshCw className="size-4" />
                          </Button>
                        ) : null}
                        {plugins.find((item) => item.name === row.name)
                          ?.canRemove ? (
                          <Button
                            variant="ghost"
                            size="icon-sm"
                            disabled={Boolean(busyName)}
                            aria-label={t("addons.removePlugin", {
                              name: row.name,
                            })}
                            onClick={() => setDeletePluginName(row.name)}
                          >
                            <Trash2 className="size-4" />
                          </Button>
                        ) : null}
                      </>
                    ) : (
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
                    )}
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
        open={pluginOpen}
        onOpenChange={(next) => !busyName && setPluginOpen(next)}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{t("addons.installPluginTitle")}</DialogTitle>
            <DialogDescription>
              {t("addons.installPluginDescription")}
            </DialogDescription>
          </DialogHeader>
          <label className="space-y-2 text-sm">
            <span>{t("addons.pluginSource")}</span>
            <Input
              value={pluginIdentifier}
              onChange={(event) => setPluginIdentifier(event.target.value)}
              placeholder={t("addons.pluginSourcePlaceholder")}
              autoComplete="off"
            />
          </label>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(busyName)}
              onClick={() => setPluginOpen(false)}
            >
              {t("projects.cancel")}
            </Button>
            <Button
              disabled={Boolean(busyName) || !pluginIdentifier.trim()}
              onClick={() => void installPlugin()}
            >
              {busyName
                ? t("addons.installingPlugin")
                : t("addons.installPlugin")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

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

      <Dialog
        open={Boolean(deletePluginName)}
        onOpenChange={(next) => !next && !busyName && setDeletePluginName(null)}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t("addons.removePluginTitle", {
                name: deletePluginName ?? "",
              })}
            </DialogTitle>
            <DialogDescription>
              {t("addons.removePluginDescription")}
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              disabled={Boolean(busyName)}
              onClick={() => setDeletePluginName(null)}
            >
              {t("projects.cancel")}
            </Button>
            <Button
              variant="destructive"
              disabled={Boolean(busyName)}
              onClick={() => void deletePlugin()}
            >
              {busyName ? t("addons.removing") : t("addons.confirmDelete")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
