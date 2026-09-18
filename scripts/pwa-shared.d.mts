export declare const DEFAULT_APP_NAME: string;
export declare const SITE_REL_PATH: string;
export declare const PWA_BASE: string;
export declare function escapeHtml(value: unknown): string;
export declare function publicAppHost(
  hostHeader: string | null | undefined,
): string;
export declare function isDocumentPath(
  pathname: string | null | undefined,
): boolean;
export declare function acceptsHtml(accept: string | null | undefined): boolean;
export declare function renderWebManifest(): string;
export declare function pwaHeadTags(appName?: string): Array<[string, string]>;

export type Site = {
  title?: string;
  description?: string;
  type?: string;
  card?: string;
  image?: string;
  banner?: string;
  color?: string;
};

export type HeadContext = {
  appName?: string;
  host?: string | null;
  cwd?: string;
  site?: Site;
};

export declare function readSite(cwd?: string): Site;
export declare function ogHeadTags(ctx?: {
  host?: string;
  site?: Site;
  documentTitle?: string;
  cwd?: string;
}): string[];
export declare function stripShareMetaTags(html: string): string;
export declare function normalizeHeadContext(ctx?: HeadContext): {
  appName: string;
  host: string;
  cwd: string;
  site: Site;
};
export declare function injectPwaHead(html: string, ctx?: HeadContext): string;
export declare function createHeadInjector(ctx?: HeadContext): {
  push(chunk: Uint8Array | string): Uint8Array[];
  flush(): Uint8Array[];
};
