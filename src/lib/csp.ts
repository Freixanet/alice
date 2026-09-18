// Content-Security-Policy shared by the request middleware (per-request nonce)
// and the static fallback in vercel.json. This module must stay isomorphic: it
// is imported by both the server middleware and client-bundled code.

export const CSP_NONCE_HEADER = "x-alice-csp-nonce";

export function buildContentSecurityPolicy(nonce?: string): string {
  // Keeping 'unsafe-inline' alongside the nonce is deliberate: CSP3 engines
  // ignore it once a nonce is present (inline scripts still need the nonce),
  // while older engines keep working. vercel.json's static policy is enforced
  // on top of this one on Vercel, so removing the sandbox origins is enough.
  const scriptSrc = nonce
    ? `script-src 'self' 'nonce-${nonce}' 'unsafe-inline'`
    : "script-src 'self' 'unsafe-inline'";
  return [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "frame-ancestors 'self'",
    "img-src 'self' data: blob: https: http:",
    "font-src 'self' data: https://fonts.gstatic.com",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    scriptSrc,
    "connect-src 'self' https: http: ws: wss:",
    "form-action 'self'",
  ].join("; ");
}
