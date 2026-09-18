import { createRouter } from "@tanstack/react-router";
import { AppErrorComponent, AppNotFoundComponent } from "@/lib/error-component";
import { CSP_NONCE_HEADER } from "./lib/csp";
import { routeTree } from "./routeTree.gen";

export async function getRouter() {
  // The request middleware stamps a per-request nonce onto the request headers;
  // forwarding it here lets SSR inline scripts and streamed scripts carry
  // `nonce=` attributes. The dynamic import keeps server-only code out of the
  // client bundle; on the client `ssr.nonce` is restored from the
  // `meta[property="csp-nonce"]` tag emitted during SSR.
  const nonce = import.meta.env.SSR
    ? (await import("@tanstack/react-start/server")).getRequestHeader(
        CSP_NONCE_HEADER,
      )
    : undefined;
  return createRouter({
    routeTree,
    defaultErrorComponent: AppErrorComponent,
    defaultNotFoundComponent: AppNotFoundComponent,
    defaultPreload: "intent",
    scrollRestoration: true,
    ssr: { nonce },
  });
}
