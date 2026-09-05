import { useCloudSync } from "@/lib/use-cloud-sync";
import { CloudSyncStatusIndicator } from "@/components/cloud-sync-status";

/**
 * The sync loop and the line that reports on it, mounted together.
 *
 * They are one component so that one lazy import keeps both off the chunk a
 * signed-in page loads before it can render anything. Sync is a background
 * effect — the replicas, the crypto and the merge are several kilobytes that
 * nothing on screen waits for — and the status line only ever appears once
 * that machinery is already running.
 */
export function CloudSync() {
  useCloudSync();
  return <CloudSyncStatusIndicator />;
}
