import { randomBytes } from "node:crypto";
import { hashPassword } from "better-auth/crypto";
import { ensureDbReady, getSql } from "../db";
import { DEV_USER_ID, sessionsEnabled } from "./verify.server";

/**
 * Account that owns the Hermes on this machine, when the deployer pinned one
 * with `ALICE_OWNER_EMAIL`.
 *
 * There is deliberately no default. Baking in an address would hand ownership
 * of every other install’s Hermes to a stranger.
 *
 * Unset no longer means "whoever registered first here owns it". That was a
 * public grant: on any install a stranger could reach, the first person to
 * sign up became the owner of somebody else’s agent. Unset now means nobody
 * is owner, and ownership has to be provisioned deliberately.
 */
export function pinnedOwnerEmail(): string | null {
  const value = process.env.ALICE_OWNER_EMAIL?.trim();
  return value ? value.toLowerCase() : null;
}

/**
 * Whether a throwaway local account may be promoted to the pinned owner.
 *
 * Off unless asked for. It is a convenience for setting up a fresh machine,
 * and a convenience that hands over an agent should be typed by the person
 * who wants it.
 */
function claimLocalEnabled(): boolean {
  const value = process.env.ALICE_OWNER_CLAIM_LOCAL?.trim().toLowerCase();
  return value === "1" || value === "true" || value === "on";
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

/**
 * Whether this session owns the Hermes on this machine.
 *
 * Decided on the owner’s user id and nothing else. It used to also accept a
 * session whose *claimed* email matched the pinned address, which is not a
 * proof of anything: registering that address — unverified, no password from
 * the deployer, no pre-existing account — was enough to be handed the role,
 * because the pinned address was treated as an identity even when no such
 * account existed.
 *
 * The `email` argument is kept so callers need not change, and is deliberately
 * unused: an address supplied by the request is a claim, not a credential.
 */
export async function isLocalHermesOwner(
  userId: string | null,
  _email?: string | null,
): Promise<boolean> {
  if (!sessionsEnabled()) return true;
  if (!userId) return false;
  if (userId === DEV_USER_ID) return true;
  const owner = await resolveOwner();
  // Fail closed. This previously fell back to `localHermesAvailable()`, so a
  // database error — or simply an install with no owner — granted ownership
  // to whoever happened to be signed in.
  if (!owner) return false;
  return owner.id === userId;
}

/**
 * The account that owns this Hermes, or null.
 *
 * Three things changed here, and each of them was a way in:
 *
 * Without a pinned owner there is no owner. The first-registered rule handed
 * the agent to whoever signed up first.
 *
 * The pinned address must belong to a real, verified account. It used to
 * resolve to `{ id: "", email: pinned }` when no such row existed, so the
 * address alone conferred the role and anyone could register it.
 *
 * A failure resolves to null rather than to the pinned address, so an error
 * reading the database cannot promote a stranger.
 */
async function resolveOwner(): Promise<{ id: string } | null> {
  const pinned = pinnedOwnerEmail();
  if (!pinned) return null;
  try {
    // Provision once at startup. Ordinary authorization checks must never
    // reset a password or repeat its expensive hash on every request.
    await ownerBoot.__aliceOwnerPasswordBoot__;
    const sql = await getSql();
    const rows = await sql.query<{ id: string }>(
      `select id from "user"
       where lower(email) = $1 and "emailVerified" = true
       limit 1`,
      [pinned],
    );
    return rows[0] ? { id: rows[0].id } : null;
  } catch {
    return null;
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
 * user — the one that already owns this machine's Hermes.
 *
 * This grants ownership, and it used to do so to whoever had registered the
 * first `@local.test` account: it rewrote that row to the pinned address and
 * marked it verified. It now needs saying out loud — `ALICE_OWNER_CLAIM_LOCAL`
 * — and only fires on an install with exactly one account, which is the
 * situation it was written for: a fresh machine with a scratch user on it.
 */
async function claimOwnerIdentity(
  sql: Awaited<ReturnType<typeof getSql>>,
  pinned: string,
): Promise<void> {
  if (!claimLocalEnabled()) return;
  claimRef.__aliceOwnerClaim__ ??= (async () => {
    const already = await sql.query<{ id: string }>(
      `select id from "user" where lower(email) = $1 limit 1`,
      [pinned],
    );
    if (already[0]) return;
    // Only on an install that has nobody else on it. With a second account
    // present this is no longer a scratch machine, and rewriting one of them
    // is rewriting somebody.
    const count = await sql.query<{ n: number }>(
      `select count(*)::int as n from "user"`,
    );
    if ((count[0]?.n ?? 0) !== 1) return;
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
