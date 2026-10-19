# ADR-0001: Use official Hermes, no fork

## STATUS

Accepted

## CONTEXT

Alice needs to interact with a Hermes agent: send chat messages, receive
streaming replies, manage agent profiles, handle approvals, run routines and
access tools. Hermes is an external project (Nous Research) with its own
release cycle. Alice needs to survive Hermes updates without breaking.

## DECISION

Everything Alice needs from the server lives in a Hermes plugin
(`hermes-plugin/`), using Hermes' public hooks: tools, prompt sections,
`pre_tool_call`, `transform_llm_output`. Alice does not fork or patch Hermes.

## EVIDENCE

- README: "Official Hermes, no fork. Everything Alice needs from the server lives in a Hermes plugin."
- `hermes-plugin/plugin.yaml` — plugin manifest
- `hermes-plugin/__init__.py` — hooks into Hermes' public API
- `docs/hermes-contracts.md` — contract fixtures pinned to specific Hermes commits
- CI installs official Hermes at commit `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`

## ALTERNATIVES CONSIDERED

Forking Hermes would give full control but create a maintenance burden:
every Hermes update would need to be merged. The plugin approach was chosen
because Hermes' public API is stable and sufficient.

## WHY THIS APPROACH EXISTS

Hermes' plugin API provides tools, prompt sections and hooks that are
sufficient for Alice's needs. Forking would couple Alice's release cycle
to Hermes' and require merging upstream changes. The plugin approach lets
Hermes update independently.

## CONSEQUENCES

- Updating Hermes does not overwrite Alice.
- Alice is limited to what Hermes' public API exposes.
- A Hermes breaking change to the plugin API can break Alice.
- The contract fixtures (`src/lib/hermes-contract-fixtures.ts`) must be
  updated after each Hermes release.

## RISKS

- Hermes removes or changes a hook Alice depends on.
- Hermes adds a feature Alice cannot access through the plugin API.

## WHEN TO REVISIT

When Hermes releases a breaking change to the plugin API, or when Alice
needs a capability the plugin API does not expose.
