# ADR-0007: Independent agent task sessions with profile-scoped identity

## STATUS

Accepted

## CONTEXT

New Agent opens a separate conversation with the Agent Maker profile. Its
optional `agentTaskID` distinguishes it from the canonical Bot Chat in old
and new archives. The question is whether to reuse the bot chat session or
create an independent one.

## DECISION

`AgentTaskSession` uses profile-scoped `session.create` / `session.resume`,
retaining the durable session before submission and using the live ID for
prompts. Creation sets neither model nor history. A lost creation response
is recovered by a unique UUID title; a missing saved session fails rather
than silently redirecting or replaying work.

## EVIDENCE

- `ios/Alice/Networking/AgentTaskSession.swift`
- `docs/architecture.md` — "Independent agent tasks" section
- `docs/quality-audit-2026-09-25.md` — continuation: independent Agent Maker work
- `ios/AliceTests/AgentTaskSessionTests.swift`
- Official Hermes checkout `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c`,
  `tui_gateway/methods_session.py`: profile-scoped creation, lazy persistence
  on first prompt, resume by durable ID or pending title

## ALTERNATIVES CONSIDERED

Reusing the bot chat session would be simpler but would mix task-specific
state with the canonical chat. Opening a new profile per task would
proliferate profiles. The independent session approach keeps the canonical
chat intact while allowing task-specific recovery.

## WHY THIS APPROACH EXISTS

A task with several steps needs a separate Hermes session so it can be
resumed independently. Reusing the canonical bot chat would overwrite its
session state. A lost creation response must not silently redirect to
another session — it must be recoverable or fail visibly.

## CONSEQUENCES

- Tasks appear in Recents; opening or clearing the profile's canonical
  chat does not replace them.
- A rollback must keep the task-aware archive decoder and routing.
- An older binary predating `agentTaskID` would mistake these conversations
  for canonical chats.

## RISKS

- An older build that does not understand `agentTaskID` could corrupt task
  conversations by treating them as canonical chats.
- Profile proliferation if many tasks are created.

## WHEN TO REVISIT

If Hermes adds native task sessions, Alice's implementation may be
simplified. If task conversations become a significant fraction of the
archive, consider a separate storage partition.
