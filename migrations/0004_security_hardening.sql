-- Constant-space, cross-instance rate limiting for authenticated API traffic.
-- One row is reused per (scope, pseudonymous identity), so old windows do not
-- accumulate and serverless instances share the same atomic counter.

create table if not exists alice_rate_limit (
  scope text not null check (char_length(scope) between 1 and 32),
  identity_hash text not null check (char_length(identity_hash) = 64),
  window_started_at bigint not null check (window_started_at >= 0),
  hits integer not null check (hits > 0),
  updated_at timestamptz not null default now(),
  primary key (scope, identity_hash)
);

create index if not exists alice_rate_limit_updated_idx
  on alice_rate_limit (updated_at);
