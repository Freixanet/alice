# ADR-0006: Hermes' safety stays in charge; Alice adds, never removes

## STATUS

Accepted

## CONTEXT

Hermes has its own safety mechanisms: confirmation for dangerous commands,
vault for secrets, skill review. Alice adds a native UI on top of these.
The question is whether Alice should replace or supplement Hermes' safety.

## DECISION

Alice adds checks on top of Hermes' safety and never removes any. Cards and
logins go into Hermes' vault. Payments pass Hermes' confirmation. Alice adds:
after an agent reads a web page or email, a command that could send data
out of the Mac or read secrets needs the person's approval. A skill that
reads like an injected instruction is held back.

## EVIDENCE

- README: "Hermes' own safety stays in charge. Cards and logins go into
  Hermes' vault. Payments still pass Hermes' confirmation. Alice adds
  checks on top and never removes any."
- `hermes-plugin/egress_guard.py` — post-read approval for outbound commands
- `hermes-plugin/skill_keeper.py` — holds back skills that read like
  injected instructions
- `hermes-plugin/secret_store.py` — writes secrets to Hermes' .env, never
  into the chat
- `SECURITY.md` — "The agent runs with your privileges on the machine that
  hosts it."

## ALTERNATIVES CONSIDERED

Alice could have its own safety layer independent of Hermes. This would
duplicate Hermes' checks and could create false confidence. The decision
is to layer on top, not replace.

## WHY THIS APPROACH EXISTS

Hermes is the authority on what the agent can do. Alice is a UI for it.
If Alice replaced Hermes' safety, a Hermes update could bypass Alice's
checks. By layering on top, Alice's checks are additional, not
alternative.

## CONSEQUENCES

- Hermes' safety is always present, even if Alice is bypassed.
- Alice's additional checks (egress guard, skill review) are defense in
  depth.
- An agent with a terminal can still read any file on the Mac, including
  keys — Alice cannot prevent this (documented in SECURITY.md).

## RISKS

- Alice's additional checks could create friction without adding real
  safety (e.g., approving every egress command).
- Hermes could change its safety model in a way that conflicts with
  Alice's assumptions.

## WHEN TO REVISIT

If Hermes adds its own egress guard or skill review, Alice's version may
become redundant. Revisit to avoid double-approving the same action.
