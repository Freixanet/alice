import { randomBytes } from "node:crypto";
import { hashPassword } from "better-auth/crypto";
import { ensureDbReady, getSql } from "../db";
import { DEV_USER_ID, sessionsEnabled } from "./verify.server";

/**
 * Account that owns the Hermes on this machine, when the deployer pinned one
 * with `ALICE_OWNER_EMAIL`.
 *
 * There is deliberately no default. Baking in an address would hand ownership
 * of every other install’s Hermes to a stranger, so an unset value means
 * "whoever registered first here owns it" — the right answer for a personal
 * deployment, and safe for anyone who clones this.
 */
export function pinnedOwnerEmail(): string | null {
  const value = process.env.ALICE_OWNER_EMAIL?.trim();
  return value ? value.toLowerCase() : null;
}

/** Display name for a pinned owner Alice has to create. */
function ownerDisplayName(email: string): string {
  const explicit = process.env.ALICE_OWNER_NAME?.trim();
  if (explicit) return explicit;
  const local = email.split("@")[0] ?? "";
  return local ? local.charAt(0).toUpperCase() + local.slice(1) : "Owner";
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
    if (!pinned) {
      // No pinned owner: the first account registered here owns this Hermes.
      const first = await sql.query<{ id: string; email: string }>(
        `select id, email from "user" order by "createdAt" asc limit 1`,
      );
      const row = first[0];
      return row
        ? { id: row.id, email: (row.email || "").toLowerCase() }
        : null;
    }
    await claimOwnerIdentity(sql, pinned);
    await ensureOwnerPassword(sql, pinned);
    const rows = await sql.query<{ id: string; email: string }>(
      `select id, email from "user" where lower(email) = $1 limit 1`,
      [pinned],
    );
    if (rows[0]) return { id: rows[0].id, email: rows[0].email.toLowerCase() };
    return { id: "", email: pinned };
  } catch {
    return pinned ? { id: "", email: pinned } : null;
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
       values ($1, $3, $2, true, now(), now())`,
      [id, pinned, ownerDisplayName(pinned)],
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
 * Point the throwaway in-memory account (the first `@local.test` user) at the
 * pinned address, so a later sign-in with that address reuses the same Alice
 * user — the one that already owns this machine's Hermes. Runs only when the
 * deployer pinned an owner.
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
    // Only a throwaway `@local.test` account may be re-pointed; a real account
    // is never rewritten to someone else's address.
    const candidates = await sql.query<{ id: string; email: string }>(
      `select id, email from "user"
       where lower(email) like '%@local.test'
       order by "createdAt" asc limit 1`,
    );
    const row = candidates[0];
    if (!row) return;
    await sql.query(
      `update "user"
       set email = $1,
           name = case when name is null or name = '' then $3 else name end,
           "emailVerified" = true,
           "updatedAt" = now()
       where id = $2`,
      [pinned, row.id, ownerDisplayName(pinned)],
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
    if (!pinned) return;
    await claimOwnerIdentity(sql, pinned);
    await ensureOwnerPassword(sql, pinned);
  })().catch((err) => {
    ownerBoot.__aliceOwnerPasswordBoot__ = undefined;
    console.error("[auth] could not set owner password:", err);
  });
}
