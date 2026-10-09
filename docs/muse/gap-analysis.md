# Alice vs Muse — gap analysis (2026-10-07)

Studied live in the user's own Muse account (muse.ai web: Chat, Feed, Ideas, Goals, Library).
Based on how the Muse app itself behaves, not on the Alice notes stored in that account (those were tests).

## What Muse does

### Feed
- Editable **feed prompt** at the top ("Make me a feed about my interests… quick to skim, no
  clickbait") with Edit / Generate.
- Items mix three kinds: world news on the user's interests, **personal signals** read from
  connected mail/accounts (failed charges, renewals, offers expiring, saved-search hits), and
  **proactive offers** ("I can verify which saved buffets are worth the trip").
- Each item: small illustrative icon, plain declarative headline with the concrete number,
  relative time, 2–3 sentence body with inline source links, optional inline chart/table or
  image, then like + one action: **Discuss** (opens a chat seeded with the item) or
  **Let's do it** (starts the task).
- Tone: factual, specific (amounts, dates, names), source named in-line, no hype.

### Ideas
- Personal ideas first (from the user's own mail/data, each with concrete amounts and dates),
  then catalog ideas grouped by area (Health & Fitness, Financial Management, Relationships,
  Shopping…). Each idea: headline in first person ("I can…", "Let me…") + one paragraph saying
  exactly what Muse will do and what the user gets. Tapping starts it.

### Goals
- "Tracking" list: every long-running task/goal is a checkbox row with a one-line **current
  status** ("Waiting on X to confirm…", "Audit saved; picks still pending; trial ends in 2 days").
- Create a goal by area (Health, Relationships, Finance, Career, Interests, Productivity…).

### Errands / research (observed live: "3 best ANC headphones under 200 EUR in Spain", ~5 min)
- Live status under the avatar at the top while working: Searching → Reading profile →
  Resolving options → Extracting details → Activating search. No status text in the transcript.
- A **Browser card** appears in the chat: title, current step ("Starting", "Opening site search",
  "Working"), live screenshot of the page, and an "Open browser" button. When done it collapses to
  one line: "Completed · Research noise-cancelling headphones · Open preview".
- Sends an early **provisional** message with first candidates, says what it is still checking.
- Result: a **product card list** (photo, title, brand · store, price with struck-through original
  price), then one short recommendation paragraph with inline product chips (thumbnail + name)
  that says which to pick for which priority.

### Purchases (observed in the user's real domain purchase in Muse's chat history)
- Says what it will do and that it will show the total before paying.
- Puts the item in the basket first, tries promo codes, reports the basket total with renewal price
  and hidden-fee check, then asks only for the missing data in one list.
- Passwords via a secure card, never in chat; asks "Do I try the CAPTCHA or do you?"; asks the
  user for verification codes from mailboxes it cannot read.
- **Final review** as a short list: order, account, price breakdown (list price, offer, coupon),
  conditions (auto-renew, no refunds), payment options. Then asks "Is the order right? How do we
  pay?" with a widget to choose.
- Payment through a one-time virtual card (Stripe Link); user picks the card by last 4 digits.
- After paying, checks the real charge on the invoice; when the user saw a higher hold it paused,
  verified, explained, and apologised for not warning beforehand.
- Keeps going with the next step of the goal right after ("next step, the email…").

### Chat / answering
- User messages as light-blue bubbles on the right, Muse as grey bubbles on the left; several short bubbles in a row instead of one long block.
- Short, concrete replies that say what it checked and what happens next ("Ya está publicado. Pulsa de nuevo…").
- Composer: "+" for attachments and a single Message field.

### Look & motion (Muse app)
- Light, quiet UI: white/off-white background, black text, hairline separators, one blue accent for primary buttons.
- Large left-aligned page titles; bottom tab bar Chat · Feed · Ideas · Goals · Library · More.
- Feed rows: small illustrative icon on the left, headline + time + body, like and one action below.
- Skeleton shimmer while content loads.

## Alice today (to verify item by item before building)
Alice already has Chat, Feed, Goals, Errands, Purchase, Browser, Catalog, Agenda, Notes.
The gaps are mostly in *behaviour and quality*, not missing screens.

## Proposed order
1. **Errands + purchases**: after watching Muse do one end to end.
2. **Feed**: feed prompt, personal signals + proactive offers, Discuss / Let's do it.
3. **Ideas** from the user's own data, grouped by area.
4. **Goals** status line ("waiting on…").
5. **Chat answering** style (plain text agent, collapsed reasoning, approval cards).
6. **Look & motion**: only the parts the user picks.
