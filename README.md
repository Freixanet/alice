# Alice

A native iPhone app for your own [Hermes agent](https://hermes-agent.nousresearch.com):
talk to it, watch it work and let it run errands for you. Hermes and your model keys stay
on your own Mac or server.

[![Quality](https://github.com/Freixanet/alice/actions/workflows/quality.yml/badge.svg)](https://github.com/Freixanet/alice/actions/workflows/quality.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Status:** a personal project in active daily use and development. It is not on the App
Store; you build it with Xcode. It needs iOS 26 and a Hermes you run yourself. It is an
independent project, not a Nous Research product.

[Get started](#get-started) · [What it does](#what-it-does) · [How it is built](#how-it-is-built) · [Limitations](#limitations) · [Guía en español](docs/getting-connected.md)

## Why it exists

Hermes is a capable open agent, but on a phone you usually reach it through a messaging
bot. That works for questions. It works less well when the agent is buying something,
signing in to a site or needs your approval halfway through a task. Alice is the phone
side of that work:

- you see the page the agent is on, live, and can take over;
- logins, cards, keys and verification codes are typed into secure sheets and go to
  Hermes' vault on your Mac, never into the chat;
- an irreversible step, such as paying, waits for one explicit "Pay" from you.

## What it does

### Works today, used daily

- **Chat with Hermes and its agents.** Streaming replies, tool activity, Markdown,
  attachments and model choice. Each agent keeps its own conversation and Hermes session.
- **A live view of the agent's browser.** The page the agent is on appears in the chat as
  it navigates. Tap it to take control, then hand it back.
- **Secure sheets instead of pasting secrets.** A site login, a one-time code, an API key
  or a payment card goes straight to Hermes. The chat only learns that it was saved.
- **Approvals that say what they approve.** Hermes' approval requests become cards in the
  chat instead of a raw command.
- **Morning and evening briefings.** The morning one covers today's appointments and what
  to prepare, due and overdue reminders, open goals, the Mac's health (disk, memory,
  battery, whether Hermes is running) and errors logged overnight. The evening one lists
  what was left open, with one "Remind me tomorrow" button.
- **Agenda, goals and notes.** Your iPhone's calendar and reminders are shared with your
  own Hermes, never a third party. Goals carry a plan the agent keeps up to date.
- **Connections.** Hermes' connector catalogue (Notion, Linear, Figma and others), shown
  with each product's own logo, to connect or disconnect from the phone.
- **Other channels.** The same Alice answers in Telegram and in iMessage (through
  [Photon](https://photon.codes)). iMessage replies are reformatted as plain text messages.

### Built, still being proven in daily use

- **Buying online up to the payment.** Alice fills the basket, address and delivery, stops
  at your one "Pay" (a card that reads "Alice will pay on this site with your Visa ···4242"), pays on the bank's page (for example Redsys) with the card saved for it, then
  tells you whether the payment went through, was declined or failed. An approval sent
  while the phone was locked comes back into the chat when you open it. Real
  purchases have exposed bugs that have since been fixed. It is not yet reliable enough to
  leave unattended.
- **Tasks that keep going until they are done.** For a task with several steps, the agent
  opens a Hermes session goal. A separate judge model then sends it back to work when it
  stops at a solvable obstacle, and accepts "done" only with proof such as an order number.
- **Place triggers.** "When I get to the supermarket, remind me of the oil." The iPhone
  watches the place with iOS region monitoring and tells Hermes only that you arrived or
  left, never where you are.
- **Health.** Sleep, steps, activity, resting heart rate, HRV, mindfulness and medication
  from Apple Health (a WHOOP or Apple Watch reaches it through Health). The morning
  briefing mentions only what is clearly off against your own last four weeks. Goals such
  as "sleep 7 hours" or "10,000 steps a day" measure themselves.
- **Voice you can talk over.** A hands-free voice mode on the iPhone's own recogniser and
  voices. You can interrupt her by speaking, and what you say while she works reaches the
  running task.
- **Learning from corrections.** When you correct Alice, the lesson is kept as a standing
  instruction, quoting your words. Skills Hermes writes are applied automatically after a
  safety review.

## Get started

### You need

- A Mac or server running **Hermes 0.21.x**, with a model provider configured. Alice does
  not install Hermes or provide a model.
- A Mac with **Xcode 26**, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an
  Apple developer account, to sign the app for your iPhone.
- An **iPhone with iOS 26**. The phone must reach Hermes, either on the same network or
  through [Tailscale](https://tailscale.com), which is the usual setup.

### 1. Add the Alice plugin to Hermes

On the machine that runs Hermes, from a clone of this repository:

```bash
git clone https://github.com/Freixanet/alice.git
cd alice
hermes-plugin/install.sh
```

The script copies the plugin to `~/.hermes/plugins/alice` and enables it. On macOS it also
restarts the Hermes dashboard. Restart any running Hermes gateway too: Hermes loads plugins
once per process. The plugin adds the pairing QR and what the app needs from Hermes.

### 2. Build the app onto your iPhone

```bash
brew install xcodegen        # once
cd ios && xcodegen generate  # writes Alice.xcodeproj from project.yml
open Alice.xcodeproj
```

In Xcode, choose your team under Signing, select your iPhone and press Run.

### 3. Pair

Open the Hermes dashboard, go to the **Alice** tab and scan the QR with the iPhone camera.
Alice opens, saves the connection in the iPhone's Keychain and shows **Hermes: Connected**
under Settings. You can also connect by hand with the Hermes address and key.

Then try it. Ask "What do I have tomorrow?" after connecting your calendar, or "Find me
flights to Palma on 12 October under €100". The step-by-step guide, in Spanish, is in
[docs/getting-connected.md](docs/getting-connected.md).

<details>
<summary>If something does not connect</summary>

- **No Alice tab in the dashboard:** the plugin is not enabled in that Hermes, or the
  dashboard was not restarted after installing it.
- **The code expired or was already used:** open the Alice tab again for a new QR.
- **Alice cannot find Hermes:** the phone cannot reach that address. Check that both are
  on the same network or on Tailscale, and that Hermes is running.

</details>

## How it is built

| Part                               | Stack                                | What it does                                                         |
| ---------------------------------- | ------------------------------------ | -------------------------------------------------------------------- |
| [`ios/`](ios/)                     | SwiftUI, iOS 26, Keychain, HealthKit | The app                                                              |
| [`hermes-plugin/`](hermes-plugin/) | Python, Hermes plugin API            | Pairing, memory, briefings, cards, health, places, safety hooks      |
| [`hermes-agents/`](hermes-agents/) | Python and Markdown                  | Alice's persona, routines (morning, appointments, evening) and evals |
| [`src/`](src/)                     | React 19, TanStack Start, TypeScript | A web companion                                                      |
| [`mac/notifier/`](mac/notifier/)   | Python, macOS                        | Optional notifications from the Mac                                  |

Decisions that shape it:

- **Official Hermes, no fork.** Everything Alice needs from the server lives in a Hermes
  plugin, using its public hooks (tools, prompt sections, `pre_tool_call`,
  `transform_llm_output`). Updating Hermes does not overwrite Alice.
- **Hermes' own safety stays in charge.** Cards and logins go into Hermes' vault. Payments
  still pass Hermes' confirmation. Alice adds checks on top and never removes any:
  - after an agent has read a web page or an email, a command that could send data out of
    the Mac or read secrets needs your approval, with the exact command shown;
  - a skill that reads like an injected instruction is held back instead of applied.
- **Deterministic where it can be.** Health patterns come from plain statistics: at least
  14 days of data and a correlation of at least 0.4. Card formats are checked with the
  Luhn algorithm. The model is used for the parts that need judgement, not for arithmetic.
- **The phone never becomes the server.** No push infrastructure and no cloud of our own.
  The iPhone talks to your Hermes over your network. Background delivery is best effort,
  as iOS allows.

More detail: [architecture](docs/architecture.md), [pairing protocol](docs/pairing.md),
[Hermes contracts](docs/hermes-contracts.md), [security](SECURITY.md).

## Limitations

- **Not on the App Store.** You need Xcode and an Apple developer account to install it.
- **Not a hosted service.** It needs a Hermes you run yourself and a model provider you
  pay for.
- **Agents depend on the model.** Long web tasks, buying in particular, succeed or fail
  with the model's ability. Smaller models skip steps that larger ones follow.
- **Not all checks run on the development Mac.** It is an Intel machine with no iOS
  simulator, so UI tests there do not run. The app is checked by building and installing
  it on a real iPhone, and CI runs the simulator suites.
- **iOS wakes background apps when it chooses.** When the phone is locked, a notification
  or approval can wait until you open the app.
- **WhatsApp is not supported.** WhatsApp's official agent API is not public yet, and
  Alice does not use unofficial WhatsApp Web clients.

## Quality

- **Tests:** about 980 iOS unit test cases, 281 plugin tests and 81 web test files, plus
  end-to-end browser tests.
- **CI:** runs a secret scan, type and lint checks, bundle budgets, the plugin tests, the
  Playwright suites and the iOS simulator suites
  ([workflow](.github/workflows/quality.yml)).
- **Commands:**

  ```bash
  bash scripts/verify-ios.sh all                    # iOS unit and UI tests, needs a simulator
  npm ci && npm run check                           # web: types, lint, unit and contract tests
  python -m unittest discover -s hermes-plugin/tests  # with Hermes' virtualenv
  ```

What each suite does and does not prove is in [docs/verification.md](docs/verification.md).

## Who built it

Designed and directed by Marc Freixanet. Much of the code was written with AI coding agents
(Claude Code, Codex) working under the rules in [AGENTS.md](AGENTS.md). That file holds
the contracts, the verification steps and a checklist that asks every change for evidence.
The 700+ commit history shows how features were specified, reviewed and fixed, including
the fixes that followed real-world failures.

## Contribute and report

- Start with [CONTRIBUTING.md](CONTRIBUTING.md).
- Report security issues privately, as [SECURITY.md](SECURITY.md) explains.
- Keep credentials and private conversations out of issues and screenshots.

[MIT](LICENSE) © Marc Freixanet
