export type ReleaseEnvironment = "development" | "preview" | "production";

export type ReleaseMetadata = {
  version: string;
  environment: ReleaseEnvironment;
  source: "local" | "vercel";
};

type ReleaseEnvironmentInput = Readonly<Record<string, string | undefined>>;

const SAFE_VERSION = /^[a-zA-Z0-9._-]{1,32}$/;

function safeVersion(value: string | undefined): string | undefined {
  const candidate = value?.trim().slice(0, 32);
  return candidate && SAFE_VERSION.test(candidate) ? candidate : undefined;
}

function releaseEnvironment(
  environment: ReleaseEnvironmentInput,
): ReleaseEnvironment {
  if (environment.VERCEL_ENV === "production") return "production";
  if (environment.VERCEL_ENV === "preview") return "preview";
  return "development";
}

export function releaseMetadata(
  environment: ReleaseEnvironmentInput = process.env,
): ReleaseMetadata {
  const commit = safeVersion(environment.VERCEL_GIT_COMMIT_SHA)?.slice(0, 12);
  const configured = safeVersion(environment.ALICE_VERSION);
  return {
    version: commit ?? configured ?? "development",
    environment: releaseEnvironment(environment),
    source: environment.VERCEL === "1" ? "vercel" : "local",
  };
}

export function appendReleaseHeaders(
  headers: Headers,
  metadata: ReleaseMetadata = releaseMetadata(),
): void {
  headers.set("X-Alice-Version", metadata.version);
  headers.set("X-Alice-Environment", metadata.environment);
}
