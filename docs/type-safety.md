# Type-safety ratchet

Alice uses `exactOptionalPropertyTypes` for its critical external contracts.
The gate lives in `tsconfig.strict-contracts.json` and runs as part of
`npm run check`.

The strict scope currently covers:

- HTTP request schemas and Hermes mutation schemas;
- Hermes capability, model, live-data, profile and operation contracts;
- Hermes run events, connection status and outbound HTTP boundaries;
- chat-stream state transitions and message-patch persistence;
- sync contracts, encryption and deterministic merge logic;
- encrypted sync transport and hybrid local/IndexedDB storage;
- database and owner-auth initialization state;
- shared read caches and abortable delays.

Parsers omit unavailable optional values instead of emitting properties whose
value is `undefined`. This preserves the distinction between “not supplied” and
“supplied with a value” at every external boundary.

The initial global audit found 131 violations. The first ratchet removed 34
from the parsing and model-contract dependency graph; the second removed 26
from streaming, connection, persistence and synchronization. The remaining 71
violations are outside the enforced scope. Domains are added to the strict
configuration only after their existing violations are removed, keeping each
increment reviewable while preventing regressions in the hardened boundaries.
