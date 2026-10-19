# Architecture Decision Records

This directory holds Alice's important architectural decisions. An ADR is
written only for decisions that materially constrain future engineering —
not for every technical choice.

## How to use ADRs

- Read an ADR before changing the area it covers.
- Do not casually undo a decision without understanding its consequences.
- If a decision is revisited, update the STATUS and add a new ADR that
  supersedes it.
- If rationale cannot be established from code, Git history or
  documentation, write `RATIONALE NOT RECOVERABLE` and distinguish
  inference from evidence.

## Index

| ADR | Title | Status |
| --- | ----- | ------ |
| [0001](0001-official-hermes-no-fork.md) | Use official Hermes, no fork | Accepted |
| [0002](0002-phone-never-server.md) | The phone never becomes the server | Accepted |
| [0003](0003-file-per-conversation.md) | One file per conversation, not UserDefaults | Accepted |
| [0004](0004-keychain-update-then-add.md) | Keychain update-then-add, never delete-then-add | Accepted |
| [0005](0005-additive-sql-migrations.md) | Additive, backward-compatible SQL migrations | Accepted |
| [0006](0006-hermes-safety-in-charge.md) | Hermes' safety stays in charge; Alice adds, never removes | Accepted |
| [0007](0007-agent-task-session-isolation.md) | Independent agent task sessions with profile-scoped identity | Accepted |
| [0008](0008-encrypted-sync-web-only.md) | Encrypted conversation sync is web-only | Accepted |
| [0009](0009-codable-backward-compatibility.md) | Codable backward compatibility with optional fields and standing tests | Accepted |

See [TEMPLATE.md](TEMPLATE.md) for the structure of a new ADR.
