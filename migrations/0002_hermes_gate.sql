-- Hermes connection (url + key), sealed, per signed-in user.
-- The browser cookie is easy to drop (embedded tabs, bearer sessions).
-- Chat looks this up by user_id when the cookie is missing.

create table if not exists hermes_gate (
  user_id text not null primary key,
  token text not null,
  updated_at timestamptz not null default now()
);
