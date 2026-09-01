import { createFileRoute } from "@tanstack/react-router";
import {
  jsonWithCookie,
  listHermesModelsServer,
  modelsFromEndpoints,
  persistUserGate,
  probeHermes,
  resolveAliceGate,
  saveHermesCustomEndpointServer,
  sealGate,
  setHermesModelServer,
  upsertStoredEndpoint,
  fetchHermesMemory,
  getHermesRunServer,
  controlHermesRunServer,
} from "@/lib/gateway.server";
import type { GatewayPlace } from "@/lib/gateway";
import {
  assertGatewayKey,
  GatewayError,
  isPrivateHostname,
  normalizeGatewayUrl,
} from "@/lib/gateway";
import type { GateSecret } from "@/lib/gateway.server";
import { hermesRequestSchema } from "@/lib/api-contracts";
import { hermesMutationSchema } from "@/lib/hermes-operations";
import {
  assertSameOriginRequest,
  parseJsonRequest,
  requestErrorResponse,
} from "@/lib/http.server";
import {
  consumeSharedRateLimit,
  rateLimitResponse,
} from "@/lib/rate-limit.server";
import { observeApiRequest } from "@/lib/operational-telemetry.server";

const FAIL = "Couldn’t connect.";

function effectiveSavedPlace(
  saved: GateSecret | null,
  macOk: boolean,
): GatewayPlace | undefined {
  if (!saved) return undefined;
  if (saved.p === "mac" && macOk) return "mac";
  try {
    const host = new URL(normalizeGatewayUrl(saved.u)).hostname;
    if (isPrivateHostname(host)) return "device";
  } catch {
    // Keep the stored place; validation happens before a connection is saved.
  }
  return saved.p;
}

export const Route = createFileRoute("/api/hermes")({
  server: {
    handlers: {
      POST: observeApiRequest("/api/hermes", async ({ request }) => {
        try {
          assertSameOriginRequest(request);
        } catch (error) {
          return (
            requestErrorResponse(error) ??
            jsonWithCookie({ ok: false, code: "invalid", error: FAIL }, 400)
          );
        }
        const { saved, owner, local, userId } = await resolveAliceGate(request);
        if (!userId) {
          return jsonWithCookie(
            { ok: false, error: "Sign in to continue." },
            401,
          );
        }
        const rate = await consumeSharedRateLimit(
          "hermes",
          userId,
          240,
          60_000,
        );
        if (!rate.ok) return rateLimitResponse(rate);

        let body;
        try {
          body = await parseJsonRequest(request, hermesRequestSchema, 32_768);
        } catch (error) {
          return (
            requestErrorResponse(error) ??
            jsonWithCookie({ ok: false, code: "invalid", error: FAIL }, 400)
          );
        }

        const macOk = owner && local;

        if (body.action === "status") {
          return jsonWithCookie(
            {
              ok: true,
              hasKey: Boolean(saved?.k),
              url: saved?.u,
              place: effectiveSavedPlace(saved, macOk),
              owner,
              local,
              userId,
            },
            200,
          );
        }

        if (body.action === "device-secret") {
          if (
            !saved?.u ||
            !saved.k ||
            effectiveSavedPlace(saved, macOk) !== "device"
          ) {
            return jsonWithCookie({ ok: false }, 404);
          }
          return jsonWithCookie({ ok: true, url: saved.u, key: saved.k }, 200);
        }

        if (body.action === "store-device") {
          try {
            const url = normalizeGatewayUrl(body.url ?? "");
            const key = assertGatewayKey(body.key ?? "");
            const host = new URL(url).hostname;
            if (!isPrivateHostname(host)) {
              return jsonWithCookie(
                { ok: false, code: "invalid", error: FAIL },
                400,
              );
            }
            const token = sealGate({
              k: key,
              u: url,
              p: "device",
              ...(saved?.u === url && saved.ep ? { ep: saved.ep } : {}),
              uid: userId,
            });
            await persistUserGate(userId, token);
            return jsonWithCookie({ ok: true }, 200, token);
          } catch {
            return jsonWithCookie(
              { ok: false, code: "invalid", error: FAIL },
              400,
            );
          }
        }

        if (body.action === "forget") {
          await persistUserGate(userId, null);
          return jsonWithCookie({ ok: true }, 200, null);
        }

        if (body.action === "memory") {
          try {
            const result = await fetchHermesMemory({
              url: saved?.u,
              key: saved?.k,
              place: saved?.p,
              local: macOk,
              signal: AbortSignal.any([
                request.signal,
                AbortSignal.timeout(12_000),
              ]),
            });
            return jsonWithCookie(result, 200);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes memory." },
              502,
            );
          }
        }

        if (
          body.action === "run-status" ||
          body.action === "run-stop" ||
          body.action === "run-approval" ||
          body.action === "run-steer"
        ) {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          const signal = AbortSignal.any([
            request.signal,
            AbortSignal.timeout(12_000),
          ]);
          try {
            if (body.action === "run-status") {
              const run = await getHermesRunServer({
                url: saved.u,
                key: saved.k,
                place: saved.p,
                runId: body.runId,
                conversationId: body.conversationId,
                signal,
                profile: body.profile,
              });
              return jsonWithCookie(
                run
                  ? { ok: true, run }
                  : { ok: false, error: "Run not found." },
                run ? 200 : 404,
              );
            }
            const control =
              body.action === "run-stop"
                ? ({ action: "stop" } as const)
                : body.action === "run-steer"
                  ? ({ action: "steer", input: body.input } as const)
                  : ({
                      action: "approval",
                      choice: body.choice,
                      resolveAll: body.resolveAll,
                    } as const);
            const ok = await controlHermesRunServer({
              url: saved.u,
              key: saved.k,
              place: saved.p,
              runId: body.runId,
              ...control,
              signal,
              profile: body.profile,
            });
            return jsonWithCookie(
              ok
                ? { ok: true }
                : { ok: false, error: "Hermes rejected the request." },
              ok ? 200 : 409,
            );
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t reach this Hermes run." },
              502,
            );
          }
        }

        if (body.action === "session-messages") {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          try {
            const { fetchHermesSessionMessages } =
              await import("@/lib/hermes-live.server");
            const result = await fetchHermesSessionMessages(
              {
                url: saved.u,
                key: saved.k,
                place: saved.p,
                signal: AbortSignal.any([
                  request.signal,
                  AbortSignal.timeout(12_000),
                ]),
              },
              body.sessionId,
              body.profile,
            );
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read this Hermes session." },
              502,
            );
          }
        }

        if (
          body.action === "mcp-catalog" ||
          body.action === "mcp-probe" ||
          body.action === "mcp-oauth-start" ||
          body.action === "mcp-oauth-status" ||
          body.action === "mcp-usage"
        ) {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          const timeoutMs =
            body.action === "mcp-probe" || body.action === "mcp-oauth-start"
              ? 65_000
              : 15_000;
          const gate = {
            url: saved.u,
            key: saved.k,
            place: saved.p,
            signal: AbortSignal.any([
              request.signal,
              AbortSignal.timeout(timeoutMs),
            ]),
          };
          try {
            const {
              fetchHermesMcpCatalog,
              fetchHermesMcpOAuth,
              fetchHermesMcpUsage,
              startHermesMcpOAuth,
              testHermesMcpServer,
            } = await import("@/lib/hermes-live.server");
            const result =
              body.action === "mcp-catalog"
                ? await fetchHermesMcpCatalog(gate, body.profile)
                : body.action === "mcp-probe"
                  ? await testHermesMcpServer(gate, body.name, body.profile)
                  : body.action === "mcp-oauth-start"
                    ? await startHermesMcpOAuth(gate, body.name, body.profile)
                    : body.action === "mcp-oauth-status"
                      ? await fetchHermesMcpOAuth(
                          gate,
                          body.flowId,
                          body.profile,
                        )
                      : await fetchHermesMcpUsage(gate, body.profile);
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes MCP status." },
              502,
            );
          }
        }

        if (
          body.action === "skill-content" ||
          body.action === "toolset-details" ||
          body.action === "action-status" ||
          body.action === "skills-search"
        ) {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          const gate = {
            url: saved.u,
            key: saved.k,
            place: saved.p,
            signal: AbortSignal.any([
              request.signal,
              AbortSignal.timeout(20_000),
            ]),
          };
          try {
            const {
              fetchHermesActionStatus,
              fetchHermesSkillContent,
              fetchHermesToolsetDetails,
              searchHermesSkillsHub,
            } = await import("@/lib/hermes-live.server");
            const result =
              body.action === "skill-content"
                ? await fetchHermesSkillContent(gate, body.name, body.profile)
                : body.action === "toolset-details"
                  ? await fetchHermesToolsetDetails(
                      gate,
                      body.name,
                      body.profile,
                    )
                  : body.action === "action-status"
                    ? await fetchHermesActionStatus(
                        gate,
                        body.name,
                        body.profile,
                      )
                    : await searchHermesSkillsHub(
                        gate,
                        body.query,
                        body.profile,
                      );
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes skill status." },
              502,
            );
          }
        }

        if (body.action === "diagnostics") {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          try {
            const { fetchHermesDiagnostics } =
              await import("@/lib/hermes-live.server");
            const result = await fetchHermesDiagnostics({
              url: saved.u,
              key: saved.k,
              place: saved.p,
              signal: AbortSignal.any([
                request.signal,
                AbortSignal.timeout(12_000),
              ]),
            });
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes diagnostics." },
              502,
            );
          }
        }

        if (body.action === "system-tools") {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          try {
            const { fetchHermesSystemTools } =
              await import("@/lib/hermes-live.server");
            const result = await fetchHermesSystemTools(
              {
                url: saved.u,
                key: saved.k,
                place: saved.p,
                signal: AbortSignal.any([
                  request.signal,
                  AbortSignal.timeout(12_000),
                ]),
              },
              body.profile,
            );
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes system tools." },
              502,
            );
          }
        }

        if (body.action === "live") {
          try {
            const { fetchHermesLive } =
              await import("@/lib/hermes-live.server");
            const result = await fetchHermesLive({
              url: saved?.u,
              key: saved?.k,
              place: saved?.p,
              local: macOk,
              owner,
              profile: body.profile,
              signal: AbortSignal.any([
                request.signal,
                AbortSignal.timeout(20_000),
              ]),
            });
            return jsonWithCookie(result, 200);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes status." },
              502,
            );
          }
        }

        if (body.action === "profiles" || body.action === "profile-soul") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          const gate = {
            url: saved.u,
            key: saved.k,
            place: saved.p,
            signal: AbortSignal.any([
              request.signal,
              AbortSignal.timeout(12_000),
            ]),
          };
          try {
            const { fetchHermesProfiles, fetchHermesProfileSoul } =
              await import("@/lib/hermes-live.server");
            const result =
              body.action === "profiles"
                ? await fetchHermesProfiles(gate)
                : await fetchHermesProfileSoul(gate, body.name);
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes profiles." },
              502,
            );
          }
        }

        if (body.action === "insights") {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          try {
            const { fetchHermesInsights } =
              await import("@/lib/hermes-live.server");
            const result = await fetchHermesInsights(
              {
                url: saved.u,
                key: saved.k,
                place: saved.p,
                signal: AbortSignal.any([
                  request.signal,
                  AbortSignal.timeout(12_000),
                ]),
              },
              body.days,
              body.profile,
            );
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Couldn’t read Hermes insights." },
              502,
            );
          }
        }

        if (
          body.action === "rooms" ||
          body.action === "room-create" ||
          body.action === "room-send" ||
          body.action === "room-log"
        ) {
          if (!saved?.u || !saved.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          const gate = {
            url: saved.u,
            key: saved.k,
            place: saved.p,
            signal: AbortSignal.any([
              request.signal,
              AbortSignal.timeout(12_000),
            ]),
          };
          try {
            const { fetchHermesRooms, fetchHermesRoomLog, mutateHermesRoom } =
              await import("@/lib/hermes-live.server");
            const result =
              body.action === "rooms"
                ? await fetchHermesRooms(gate, body.profile)
                : body.action === "room-log"
                  ? await fetchHermesRoomLog(
                      gate,
                      body.roomId,
                      body.sinceSeq,
                      body.profile,
                    )
                  : await mutateHermesRoom(
                      gate,
                      body.action === "room-create"
                        ? {
                            action: "create",
                            roomId: body.roomId,
                            name: body.name,
                            members: body.members,
                          }
                        : {
                            action: "send",
                            roomId: body.roomId,
                            eventId: body.eventId,
                            message: body.message,
                          },
                      body.profile,
                    );
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Hermes group chat is unavailable." },
              502,
            );
          }
        }

        if (body.action === "mutate") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          try {
            const { mutateHermesLive } =
              await import("@/lib/hermes-live.server");
            const result = await mutateHermesLive(
              {
                url: saved.u,
                key: saved.k,
                place: saved.p,
                local: macOk,
                signal: AbortSignal.any([
                  request.signal,
                  AbortSignal.timeout(12_000),
                ]),
              },
              body.mutation,
              body.profile,
            );
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Hermes couldn’t save the change." },
              502,
            );
          }
        }

        const mutation = hermesMutationSchema.safeParse(body);
        if (mutation.success) {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          try {
            const { mutateHermesLive } =
              await import("@/lib/hermes-live.server");
            const result = await mutateHermesLive(
              {
                url: saved.u,
                key: saved.k,
                place: saved.p,
                local: macOk,
                signal: AbortSignal.any([
                  request.signal,
                  AbortSignal.timeout(12_000),
                ]),
              },
              mutation.data,
            );
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie(
              { ok: false, error: "Hermes couldn’t save the change." },
              502,
            );
          }
        }

        if (body.action === "models") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie({ ok: false, models: [] }, 400);
          }
          try {
            const listed = await listHermesModelsServer(
              saved.u,
              saved.k,
              AbortSignal.any([request.signal, AbortSignal.timeout(20_000)]),
              Boolean(body.refresh),
              saved.p,
              body.profile,
            );
            const extra = modelsFromEndpoints(saved.ep, body.profile);
            const models = [...listed.models];
            for (const item of extra) {
              if (
                !models.some(
                  (row) => row.id === item.id && row.provider === item.provider,
                )
              ) {
                models.push(item);
              }
            }
            return jsonWithCookie({ ok: true, ...listed, models }, 200);
          } catch {
            const extra = modelsFromEndpoints(saved.ep, body.profile);
            if (extra.length)
              return jsonWithCookie({ ok: true, models: extra }, 200);
            return jsonWithCookie({ ok: false, models: [] }, 502);
          }
        }

        if (body.action === "set-model") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie({ ok: false }, 400);
          }
          const model = body.model;
          const provider = body.provider;
          try {
            const result = await setHermesModelServer({
              url: saved.u,
              key: saved.k,
              model,
              provider,
              conversationId: body.conversationId,
              signal: AbortSignal.any([
                request.signal,
                AbortSignal.timeout(12_000),
              ]),
              place: saved.p,
              profile: body.profile,
            });
            return jsonWithCookie(result, result.ok ? 200 : 502);
          } catch {
            return jsonWithCookie({ ok: false }, 502);
          }
        }

        if (body.action === "custom-endpoint") {
          if (!saved?.u || !saved?.k) {
            return jsonWithCookie(
              { ok: false, error: "Connect your Hermes first." },
              400,
            );
          }
          const endpointUrl = body.endpointUrl;
          try {
            const result = await saveHermesCustomEndpointServer({
              url: saved.u,
              key: saved.k,
              place: saved.p,
              name: body.endpointName ?? "",
              baseUrl: endpointUrl,
              apiKey: body.endpointKey ?? "",
              model: body.endpointModel,
              profile: body.profile,
              signal: AbortSignal.any([
                request.signal,
                AbortSignal.timeout(20_000),
              ]),
            });
            if (!result.ok || !result.persist) {
              return jsonWithCookie(result, result.ok ? 200 : 502);
            }
            const token = sealGate({
              k: saved.k,
              u: saved.u,
              p: saved.p,
              ep: upsertStoredEndpoint(saved.ep, result.persist),
              ...(userId ? { uid: userId } : {}),
            });
            await persistUserGate(userId, token);
            return jsonWithCookie(
              {
                ok: true,
                model: result.model,
                provider: result.provider,
                models: result.models,
              },
              200,
              token,
            );
          } catch (e) {
            if (e instanceof GatewayError) {
              const message =
                e.code === "private"
                  ? "Your Hermes is local. Choose “On this Mac”."
                  : e.code === "unauthorized"
                    ? "The key is not correct."
                    : "Hermes isn’t responding. Reconnect it above.";
              return jsonWithCookie({ ok: false, error: message }, 502);
            }
            return jsonWithCookie(
              {
                ok: false,
                error: "Hermes isn’t responding. Reconnect it above.",
              },
              502,
            );
          }
        }

        if (body.action !== "probe" && body.action !== "connect") {
          return jsonWithCookie(
            { ok: false, code: "invalid", error: FAIL },
            400,
          );
        }

        const url = body.url || saved?.u;
        const key = body.key || saved?.k;
        if (!url || !key) {
          return jsonWithCookie(
            { ok: false, code: "invalid", error: FAIL },
            400,
          );
        }

        const place: GatewayPlace = body.place === "mac" ? "mac" : "cloud";
        if (place === "mac" && !macOk) {
          return jsonWithCookie(
            {
              ok: false,
              code: "private",
              error: "Connect your Hermes with a public address.",
            },
            400,
          );
        }
        const result = await probeHermes(
          url,
          key,
          AbortSignal.any([request.signal, AbortSignal.timeout(12_000)]),
          place,
        );

        const status = result.ok
          ? 200
          : result.code === "unauthorized"
            ? 401
            : result.code === "private" || result.code === "invalid"
              ? 400
              : 502;

        if (body.action === "connect" && result.ok) {
          if (!userId) {
            return jsonWithCookie(
              { ok: false, error: "Sign in to continue." },
              401,
            );
          }
          const token = sealGate({
            k: key,
            u: url,
            p: place,
            ep: saved?.ep,
            ...(userId ? { uid: userId } : {}),
          });
          await persistUserGate(userId, token);
          return jsonWithCookie(result, 200, token);
        }

        return jsonWithCookie(result, status);
      }),
    },
  },
});
