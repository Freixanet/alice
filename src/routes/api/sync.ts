import { createFileRoute } from "@tanstack/react-router";
import { requireUserId, UnauthorizedError } from "@/lib/auth/verify.server";
import { getSql } from "@/lib/db";
import { parseJsonRequest, requestErrorResponse } from "@/lib/http.server";
import { consumeRateLimit, rateLimitResponse } from "@/lib/rate-limit.server";
import { syncRequestSchema } from "@/lib/sync-contracts";
import {
  CLOUD_SYNC_QUOTA_BYTES,
  getEncryptedSyncUsage,
  pullEncryptedSyncRecords,
  pushEncryptedSyncRecords,
  SyncQuotaError,
} from "@/lib/sync-store.server";

const MAX_REQUEST_BYTES = 16 * 1024 * 1024;

function json(value: unknown, status = 200) {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

export const Route = createFileRoute("/api/sync")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        let userId: string;
        try {
          userId = await requireUserId();
        } catch (error) {
          if (error instanceof UnauthorizedError)
            return json({ ok: false, error: { code: "unauthorized" } }, 401);
          throw error;
        }
        const rate = consumeRateLimit("sync", userId, 120, 60_000);
        if (!rate.ok) return rateLimitResponse(rate);

        let body;
        try {
          body = await parseJsonRequest(
            request,
            syncRequestSchema,
            MAX_REQUEST_BYTES,
          );
        } catch (error) {
          return (
            requestErrorResponse(error) ??
            json({ ok: false, error: { code: "invalid_request" } }, 400)
          );
        }

        const sql = await getSql();
        if (body.action === "pull") {
          const cursor = Number(body.cursor ?? "0");
          const result = await pullEncryptedSyncRecords(
            sql,
            userId,
            cursor,
            body.limit ?? 100,
          );
          return json({
            ok: true,
            ...result,
            cursor: String(result.cursor),
          });
        }
        if (body.action === "quota") {
          const used = await getEncryptedSyncUsage(sql, userId);
          return json({ ok: true, used, limit: CLOUD_SYNC_QUOTA_BYTES });
        }
        try {
          const result = await pushEncryptedSyncRecords(
            sql,
            userId,
            body.requestId,
            body.records,
          );
          return json({ ok: true, ...result });
        } catch (error) {
          if (error instanceof SyncQuotaError) {
            return json(
              { ok: false, error: { code: "cloud_quota_exceeded" } },
              409,
            );
          }
          throw error;
        }
      },
    },
  },
});
