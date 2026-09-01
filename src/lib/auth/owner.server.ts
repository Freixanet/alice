import { randomBytes } from "node:crypto";
import { hashPassword } from "better-auth/crypto";
import { ensureDbReady, getSql } from "../db";
import { DEV_USER_ID, sessionsEnabled } from "./verify.server";

/** Hermes on this Mac belongs to this Google account. Override with `ALICE_OWNER_EMAIL`. */
export const DEFAULT_OWNER_EMAIL = "marcfreixanet@gmail.com";

export function pinnedOwnerEmail(): string {
  return (
    process.env.ALICE_OWNER_EMAIL?.trim() || DEFAULT_OWNER_EMAIL
  ).toLowerCase();
}

/** True when this process can read ~/.hermes (this Mac). Off on Vercel. */
export function localHermesAvailable(): boolean {
  const explicit = process.env.ALICE_LOCAL_HERMES?.trim().toLowerCase();
  if (explicit === "0" || explicit === "false" || explicit === "off")
    return false;
  if (explicit === "1" || explicit === "true" || explicit === "on") return true;
  if (process.env.VERCEL) return false;
  return true;
}

export async function isLocalHermesOwner(
  userId: string | null,
  email?: string | null,
): Promise<boolean> {
  if (!sessionsEnabled()) return true;
  if (!userId) return false;
  if (userId === DEV_USER_ID) return true;
  const owner = await resolveOwner();
  // Fail closed when we cannot resolve the owner (e.g. DB error on Vercel).
  // On this Mac with no users yet, keep treating the local process as owner.
  if (!owner) return localHermesAvailable();
  if (owner.id && owner.id === userId) return true;
  const want = (email || "").trim().toLowerCase();
  if (owner.email && want && owner.email === want) return true;
  return false;
}

async function resolveOwner(): Promise<{ id: string; email: string } | null> {
  const pinned = pinnedOwnerEmail();
  try {
    const sql = await getSql();
    await claimOwnerIdentity(sql, pinned);
    await ensureOwnerPassword(sql, pinned);
    const rows = await sql.query<{ id: string; email: string }>(
      `select id, email from "user" where lower(email) = $1 limit 1`,
      [pinned],
    );
    if (rows[0]) return { id: rows[0].id, email: rows[0].email.toLowerCase() };
    return { id: "", email: pinned };
  } catch {
    return { id: "", email: pinned };
  }
}

function ownerPassword(): string | undefined {
  const value = process.env.ALICE_OWNER_PASSWORD?.trim();
  if (value && value.length >= 8) return value;
  return undefined;
}

/**
 * Give the Mac owner an email/password so the phone can sign in without Google.
 * Runs against the live PGLite in this process (Vite HMR keeps the same DB).
 */
async function ensureOwnerPassword(
  sql: Awaited<ReturnType<typeof getSql>>,
  pinned: string,
): Promise<void> {
  const password = ownerPassword();
  if (!password) return;
  let user = (
    await sql.query<{ id: string }>(
      `select id from "user" where lower(email) = $1 limit 1`,
      [pinned],
    )
  )[0];
  if (!user) {
    const id = randomBytes(16).toString("hex");
    await sql.query(
      `insert into "user" (id, name, email, "emailVerified", "createdAt", "updatedAt")
       values ($1, 'Marcos', $2, true, now(), now())`,
      [id, pinned],
    );
    user = { id };
  }
  const hash = await hashPassword(password);
  const cred = (
    await sql.query<{ id: string }>(
      `select id from "account" where "userId" = $1 and "providerId" = 'credential' limit 1`,
      [user.id],
    )
  )[0];
  if (cred) {
    await sql.query(
      `update "account" set password = $1, "updatedAt" = now() where id = $2`,
      [hash, cred.id],
    );
    return;
  }
  await sql.query(
    `insert into "account"
      (id, "accountId", "providerId", "userId", password, "createdAt", "updatedAt")
     values ($1, $2, 'credential', $2, $3, now(), now())`,
    [randomBytes(16).toString("hex"), user.id, hash],
  );
}

const claimRef = globalThis as typeof globalThis & {
  __aliceOwnerClaim__: Promise<void> | undefined;
};

/**
 * Point the in-memory test owner (first `@local.test` user) at the Google email
 * so a later Google sign-in with that address reuses the same Alice user — the
 * one that already owns this Mac's Hermes.
 */
async function claimOwnerIdentity(
  sql: Awaited<ReturnType<typeof getSql>>,
  pinned: string,
): Promise<void> {
  claimRef.__aliceOwnerClaim__ ??= (async () => {
    const already = await sql.query<{ id: string }>(
      `select id from "user" where lower(email) = $1 limit 1`,
      [pinned],
    );
    if (already[0]) return;
    const local = await sql.query<{ id: string }>(
      `select id from "user" where lower(email) = 'marcos@local.test' limit 1`,
    );
    const fallback = local[0]
      ? local
      : await sql.query<{ id: string; email: string }>(
          `select id, email from "user" order by "createdAt" asc limit 1`,
        );
    const row = fallback[0];
    if (!row) return;
    if ("email" in row && typeof row.email === "string") {
      const email = row.email.toLowerCase();
      if (!email.endsWith("@local.test")) return;
    }
    await sql.query(
      `update "user"
       set email = $1,
           name = case when name is null or name in ('', 'Marcos') then 'Marcos' else name end,
           "emailVerified" = true,
           "updatedAt" = now()
       where id = $2`,
      [pinned, row.id],
    );
  })().catch((err) => {
    claimRef.__aliceOwnerClaim__ = undefined;
    console.error("[auth] could not claim owner identity:", err);
  });
  await claimRef.__aliceOwnerClaim__;
}

const ownerBoot = globalThis as typeof globalThis & {
  __aliceOwnerPasswordBoot__: Promise<void> | undefined;
};
if (typeof window === "undefined") {
  ownerBoot.__aliceOwnerPasswordBoot__ ??= (async () => {
    await ensureDbReady();
    const sql = await getSql();
    const pinned = pinnedOwnerEmail();
    await claimOwnerIdentity(sql, pinned);
    await ensureOwnerPassword(sql, pinned);
  })().catch((err) => {
    ownerBoot.__aliceOwnerPasswordBoot__ = undefined;
    console.error("[auth] could not set owner password:", err);
  });
}
