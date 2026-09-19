import { createMiddleware, createStart } from "@tanstack/react-start";
import { getRequest, setResponseHeader } from "@tanstack/react-start/server";
import { randomBytes } from "node:crypto";
import { CSP_NONCE_HEADER, buildContentSecurityPolicy } from "./lib/csp";

const cspRequestMiddleware = createMiddleware({ type: "request" }).server(
  ({ next }) => {
    // Dev mode must keep unnonced inline scripts: Vite injects its react-refresh
    // preamble as an inline module script we cannot reach with a nonce.
    if (import.meta.env.DEV) return next();
    const nonce = randomBytes(16).toString("base64");
    // getRequest() returns the request's mutable Headers store; the router reads
    // this header in getRouter() to stamp `ssr.nonce` onto every inline script.
    getRequest().headers.set(CSP_NONCE_HEADER, nonce);
    setResponseHeader(
      "Content-Security-Policy",
      buildContentSecurityPolicy(nonce),
    );
    return next();
  },
);

export const startInstance = createStart(() => ({
  requestMiddleware: [cspRequestMiddleware],
}));
