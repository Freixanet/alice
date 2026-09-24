# Handoff — 24 Sep 2026

This is where the work stands and what comes next. The user writes in Spanish, and expects plain explanations and a single recommendation (see AGENTS.md and CLAUDE.md).

## State

- `main` holds everything: `fix/ios-chat-bugs`, the self-maintaining memory, and the other session's work (Exa key, secure key card, site login that can create an account), merged in f0b2cc9.
- The iPhone has **build 96**, built from `main`. Build numbers only go up (`CURRENT_PROJECT_VERSION=97` next). Always build from `main`, so nothing another session did disappears.
- The live plugin on the Mac (`~/.hermes/plugins/alice`) matches `main`. The previous copy is backed up under `~/.hermes/backups/plugin-alice-*`. Before deploying again:
  1. Compare the live copy with the repo.
  2. Merge; never just overwrite.
  3. Restart `ai.hermes.gateway`, then `ai.hermes.dashboard`, one at a time. The iPhone chats run in the dashboard (port 9119).
- **Never test in the shared agent browser (127.0.0.1:9222).** Use a temporary Chrome on another port.

## Done today

- **Agenda:** events and reminders from the phone, a list without calendar views, a reminder composer with natural-language dates, reminder lists.
- **Connections:** the Hermes MCP catalog with each connector's own logo (plugin `connector_icons.py`).
- **Goals tab:**
  - plugin `goals.py`, with a `goals` tool and the `alice.objetivos` prompt section;
  - iOS `Features/Goals`.
- **Live browser:**
  - `Features/Browser/LiveBrowser.swift` (card in the chat, full screen, take over / hand back);
  - plugin `browser_live.py`: follows the agent's tab, control lease, pointer overlay, small frames.
- **Secure requests:** Hermes `vault.save_login`, `vault.code`, `vault.unlock_prompt` and `secret` are shown as a native sheet (`SecureRequestSheet`), so Alice signs in through Hermes' vault.
- **Alice's persona** (`hermes-agents/alice/persona.md`, applied to `~/.hermes/SOUL.md`):
  - her purpose line;
  - use the browser for websites;
  - sign in through the vault;
  - buy up to the pay button, and stop there.

## Open problems

1. **Card payment (Redsys) — fixed, not yet tried end to end.** The vault had no card, and nothing let the person give one. Now an agent at a payment page with no card ends with `[Añadir tarjeta](alice://connect/card?origin=…&profile=…)`; the app shows a native card form (`PaymentCardOfferCard`) and the plugin (`vault_cards.py`, `/api/plugins/alice/vault/cards`) stores it in Hermes' vault, bound to that page. Hermes fills it after the person confirms. Risk: Hermes finds card fields by English names and autocomplete tokens; if a Spanish bank page has neither, the fill finds nothing and Alice asks the person to type the card in the live view. The old notes: Alice reaches the Redsys page, but the card data isn't entered and "Pagar" stays disabled. Hermes' vault supports payment items: `browser_vault_fill` fills card fields after the user confirms. Next steps:
   - make sure the app answers the vault's payment confirmation, and a request to save a card if Hermes sends one (check the `tui_gateway/contracts/server_requests.py` vault requests);
   - teach Alice to use a saved card, or ask for one through a secure card, never the chat;
   - it still needs the person's explicit yes before paying.
2. **The live view is a slideshow, not video.** Several JPEG frames a second reach the phone over long-polling. For real video, stream frames over a WebSocket, or use WebRTC.
3. **The rest of the brief's plan** (shared with the user):
   - (2) a status snippet under Alice's avatar; tapping it opens her activity log and the permissions she has been granted;
   - (3) a proactivity setting (off / less / more), plus approval cards for irreversible browser actions with a caution level;
   - (4) an Ideas tab and first-day tips;
   - (5) a truly personal Alice: the user's own name, avatar and style. The persona currently hard-codes "Marcos".
   - (6) chat bubbles for Alice's messages (ask first).
4. **Gmail isn't connected yet.** The user has to do it.

## How to build and install

See AGENTS.md. In short:

```
cd ios && xcodegen generate && xcodebuild -project Alice.xcodeproj -scheme Alice -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceData -allowProvisioningUpdates CURRENT_PROJECT_VERSION=96 build-for-testing
xcrun devicectl device install app --device A60AE407-5EC1-5B24-8A49-3F5DF1BAF70B .build/DeviceData/Build/Products/Debug-iphoneos/Alice.app
```

Plugin tests:

```
PYTHONPATH=$HOME/.hermes/hermes-agent ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests
```

Static checks:

```
npm run -s check:static
```
