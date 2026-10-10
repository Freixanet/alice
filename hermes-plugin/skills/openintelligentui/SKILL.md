---
name: openintelligentui
description: Choose useful text, native cards or isolated interactive answers for Alice; implement working diagrams, comparisons and calculators.
---
# Interactive answers for Alice
Adapted from OpenIntelligentUI (CopilotKit), revision f6e4388, MIT.

Answer the actual task. Plain text for facts/writing/code; Markdown tables for exact comparisons; existing alice-ui native cards for places, calendar, drafts and supported tasks. Use generateSandboxedUi only when interaction improves understanding or decisions. No mandatory plan/narration; do not duplicate an artifact. On follow-up create a new snapshot; never patch previous outputs or assume control state is agent memory.

Supply title and accessible summary, then ordered fields initialHeight → placeholderMessages (2–4) → css → html → jsFunctions → jsExpressions. Emit the returned alice-interactive fence once in the final answer. Do not claim prepared means displayed. Full artifacts are rendered only when the fence closes; partial streaming shows a placeholder, never executes scripts.

The host includes OpenIntelligentUI theme tokens, form styles and SVG .c-* classes. Use these tokens and only widget-specific css. html is body markup without script/style/iframe/form/meta/object/embed/base. Named behavior goes in jsFunctions; synchronous initialization in jsExpressions. Classic scripts: no top-level await. In Alice there is NO CDN import map or network: use HTML, SVG, canvas and plain JS; do not import Three/d3/chart.js, fetch data, access parent DOM, cookies/storage or invent backend APIs.

Understand: expose meaningful variables or steps. Compare: make criteria/tradeoffs/assumptions visible. Tool: working inputs, calculations, outputs and reset. A static diagram suffices when controls add no value. Validate blanks/non-finite/out-of-range/zero divisors; clear stale outputs on invalid input. Show units/formulas and appropriate precision. Use textContent for user/retrieved text. Never interpolate untrusted values into executable HTML/JS.

Label user values, retrieved evidence, calculated results and illustrative assumptions in the artifact. Never invent current prices, weather, sources, timestamps, saved state or actions. Essential missing evidence: ask for inputs or show explicitly labeled sample assumptions. Never collect secrets or create login/payment forms; existing native approvals remain in Hermes.

Responsive at phone width; semantic headings, associated labels, keyboard controls, visible focus, readable contrast, textual SVG/canvas alternatives. Respect reduced motion; no autoplay; provide pause/reset and useful error states. Every enabled control works. No decorative controls.

Filters, sliders and calculations are local and cost no model call. A deliberate button may use Websandbox.connection.remote.sendPrompt({text}) with current validated selections. In Alice this only proposes a draft: the person reviews and explicitly sends through native Alice UI. It never sends automatically. No calls on load/timers/input changes. Do not request credentials. No openLink bridge is supplied; external actions stay in native Alice.
