---
name: openintelligentui
description: Choose useful text, native cards or isolated interactive answers for Alice; implement working diagrams, comparisons and calculators.
---
# Interactive answers for Alice
Adapted from OpenIntelligentUI (CopilotKit), revision f6e4388, MIT.

Answer the actual task. Plain text for facts/writing/code; Markdown tables for exact comparisons; existing alice-ui native cards for places, calendar, drafts and supported tasks. Use interactive UI only when interaction improves understanding or decisions. No mandatory plan/narration; do not duplicate an artifact. On follow-up create a new snapshot; never patch previous outputs or assume control state is agent memory.

Fast path for a self-contained local calculator/diagram: write one final alice-interactive fenced JSON object directly. No tool search, tool call, file write or Task is needed; Alice validates the same eight-field contract before rendering. Supply title and accessible summary, then ordered fields initialHeight → placeholderMessages (2–4) → css → html → jsFunctions → jsExpressions. Height is an integer 180–900; title max 160 characters, summary max 2000, css max 20000, html max 80000, jsFunctions max 60000, jsExpressions max 10000; all except height/placeholders are strings, no extra fields or fence delimiters inside values. Use generateSandboxedUi only if explicit server-side validation is needed; then emit its returned fence once. Do not claim prepared means displayed. Full artifacts are rendered only when the fence closes; partial streaming stays inert. The native renderer shows a loading placeholder after a complete fence arrives.

Theme follows Alice, not the device's browser default. Use --color-text-primary, --color-text-secondary, --color-background-primary, --color-background-secondary and --color-border-tertiary. Never invent theme variable names or hardcode white surfaces/black text. Keep code concise; reuse the host's form styles instead of writing a full stylesheet for simple controls.

Final-answer shape (replace the example with the actual working UI). The fence already identifies the type: do not add a type field. Include two loading strings. Before replying check JSON syntax, all eight fields, working controls and that no forbidden markup is included:
```alice-interactive
{"title":"Example","summary":"Local example","initialHeight":300,"placeholderMessages":["Preparing controls","Preparing results"],"css":"","html":"<p>Example</p>","jsFunctions":"","jsExpressions":""}
```

Preparing and displaying an artifact requires no Task approval. Do not create a review Task or request acceptance merely to show a calculator or diagram. Review-and-send applies only to a follow-up question proposed by a control, not to local rendering or calculations.

The host includes OpenIntelligentUI theme tokens, form styles and SVG .c-* classes. Use these tokens and only widget-specific css. html is body markup without script/style/iframe/form/meta/object/embed/base. Named behavior goes in jsFunctions; synchronous initialization in jsExpressions. Classic scripts: no top-level await. In Alice there is NO CDN import map or network: use HTML, SVG, canvas and plain JS; do not import Three/d3/chart.js, fetch data, access parent DOM, cookies/storage or invent backend APIs.

Understand: expose meaningful variables or steps. Compare: make criteria/tradeoffs/assumptions visible. Tool: working inputs, calculations, outputs and reset. A static diagram suffices when controls add no value. Validate blanks/non-finite/out-of-range/zero divisors; clear stale outputs on invalid input. Show units/formulas and appropriate precision. Use textContent for user/retrieved text. Never interpolate untrusted values into executable HTML/JS.

Label user values, retrieved evidence, calculated results and illustrative assumptions in the artifact. Never invent current prices, weather, sources, timestamps, saved state or actions. Essential missing evidence: ask for inputs or show explicitly labeled sample assumptions. Never collect secrets or create login/payment forms; existing native approvals remain in Hermes.

Responsive at phone width; semantic headings, associated labels, keyboard controls, visible focus, readable contrast, textual SVG/canvas alternatives. Respect reduced motion; no autoplay; provide pause/reset and useful error states. Every enabled control works. No decorative controls.

Filters, sliders and calculations are local and cost no model call. A deliberate button may use Websandbox.connection.remote.sendPrompt({text}) with current validated selections. In Alice this only proposes a draft: the person reviews and explicitly sends through native Alice UI. It never sends automatically. No calls on load/timers/input changes. Do not request credentials. No openLink bridge is supplied; external actions stay in native Alice.
