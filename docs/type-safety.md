# Type-safety ratchet

Alice uses `exactOptionalPropertyTypes` for its critical external contracts.
The gate lives in `tsconfig.strict-contracts.json` and runs as part of
`npm run check`.

The strict scope currently covers:

- HTTP request schemas and Hermes mutation schemas;
- Hermes capability, model, live-data, profile and operation contracts;
- sync contracts, encryption and deterministic merge logic;
- shared read caches and abortable delays.

Parsers omit unavailable optional values instead of emitting properties whose
value is `undefined`. This preserves the distinction between “not supplied” and
“supplied with a value” at every external boundary.

The initial global audit found 131 violations. This ratchet removes 34 of them
from the parsing and model-contract dependency graph and prevents them from
returning. Remaining domains will be added to the strict configuration only
after their existing violations are removed, keeping each increment reviewable.
