# Alice design system

Alice's visual system, and the habits it keeps out of the interface. Every
surface — native and web — follows these rules; `npm run design:check` holds
the web to the measurable ones.

## Identity that stays

- Warm paper light theme and restrained charcoal dark theme.
- Instrument Serif for editorial headings; IBM Plex Sans and Mono elsewhere.
- Alice's mark, wordmark, neutral palette, optional single accent, and concise copy.
- Quiet, tactile interaction and strong mobile behavior.

## Surface model

- **Chat — Command / Inspect:** conversation and composer dominate. No dashboard framing.
- **Skills, Tools, Add-ons, Projects, Memory, Jobs — Explore / Operate:** searchable,
  scannable records with separators and meaningful state, not a wall of cards.
- **Connect and Settings — Configure:** labels, controls, validation and progressive
  disclosure dominate. Decoration must never compete with the task.

## Strict rules

1. No box shadows, gradients, glassmorphism, glow, blur, or floating glass surfaces.
2. Do not use a rounded card as the default grouping mechanism. Prefer alignment,
   whitespace, headings and hairline separators.
3. Do not use pills by default. Pills are reserved for compact state or filtering;
   avatars, switches, status dots, swatches and icon-only controls may be circular.
4. No generic blue/purple "tech" treatment. Alice keeps the user's chosen accent.
5. No decorative icons, fake metrics, icon-topped feature tiles, accent rails,
   ornamental badges, emojis, filler copy or invented product claims.
6. Do not center an entire working surface. Centering is allowed only for a genuinely
   empty moment; its composition must still align with the composer it introduces.
7. Hierarchy comes from type, spacing, alignment, weight and contrast before boxes.
8. Every visible state color, label and divider must communicate something.

## Visual system

- Surfaces: use the page background, one restrained raised surface, and a 1px border.
- Radius: 8px for every standalone field, button, message, composer, popover and
  dialog. Integrated list rows and full-screen mobile sheets use 0; full circles
  remain exclusive to the functional exceptions above.
- Spacing: use a 4px base rhythm; lists are denser than prose and settings.
- Typography: preserve the current families; use serif sparingly for page identity.
  On iOS, SF is the content and chrome face. Instrument Serif is Alice's voice
  only (home empty state, sidebar wordmark) — never Markdown headings in a reply.
  Assistant prose uses a Dynamic Type–scaled reading measure on wide layouts;
  code is SF Mono with ligatures off.
- Color: one accent at a time; neutral surfaces carry structure. Meet WCAG AA.
- Motion: 150–300ms only to clarify continuity or state. Respect reduced motion.

## Responsive rules

- At 320px there must be no horizontal page overflow or clipped controls.
- Touch targets are at least 44px for mobile controls.
- Mobile Settings remains a full-screen surface with independently scrolling content.
- The mobile sidebar gesture, settling behavior and external toggle remain unchanged.

## Completion audit

- Review Chat, a populated record list, Connect, Memory and Settings at desktop
  and mobile widths after every visual change.
- Computed styles contain no box shadow, gradient or backdrop filter.
- Verify light/dark themes, accent selection, keyboard focus, scrolling and reduced motion.
- A visual change is complete only if it improves hierarchy without hiding information
  or changing behavior.
