import { useCurrentUser } from "@/lib/auth/use-current-user";
import { useCloudSyncRuntime } from "@/lib/cloud-sync-runtime";
import { useHermes } from "@/lib/store";
import { cn } from "@/lib/utils";

const LABELS = {
  en: {
    idle: "Pending",
    syncing: "Syncing…",
    synced: "Synced",
    pending: "Pending",
    offline: "Offline",
    "key-mismatch": "Wrong key",
    "quota-exceeded": "Cloud quota exhausted",
    error: "Sync error",
    last: "Last sync",
  },
  es: {
    idle: "Pendiente",
    syncing: "Sincronizando…",
    synced: "Sincronizado",
    pending: "Pendiente",
    offline: "Sin conexión",
    "key-mismatch": "Clave incorrecta",
    "quota-exceeded": "Cuota agotada",
    error: "Error de sincronización",
    last: "Última sincronización",
  },
} as const;

export function CloudSyncStatusIndicator() {
  const user = useCurrentUser();
  const enabled = useHermes((state) => state.cloudSyncEnabled);
  const locale = useHermes((state) => state.locale);
  const runtime = useCloudSyncRuntime();

  if (!enabled || !user || runtime.userId !== user.id) return null;

  const copy = LABELS[locale === "es" ? "es" : "en"];
  const last = runtime.lastSyncedAt
    ? new Intl.DateTimeFormat(locale === "es" ? "es-ES" : "en-US", {
        day: "2-digit",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      }).format(runtime.lastSyncedAt)
    : null;
  const severe =
    runtime.status === "key-mismatch" ||
    runtime.status === "quota-exceeded" ||
    runtime.status === "error";

  return (
    <div
      role="status"
      aria-live="polite"
      className={cn(
        "pointer-events-none fixed right-3 bottom-3 z-50 max-w-[calc(100vw-1.5rem)] rounded-lg border border-border bg-popover/95 px-3 py-2 text-xs shadow-sm backdrop-blur",
        severe && "text-destructive",
      )}
    >
      <div className="flex items-center gap-2">
        <span
          aria-hidden
          className={cn(
            "size-1.5 shrink-0 rounded-full bg-muted-foreground",
            runtime.status === "synced" && "bg-foreground",
            severe && "bg-destructive",
          )}
        />
        <span className="font-medium">{copy[runtime.status]}</span>
        {runtime.status === "pending" && runtime.pendingCount > 0 ? (
          <span className="text-muted-foreground">{runtime.pendingCount}</span>
        ) : null}
      </div>
      {last ? (
        <div
          className={cn(
            "mt-0.5 text-muted-foreground",
            severe && "text-current/70",
          )}
        >
          {copy.last}: {last}
        </div>
      ) : null}
    </div>
  );
}
