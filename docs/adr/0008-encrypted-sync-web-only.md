# ADR-0008: Encrypted conversation sync is web-only

## STATUS

Accepted

## CONTEXT

The web companion has an end-to-end encrypted conversation sync feature
(`alice_sync_record` table, device keys, immutable verifier). The iOS app
does not share this implementation. The question is whether iOS should
also sync conversations to the cloud.

## DECISION

Encrypted conversation sync is web-only. iOS does not share that
implementation. The compatibility matrix states: "Do not claim iOS/web
cloud-sync parity."

## EVIDENCE

- `migrations/0003_encrypted_sync.sql` — sync records table
- `src/lib/cloud-sync-runtime.ts`, `src/lib/sync-crypto.ts`,
  `src/lib/sync-store.server.ts` — web sync implementation
- `docs/compatibility-matrix.md`: "Encrypted conversation sync | Not a
  shared native sync implementation | Account-scoped E2EE"
- No sync code in `ios/Alice/`

## ALTERNATIVES CONSIDERED

RATIONALE NOT RECOVERABLE. No evidence of a deliberate decision to exclude
iOS from sync. It appears to be a feature that was built for the web first
and not yet ported to iOS.

## WHY THIS APPROACH EXISTS

The web companion has its own account system and server infrastructure
(Vercel, Neon). iOS does not have a server-side account. Implementing sync
on iOS would require either sharing the web account or building a separate
iOS sync path.

## CONSEQUENCES

- iOS conversations are only on the phone. If the phone is lost, they are
  gone (unless the web sync has a copy from a shared session).
- The web and iOS conversation models are similar but not identical.
- Claiming iOS/web sync parity would be misleading.

## RISKS

- iOS users expect cloud sync as a baseline feature.
- If iOS conversations are lost, there is no recovery path.

## WHEN TO REVISIT

If iOS gains an account system or the web account is extended to iOS,
sync can be ported. The sync crypto and merge logic are reusable.
