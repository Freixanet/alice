import { createIsomorphicFn } from "@tanstack/react-start";
import { createRouter } from "@tanstack/react-router";
import { AppErrorComponent, AppNotFoundComponent } from "@/lib/error-component";
import { CSP_NONCE_HEADER } from "./lib/csp";
import { routeTree } from "./routeTree.gen";

const getCspNonce = createIsomorphicFn().server(async () =>
  (await import("@tanstack/react-start/server")).getRequestHeader(
    CSP_NONCE_HEADER,
  ),
);

export async function getRouter() {
  // The server implementation reads the per-request CSP nonce. TanStack removes
  // it from the client bundle, where SSR restores the nonce from the meta tag.
  const nonce = await getCspNonce();
  return createRouter({
    routeTree,
    defaultErrorComponent: AppErrorComponent,
    defaultNotFoundComponent: AppNotFoundComponent,
    defaultPreload: "intent",
    scrollRestoration: true,
    ssr: { nonce },
  });
}
