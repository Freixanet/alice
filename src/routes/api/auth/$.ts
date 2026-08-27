import { createFileRoute } from "@tanstack/react-router";
import { auth } from "@/lib/auth/server";

async function handle({ request }: { request: Request }) {
  const incoming = new URL(request.url);
  const res = await auth.handler(request);
  if (!incoming.pathname.includes("/callback/")) return res;

  const location = res.headers.get("location") ?? "";
  console.info("[auth] OAuth callback response", {
    status: res.status,
    location: location.replace(/token=[^&]+/i, "token=…"),
    cookies: cookieNames(res),
    hasAuthToken: Boolean(res.headers.get("set-auth-token")),
  });
  return res;
}

function cookieNames(res: Response): string[] {
  const headers = res.headers as Headers & { getSetCookie?: () => string[] };
  const lines =
    typeof headers.getSetCookie === "function"
      ? headers.getSetCookie()
      : res.headers.get("set-cookie")
        ? [res.headers.get("set-cookie") as string]
        : [];
  return lines.map((line) => line.split("=", 1)[0] ?? "");
}

export const Route = createFileRoute("/api/auth/$")({
  server: {
    handlers: {
      GET: handle,
      POST: handle,
      PUT: handle,
      PATCH: handle,
      DELETE: handle,
    },
  },
});
