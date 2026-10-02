# ADR-0005: Additive, backward-compatible SQL migrations

## STATUS

Accepted

## CONTEXT

The web companion uses Neon Postgres (production) or PGLite (local). The
database schema evolves over time. A migration that destroys data or
breaks backward compatibility would make code rollback impossible: a
rollback would require a destructive database rollback.

## DECISION

All SQL migrations are additive and backward-compatible. New tables, new
columns with defaults, new indexes. Never `DROP TABLE`, `DROP COLUMN` or
destructive `ALTER`. Applied migrations are recorded in `_migrations` and
never run again. Never edit an applied migration.

## EVIDENCE

- `migrations/0001_auth.sql` through `migrations/0005_sync_verifier.sql` —
  all additive
- `migrations/0005_sync_verifier.sql` — demonstrates the pattern: drop old
  check constraint, add expanded one (the new constraint accepts everything
  the old one did)
- `docs/release-operations.md`: "Database changes remain additive and
  backward-compatible across releases, so a code rollback must never require
  a destructive database rollback."
- Comment in `migrations/0001_auth.sql`: "Migrations in this folder are the
  single source of truth for your schema."

## ALTERNATIVES CONSIDERED

No evidence of alternatives being considered. The additive approach is a
standard practice for systems that need rollback safety.

## WHY THIS APPROACH EXISTS

A code rollback (reverting to the previous Vercel deployment) must not
require a database rollback. If migrations are additive, old code works
with the new schema. This makes deployment safe: if a release is bad,
promote the last known-good deployment without touching the database.

## CONSEQUENCES

- Code rollback is always safe.
- The schema can only grow; columns are never removed (they become dead
  columns if no longer used).
- Constraint changes must accept everything the old constraint did.

## RISKS

- Dead columns accumulate over time (minor: storage cost).
- A constraint change that tightens validation could reject existing data.
  This is mitigated by the rule: "Never remove records to make a migration
  pass."

## WHEN TO REVISIT

If the schema accumulates too much dead weight, a cleanup migration
(dropping unused columns) could be considered. It must be deployed
separately from any code change and must be reversible.
