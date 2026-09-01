import { createFileRoute, Navigate, useNavigate } from "@tanstack/react-router";
import { useState, type FormEvent } from "react";
import { Mark, Wordmark } from "@/components/logo";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  authClient,
  authEnabled,
  LOGIN_SOCIAL,
  setBearerToken,
  signInWithSocial,
  type SocialProviderId,
} from "@/lib/auth/client";
import { useCurrentUserState } from "@/lib/auth/use-current-user";
import { SessionBoundary } from "@/lib/auth/session-boundary";
import type { MsgKey } from "@/lib/i18n";
import { useDocumentLocale, useT } from "@/lib/use-i18n";

export const Route = createFileRoute("/login")({
  validateSearch: (search: Record<string, unknown>) => ({
    error: typeof search.error === "string" ? search.error : undefined,
  }),
  component: LoginRoute,
});

function LoginRoute() {
  return (
    <SessionBoundary>
      <LoginPage />
    </SessionBoundary>
  );
}

function LoginPage() {
  useDocumentLocale();
  const t = useT();
  const { user, isPending } = useCurrentUserState();
  const navigate = useNavigate();
  const { error: oauthError } = Route.useSearch();
  const [mode, setMode] = useState<"in" | "up">("in");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState<"form" | SocialProviderId | null>(null);
  const [error, setError] = useState<string | null>(
    oauthError ? friendlyOAuthError(oauthError, t) : null,
  );

  if (!authEnabled) return <Navigate to="/" />;
  if (!isPending && user && !user.isDevFallback) return <Navigate to="/" />;

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy("form");
    setError(null);
    try {
      if (mode === "up") {
        const { data, error: err } = await authClient.signUp.email({
          email: email.trim(),
          password,
          name: name.trim() || email.trim().split("@")[0] || "Alice",
        });
        if (err) {
          setError(friendlyAuthError(err.message, t));
          return;
        }
        if (data?.token) setBearerToken(data.token);
      } else {
        const { data, error: err } = await authClient.signIn.email({
          email: email.trim(),
          password,
        });
        if (err) {
          setError(friendlyAuthError(err.message, t));
          return;
        }
        if (data?.token) setBearerToken(data.token);
      }
      await authClient.getSession();
      await navigate({ to: "/" });
    } catch {
      setError(t("login.fail"));
    } finally {
      setBusy(null);
    }
  }

  async function continueWith(provider: SocialProviderId) {
    setBusy(provider);
    setError(null);
    try {
      await signInWithSocial(provider);
    } catch {
      setError(
        provider === "google" ? t("login.failGoogle") : t("login.failApple"),
      );
      setBusy(null);
    }
  }

  return (
    <div className="flex min-h-svh items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex items-center gap-2">
          <Mark className="size-8" />
          <Wordmark className="text-4xl" />
        </div>
        <h1 className="font-serif text-3xl tracking-tight">
          {mode === "in" ? t("login.titleIn") : t("login.titleUp")}
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          {t("login.subtitle")}
        </p>
        <div className="mt-6 flex flex-col gap-2">
          {LOGIN_SOCIAL.filter((provider) => provider.id !== "apple").map(
            (provider) => (
              <Button
                key={provider.id}
                type="button"
                variant="outline"
                disabled={busy !== null}
                onClick={() => void continueWith(provider.id)}
              >
                {provider.id === "google" ? <GoogleMark /> : <AppleMark />}
                {busy === provider.id
                  ? t("login.wait")
                  : provider.id === "google"
                    ? t("login.continueGoogle")
                    : t("login.continueApple")}
              </Button>
            ),
          )}
        </div>
        <div className="relative my-6">
          <div className="h-px bg-border" />
          <span className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 bg-background px-2 text-xs text-muted-foreground">
            {t("login.or")}
          </span>
        </div>
        <form className="flex flex-col gap-3" onSubmit={(e) => void submit(e)}>
          {mode === "up" ? (
            <label className="flex flex-col gap-1.5 text-sm">
              {t("login.name")}
              <Input
                value={name}
                onChange={(e) => setName(e.target.value)}
                autoComplete="name"
              />
            </label>
          ) : null}
          <label className="flex flex-col gap-1.5 text-sm">
            {t("login.email")}
            <Input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              required
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            {t("login.password")}
            <Input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === "up" ? "new-password" : "current-password"}
              required
              minLength={8}
            />
          </label>
          {error ? <p className="text-sm text-destructive">{error}</p> : null}
          <Button
            type="submit"
            disabled={busy !== null || !email.trim() || password.length < 8}
          >
            {busy === "form"
              ? t("login.wait")
              : mode === "in"
                ? t("login.enter")
                : t("login.create")}
          </Button>
        </form>
        <p className="mt-4 text-sm text-muted-foreground">
          {mode === "in" ? t("login.noAccount") : t("login.hasAccount")}{" "}
          <button
            type="button"
            className="text-foreground underline-offset-2 hover:underline"
            onClick={() => {
              setMode(mode === "in" ? "up" : "in");
              setError(null);
            }}
          >
            {mode === "in" ? t("login.createIt") : t("login.signInInstead")}
          </button>
        </p>
      </div>
    </div>
  );
}

function GoogleMark() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden className="size-4">
      <path
        fill="#4285F4"
        d="M23.49 12.27c0-.79-.07-1.54-.2-2.27H12v4.51h6.48a5.54 5.54 0 0 1-2.4 3.64v3.02h3.88c2.27-2.09 3.53-5.17 3.53-8.9Z"
      />
      <path
        fill="#34A853"
        d="M12 24c3.24 0 5.96-1.07 7.95-2.91l-3.88-3.02c-1.08.72-2.45 1.15-4.07 1.15-3.13 0-5.78-2.11-6.73-4.96H1.27v3.11A12 12 0 0 0 12 24Z"
      />
      <path
        fill="#FBBC05"
        d="M5.27 14.26A7.21 7.21 0 0 1 4.89 12c0-.79.14-1.55.38-2.26V6.63H1.27A12 12 0 0 0 0 12c0 1.94.46 3.77 1.27 5.37l4-3.11Z"
      />
      <path
        fill="#EA4335"
        d="M12 4.75c1.76 0 3.33.6 4.58 1.79l3.43-3.43C17.95 1.19 15.24 0 12 0 7.31 0 3.26 2.69 1.27 6.63l4 3.11C6.22 6.86 8.87 4.75 12 4.75Z"
      />
    </svg>
  );
}

function AppleMark() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden className="size-4 fill-current">
      <path d="M16.37 12.63c.02 2.14 1.88 2.85 1.9 2.86-.02.05-.3 1.02-1 2.02-.6.86-1.23 1.72-2.21 1.74-.96.02-1.27-.57-2.37-.57s-1.45.55-2.36.59c-.95.04-1.67-.93-2.28-1.79-1.25-1.76-2.2-4.97-.92-7.14.64-1.08 1.78-1.77 3.02-1.79.94-.02 1.83.63 2.37.63s1.61-.78 2.72-.67c.46.02 1.76.19 2.59 1.41-.07.04-1.55.9-1.53 2.71ZM14.7 7.4c.51-.62.85-1.48.76-2.34-.73.03-1.62.49-2.15 1.1-.47.54-.89 1.42-.78 2.25.83.06 1.67-.42 2.17-1.01Z" />
    </svg>
  );
}

function friendlyOAuthError(code: string, t: (key: MsgKey) => string) {
  const m = code.toLowerCase();
  if (m.includes("state") || m.includes("please_restart")) {
    return t("login.googleRestart");
  }
  if (m.includes("denied") || m.includes("access_denied"))
    return t("login.googleDenied");
  return t("login.failGoogle");
}

function friendlyAuthError(
  message: string | undefined,
  t: (key: MsgKey) => string,
) {
  const m = (message || "").toLowerCase();
  if (m.includes("already") || m.includes("exists"))
    return t("login.emailExists");
  if (
    m.includes("invalid") ||
    m.includes("credential") ||
    m.includes("password")
  ) {
    return t("login.badCredentials");
  }
  return t("login.fail");
}
