# Contributing to Alice

Start with [AGENTS.md](AGENTS.md). These rules apply to human contributors and
coding assistants alike.

## A useful change

Describe the user problem, the expected behavior and the affected surface. For a
bug, include a small reproduction with private data removed. Discuss large
changes before investing in a broad rewrite.

Work on a topic branch. Keep one coherent purpose per pull request, preserve
backward compatibility of stored conversations and test the relevant behavior.
Follow the existing Swift and TypeScript conventions and design tokens.

## Before opening a pull request

- Follow [the verification guide](docs/verification.md).
- Explain the problem and resulting behavior, with screenshots for visual changes.
- Include the exact checks run and any limitation, such as a missing live service.
- Update [compatibility](docs/compatibility-matrix.md) when Hermes support changes.
- Check the diff for credentials, personal paths, generated files and private content.

Do not describe fixture tests as live verification or a compilation as a UX
review. Report security issues [privately](SECURITY.md).

## Review principles

Prefer explicit identity, predictable state transitions, bounded network work,
clear errors and recoverable storage. Reuse an existing tested contract before
adding another abstraction. A smaller patch with evidence is easier to maintain
than a broad rewrite that changes unrelated behavior.
