# OpenIntelligentUI in Alice

This is a Hermes/iPhone adaptation of CopilotKit/OpenIntelligentUI, pinned source
revision `f6e4388b26a64b9a0714943b08a1ce622b924eec`. It reuses the actual MIT-licensed
shared theme, form and SVG styles and adapts the agent response playbook. It does
not replace Hermes with the upstream React/FastAPI runtime or add Jev, API keys,
a router-model call or a CDN dependency.

## What people get

Simple answers remain text. Exact comparisons use Markdown tables; existing native
Alice cards remain available for supported tasks. Diagrams, calculators and other
useful interactive answers use the `generateSandboxedUi` tool. Its description and
the discoverable `openintelligentui` skill carry the detailed quality rules. A short
registered system-prompt section instructs the agent to choose interactive UI for
budgets, savings exploration and comparisons with changing inputs, without an
explicit UI request, while keeping simple facts as text and existing native cards.
Diagnostics wording was condensed with its checks preserved to fit the unchanged
prompt-budget limits. Hermes freezes plugin sections per session: new conversations
receive this selection rule; restarting services alone does not rewrite the prompt
of an existing conversation. No persisted user prompt/history is edited for migration.
Fixture checks prove registration and budget, not the live model's presentation choice.

For self-contained local interfaces the agent can emit one `alice-interactive` fence
directly; the native parser validates it before rendering. Optional server-side
validation uses the tool, whose returned fence must appear once in the final answer.
Prepared does not mean displayed. The fence passes through
the same dashboard/gateway chat text paths and is stored in existing message archives,
without a new persistence model. Invalid output stays visible as code; native/plain
summaries provide accessible fallbacks. Only closed, complete artifacts execute.
Preparation and display require no Task approval: the exact pure-assembly tool is
allowed by the Review Tasks guard. Proposed follow-up questions still require native
review-and-send; external action tools keep their original approval gates.

Title and summary precede the upstream ordered channels: initialHeight,
placeholderMessages, css, html, jsFunctions, jsExpressions. In this adaptation
partial artifacts do not execute; placeholders are visible during native loading.

Each message is a separate snapshot. Filters, controls and calculations are local.
The host explicitly applies Alice's light/dark theme, updates it without reloading
controls and maps common `--c-*` aliases to upstream semantic theme tokens.
Editable-field backgrounds, text, WebKit text-fill, caret and borders are owned
by the host theme to prevent generated light-only input styles from hiding values.
The WebKit regression probe reproduces white input backgrounds with light text,
then verifies readable fields in both themes without changing control values.
`Websandbox.connection.remote.sendPrompt({text})` proposes a draft only. A native
Review question button opens an editable sheet, and explicit Send checks connection,
busy state and the originating chat, then uses the original reply profile. Cancelling
sends nothing. Web content has no automatic model/tool/action bridge.

Settings → Developer → Components → OpenIntelligentUI contains a local bill splitter
and an illustrative plan comparison, drawn by the same production renderer. These
examples have no Hermes connection. Purchases remain disabled.

## Isolation and limitations

The renderer uses a separate nonpersistent WKWebView and an iframe with only
`allow-scripts` (no same-origin, forms, popups, downloads or top navigation).
Generated data is JSON-escaped into a controlled main document, never interpolated
as executable parent markup. The native handler ignores child-frame messages.
CSP denies network, external scripts/styles/media/fonts, nested frames and objects;
the navigation delegate denies external/custom/file URLs. Network APIs including
WebRTC are disabled in the child. Resize and draft messages are bounded. No keys,
cookies, native calendar, Vault, payments or Hermes credentials enter the document.

No CDN importmap/Three.js/d3/chart.js is supplied. Agents must use local HTML, SVG,
canvas and plain JavaScript. This is a deliberate mobile/offline adapter limitation,
not full upstream web-runtime parity. iOS does not guarantee a hard CPU execution
budget for arbitrary JS: generated loops can make an artifact unresponsive. Loading
failure/timeout/process termination leaves the native summary readable; destroying
the view removes its handler and stops loading. Do not treat rendering as proof that
an agent's data, calculations or claims are correct.

The companion web client has not gained this renderer. Plain SMS/iMessage channels
replace the fence with its summary; other unsupported clients may show its source.
The agent is instructed to use plain text on messaging channels.

## Verification

- `bash scripts/verify-open-intelligent-ui.sh`: production Swift parser/assembler,
  isolated macOS WebKit, actual bundled calculations/reset/invalid inputs, opaque
  parent/storage/cookie access, CSP network denial, WebRTC removal, script-closing
  injection survival. No simulator, Hermes or model requests.
- Plugin suite: `python -m unittest discover -s hermes-plugin/tests`, using a temporary
  HERMES_HOME and the Hermes virtualenv. Exact result recorded at installation.
- `node scripts/check-slash-parity.mjs`: shared command contracts.
- Generic iOS device build, then pushed-source installation and device version read.

Simulator unit/UI tests and physical screen/keyboard/Dynamic Type interaction require
separate checks. Model-driven presentation choice is not established by fixtures.
On iPhone, try “Hazme una calculadora interactiva para repartir una cuenta”; adjust
values without sending a prompt, test zero people, reset, then review/cancel a query.
A short factual question should still get a short text response.

### Local run on 2026-10-09

WebKit/Swift contract probe passed all opaque-parent, storage, cookie, network and
WebRTC checks, plus both bundled controls and invalid-input/reset checks. Six new
Python contract tests passed. Existing prompt-budget checks (2), registration checks
(21), watcher checks (33) and text-channel checks (3) passed; slash parity is 52/52.

The full isolated plugin run had 719 tests: 715 passed, 1 skipped, 1 failure and
2 errors. The manifest failure was fixed by adding the new tool to its exact expected
list (no original assertion removed or loosened), and the registration subset passed.
The classifier fixture assumes the normal HERMES_HOME; it passed in that environment
with mocked OAuth/transport. The remaining memory-review subprocess timeout was
reproduced unchanged in baseline commit `f4d051a` (13 tests, 1 timeout). No memory or
purchase assertion was changed. This is not a claim of a green complete suite.

Three native fence-parser regression tests were added for complete, incomplete and
invalid artifacts; they are pending simulator/CI execution. Local generic device
compilation does not execute those tests or verify the physical interface.

Chat decoding also accepts an exact optional `type: alice-interactive` discriminator
and expands one nonempty loading string to the strict two-string contract. These
are presentation-only variations; other unknown fields/types, missing fields,
invalid values, forbidden markup and size limits remain rejected. The strict tool
validator is unchanged. Compatibility is tested in the portable Swift probe and
covered by an additional native fence-parser test (pending simulator/CI).

### Task approval regression

Reproduced the guard incorrectly requiring review for `generateSandboxedUi`, then
allowed only that exact pure-assembly tool. Eight OpenIntelligentUI tests and 25
Review Tasks tests pass, including the real hook with tracked/untracked sessions in
draft-only mode, no created approvals, continued blocking of external actions and
unchanged single-use approval checks. No existing assertion was weakened. No model
request or iOS change was needed; live agent response and visual checks remain pending.

### Theme and generation latency regression

Read-only timing inspection of the reported calculator found 47.9 seconds from user
message to final answer, with skill loading, repeated tool discovery, assembly and
regeneration of the artifact. Its CSS used undefined `--c-*` variables with light-only
fallbacks. The skill now documents direct final artifacts for local-only interfaces;
this avoids the optional assembly/discovery round trips when the agent follows it.
Actual future generation time remains model-dependent and has not been benchmarked.
The isolated WebKit probe passes explicit dark colors, live light-theme change and
unchanged control values, plus every existing sandbox check. Eight Python artifact
and two unchanged prompt-budget tests pass. No model request was made for verification.
