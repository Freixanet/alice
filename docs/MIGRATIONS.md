# Alice Migrations

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

## Policy

1. **Migrations are additive.** New migrations add tables, columns, or
   constraints. They never drop, rename, or remove data.
2. **Migrations are backward-compatible.** Old application code must continue
   to work against a database with new migrations applied.
3. **Migrations are ordered.** Files are named `NNNN_description.sql` and
   applied in order.
4. **Migrations are idempotent where possible.** Use `CREATE TABLE IF NOT
   EXISTS`, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, etc.
5. **Migrations are transactional.** Each migration runs in a transaction.
   If it fails, it is rolled back. The `_migrations` table records applied
   state.
6. **Applied migrations are never edited.** Once a migration is applied to
   any database, it is immutable. Fix issues in a new migration.
7. **Migrations run on deploy.** `npm run db:migrate` applies pending
   migrations. Local PGLite applies them automatically on startup.

## How migrations work

### Production (Neon Postgres)

```bash
npm run db:migrate
```

This connects to the `DATABASE_URL`, checks the `_migrations` table, and
applies pending migrations in order. Each migration runs in a transaction.

### Local development (PGLite)

PGLite applies migrations automatically on startup. No manual action needed.

### Migration files

| File                          | Description                                    |
| ----------------------------- | ---------------------------------------------- |
| `0001_auth.sql`               | Better Auth schema (identity + sessions)       |
| `0002_hermes_gate.sql`        | Hermes connection (url + key, sealed, per user)|
| `0003_encrypted_sync.sql`     | E2E encrypted conversation sync               |
| `0004_security_hardening.sql` | Cross-instance rate limiting                   |
| `0005_sync_verifier.sql`      | Encrypted verifier for recovery keys           |

## Codable migrations (iOS)

iOS uses Swift `Codable` for persisted data. These are NOT database migrations
but follow the same principles:

1. **Read old archives before extending.** A new property with a default
   value does NOT make synthesized decoding backward-compatible. Old archives
   without the key will fail.
2. **Use `decodeIfPresent` for new fields.** This allows old archives to
   decode successfully.
3. **Never replace an unreadable archive with an empty one.** Retain
   unreadable bytes for recovery.
4. **Persist user edits immediately.** Backgrounding saves current
   conversation state.
5. **The old single-array blob is still read on launch.** It is rewritten in
   the split form. This is a one-time migration that happens on first launch.

## Migration guard

Before deploying a migration:

1. **Test locally:** PGLite applies it automatically. Verify the app starts.
2. **Test on staging:** Run `npm run db:migrate` against a staging database.
3. **Verify backward compatibility:** Deploy the new code against the old
   database. Then apply the migration. Then verify old code against the new
   database.
4. **Back up production:** Take a Neon backup before applying.
5. **Record the version:** Note the migration version alongside the deployment.

## What NOT to do

- **Never edit an applied migration.** Create a new one.
- **Never drop data in a migration.** If you need to remove data, mark it as
  deprecated and remove it in a future migration after all code has been
  updated.
- **Never remove encrypted records to make a migration pass.** (Per
  `docs/release-operations.md`.)
- **Never run migrations outside the controlled `npm run db:migrate` step.**
- **Never assume PGLite and Neon behave identically for all SQL.** Test
  against both if using features like sequences, triggers, or types.
