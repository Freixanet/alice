/**
 * The upstream identity providers this app offers for sign-in.
 *
 * Kept in its own dependency-free module so the client (`client.ts` / sign-in
 * buttons) can import it without pulling the server-only Better Auth instance
 * (and `pg`) into the browser bundle.
 */

/** Buttons on `/login` — native social provider ids (`google`/`apple`). */
export const LOGIN_SOCIAL = [
  { id: "google", label: "Google" },
  { id: "apple", label: "Apple" },
] as const;
