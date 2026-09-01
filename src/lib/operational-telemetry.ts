import { z } from "zod";

export const operationalRouteSchema = z.enum([
  "/",
  "/agents",
  "/skills",
  "/tools",
  "/addons",
  "/projects",
  "/artifacts",
  "/memory",
  "/cron",
  "/insights",
  "/connect",
  "/settings",
  "/login",
  "/auth/complete",
  "other",
]);

export const browserFamilySchema = z.enum([
  "chromium",
  "edge",
  "firefox",
  "safari",
  "other",
]);

export const viewportBucketSchema = z.enum([
  "compact",
  "narrow",
  "medium",
  "wide",
]);

const clientContextSchema = {
  route: operationalRouteSchema,
  browser: browserFamilySchema,
  viewport: viewportBucketSchema,
} as const;

export const clientOperationalEventSchema = z.discriminatedUnion("kind", [
  z.strictObject({
    kind: z.literal("navigation"),
    ...clientContextSchema,
    latencyMs: z.number().int().min(0).max(120_000),
  }),
  z.strictObject({
    kind: z.literal("client_error"),
    ...clientContextSchema,
    code: z.enum(["runtime_error", "unhandled_rejection", "route_error"]),
  }),
]);

export type ClientOperationalEvent = z.infer<
  typeof clientOperationalEventSchema
>;
export type OperationalRoute = z.infer<typeof operationalRouteSchema>;
export type BrowserFamily = z.infer<typeof browserFamilySchema>;
export type ViewportBucket = z.infer<typeof viewportBucketSchema>;

const KNOWN_ROUTES = new Set<OperationalRoute>(operationalRouteSchema.options);

export function normalizeOperationalRoute(pathname: string): OperationalRoute {
  const route = pathname.split(/[?#]/, 1)[0] || "/";
  return KNOWN_ROUTES.has(route as OperationalRoute)
    ? (route as OperationalRoute)
    : "other";
}

export function browserFamily(userAgent: string): BrowserFamily {
  if (/\b(?:Edg|EdgiOS|EdgA)\//i.test(userAgent)) return "edge";
  if (/\b(?:Firefox|FxiOS)\//i.test(userAgent)) return "firefox";
  if (
    /\bSafari\//i.test(userAgent) &&
    !/\b(?:Chrome|CriOS|Chromium|Android)\//i.test(userAgent)
  ) {
    return "safari";
  }
  if (/\b(?:Chrome|CriOS|Chromium)\//i.test(userAgent)) return "chromium";
  return "other";
}

export function viewportBucket(width: number): ViewportBucket {
  if (width < 360) return "compact";
  if (width < 768) return "narrow";
  if (width < 1280) return "medium";
  return "wide";
}

export function boundedLatency(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(120_000, Math.max(0, Math.round(value)));
}
