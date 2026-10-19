# Alice — External Dependencies

Everything Alice depends on outside its own code, by surface. Versions are
those pinned in the repository. **UNKNOWN** marks missing evidence.

## iOS app

**Third-party packages: none.** `ios/project.yml` declares no SPM/CocoaPods
packages; the app uses only Apple frameworks (SwiftUI, Observation,
CryptoKit, OSLog, WidgetKit, UserNotifications, HealthKit, EventKit,
CoreLocation, Speech, LocalAuthentication — evidenced by the imports across
`ios/Alice/` and the entitlements/usage descriptions in `project.yml`).

Toolchain requirements:

| Dependency | Version / rule | Evidence |
| --- | --- | --- |
| Xcode | 26 (CI selects `Xcode_26*.app`) | `.github/workflows/quality.yml` |
| iOS deployment target | 26.0 | `ios/project.yml` |
| Swift | 6.0, strict concurrency complete, warnings as errors | `ios/project.yml` settings |
| XcodeGen | current (brew) | `ios/README.md` |
| Apple developer account | signing team `2DYYWXP5XL` | `ios/project.yml` |

System frameworks the app integrates (from `project.yml` Info.plist and
entitlements): HealthKit (read-only), calendars/reminders full access,
location when-in-use + always (region monitoring), camera, microphone,
speech recognition, Face ID, Live Activities, background fetch.

## Hermes plugin (Python)

| Dependency | Version | Why | Evidence |
| --- | --- | --- | --- |
| Hermes | 0.21.x required; CI pins commit `b889e4e91cfc5a4a1d7738d8943c801143bf7c7c` (0.21.3); fixtures cover 0.20.6–0.21.3 | host platform + dashboard API | `.github/workflows/quality.yml`, `docs/hermes-contracts.md` |
| FastAPI | provided by Hermes' dashboard (plugin mounts an `APIRouter`) | dashboard backend | `dashboard/plugin_api.py` imports |
| Pydantic | provided by Hermes' env | request models | `plugin_api.py` imports |
| PyYAML | profile.yaml reads | `__init__.py` `_read_yaml` |
| pypdf | 6.18.0, vendored into the plugin's `vendor/` folder | PDF form read/fill; keeps Hermes' env untouched | `hermes-plugin/install.sh` |
| changedetection.io | installed on demand (Docker) | page watches | `page_watch.py`, `docs/compatibility-matrix.md` |
| Python | 3.11 in CI for plugin tests | `quality.yml` |

## Web client

Runtime dependencies (`package.json` "dependencies"):

| Package | Version | Role |
| --- | --- | --- |
| react / react-dom | ^19.2.0 | UI |
| @tanstack/react-router / react-start | ^1.170 / ^1.168 | routes, server rendering |
| vite | ^8.2.0 (devDep) + @vitejs/plugin-react | build |
| nitro | 3.0.260610-beta | server runtime for TanStack Start |
| tailwindcss + @tailwindcss/vite + tw-animate-css | ^4.3.0 | styling |
| @radix-ui/* (dialog, dropdown, scroll-area, slot, switch, tabs, tooltip) | pinned minors | accessible primitives |
| zustand | ^5.0.0 | client state |
| zod | ^4.4.0 | contract validation (incl. telemetry) |
| better-auth | ~1.6.30 | accounts (Postgres adapter) |
| @electric-sql/pglite + pg + kysely | ^0.5.4 / ^8.16.3 / ^0.28.5 | local DB (PGlite) and production Postgres (Neon) |
| jose | 6.2.9 | JWT/JWE for auth and sealed credentials |
| undici | ^7.29.1 | fetch/WebSocket on the server |
| react-markdown + remark-gfm + remark-math + rehype-katex + rehype-highlight + katex | latest pinned | chat markdown, math, code |
| lucide-react, cmdk, class-variance-authority, clsx, tailwind-merge | — | UI utilities |

Dev/test dependencies of note: TypeScript ^5.7, ESLint 9 +
typescript-eslint, Prettier, Vitest 4 (+coverage-v8), Playwright 1.62,
Testing Library, jsdom, fake-indexeddb, fast-check (property tests), knip
(unused deps/files), madge (import cycles), jscpd (duplication),
lightningcss. Node engine: `^22.13.0 || >=24.0.0`; npm pinned to 11.19.0
(`package.json` engines/packageManager; CI installs Node 24 + npm 11.19.0).

Security scanning: gitleaks 8.30.1 (pinned in CI), `npm audit
--audit-level=high`, knip dependency check (`quality.yml`,
`SECURITY.md` "Supply chain").

## Mac notifier

Python 3.9+ standard library only; **Bark** (free iOS app) as the push
channel (`mac/notifier/alice_notifier.py` docstring).

## External services and infrastructure

| Service | Used for | Evidence |
| --- | --- | --- |
| Hermes (self-hosted) | the agent itself; everything routes through it | whole repo |
| Model providers (user-configured) | LLM access; "Alice does not … provide a model" | [README.md](../README.md) |
| Tailscale (+ Funnel) | phone→Mac reachability; web exposure via `scripts/phone.mjs` | [README.md](../README.md), `scripts/phone.mjs` |
| Vercel + Neon Postgres | web client production hosting and database | `vercel.json`, `.env.example`, `docs/release-operations.md` |
| Google OAuth | optional web sign-in | `.env.example` |
| Bark | push notifications from the Mac | `mac/notifier/` |
| Photon | iMessage channel for Alice's answers | [README.md](../README.md) "Other channels" |
| Telegram | alternate channel | [README.md](../README.md) "Other channels"; `hermes-plugin/text_channel.py` |
| Shop catalog | purchase option discovery (`catalog_search`) | `catalog.py`, `docs/purchases.md` |
| Redsys (and other bank pages) | payment pages the errand pays on | [README.md](../README.md), `docs/HANDOFF.md` |
| EL PAÍS / BBC / NASA RSS | Feed's bounded catalogue | `docs/verification.md` |
| Agent-Reach 1.5.0 (uv venv, Python 3.13) + Exa, Firecrawl, mcporter, gh, rss-feeds, reddit-reading | internet access from the Hermes host | `docs/internet.md` |
| changedetection.io | page watches (installed on demand) | `page_watch.py` |
| Xcode build / devicectl | device installs | `AGENTS.md` |
| GitHub Actions (ubuntu-latest, macos-26) | CI; free because the repo is public; the dev Mac must not run CI | `quality.yml` comments |

## Repository-pinned externals

- `skills-lock.json`: hash-pinned external skills `apple-design`
  (`emilkowalski/skills`) and `design-review` (`Superfuture/design-review`).
- The committed `.hermes/profiles/descargas/` sample profile is a local
  fixture, not a service dependency.

## Update policy (as documented)

- Hermes: follow [the release-delta checklist](hermes-contracts.md); update
  fixtures with exact source commits; keep older regression cases; run the
  read-only live contract check against a dedicated test installation
  (`docs/verification.md` "Hermes updates").
- npm: `npm ci` with the pinned npm version; security patches drove past
  bumps (e.g. undici, brace-expansion — commit messages `8ac7975`,
  `d90d46e`).
- The plugin vendors pypdf so "Hermes' environment is not touched"
  (`install.sh`); anything else the plugin needs should follow the same
  pattern.
- Unknown or older Hermes versions never receive unadvertised fields
  (`docs/hermes-contracts.md`).
