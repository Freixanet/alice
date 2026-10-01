# Dependencies

> **Analyzed HEAD:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

## iOS dependencies

The iOS app has **no third-party Swift packages**. It uses only Apple
frameworks:

| Framework | Purpose |
|-----------|---------|
| SwiftUI | UI framework |
| Foundation | Core types, networking, JSON |
| HealthKit | Read-only health data |
| EventKit | Calendar and reminders |
| CoreLocation | Region monitoring (place triggers) |
| AVFoundation | Voice mode, speech recognition |
| Speech | Speech recognition (dictation) |
| LocalAuthentication | Face ID (app lock, locked notes) |
| UserNotifications | Local notifications |
| WidgetKit | Live Activities |
| BackgroundTasks | Background fetch |
| PhotosUI | Attachment picker |
| QuickLook | File preview |

### Bundled resources

| Resource | Location | Purpose |
|----------|----------|---------|
| InstrumentSerif-Regular.ttf | App bundle | Serif font |
| InstrumentSerif-Italic.ttf | App bundle | Serif italic font |
| BotPortraits.xcassets | Shared with Activities | Agent portraits |

## Web dependencies (npm)

### Production dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| react | ^19.2.0 | UI framework |
| react-dom | ^19.2.0 | DOM rendering |
| @tanstack/react-router | ^1.170.0 | File-based routing |
| @tanstack/react-start | ^1.168.0 | Full-stack framework |
| @tailwindcss/vite | ^4.3.0 | CSS framework (Vite plugin) |
| tailwindcss | ^4.3.0 | CSS framework |
| @radix-ui/react-dialog | ^1.1.15 | Dialog primitive |
| @radix-ui/react-dropdown-menu | ^2.1.16 | Dropdown menu primitive |
| @radix-ui/react-scroll-area | ^1.2.10 | Scroll area primitive |
| @radix-ui/react-slot | ^1.2.4 | Slot primitive |
| @radix-ui/react-switch | ^1.2.6 | Switch primitive |
| @radix-ui/react-tabs | ^1.1.13 | Tabs primitive |
| @radix-ui/react-tooltip | ^1.2.8 | Tooltip primitive |
| @electric-sql/pglite | ^0.5.4 | In-browser Postgres (dev) |
| better-auth | ~1.6.30 | Authentication |
| class-variance-authority | ^0.7.1 | Component variants |
| clsx | ^2.1.1 | Class name composition |
| cmdk | ^1.1.1 | Command palette |
| jose | 6.2.9 | JWT/JWE |
| katex | ^0.18.5 | Math rendering |
| kysely | ^0.28.5 | SQL query builder |
| lucide-react | ^0.510.0 | Icons |
| pg | ^8.16.3 | Postgres driver (prod) |
| react-markdown | ^10.1.0 | Markdown rendering |
| rehype-highlight | ^7.0.2 | Code highlighting |
| rehype-katex | ^7.0.1 | Math rendering |
| remark-gfm | ^4.0.1 | GitHub-flavored markdown |
| remark-math | ^6.0.0 | Math parsing |
| tailwind-merge | ^3.5.0 | Tailwind class merging |
| tw-animate-css | ^1.3.4 | Animation utilities |
| undici | ^7.29.1 | HTTP client |
| zod | ^4.4.0 | Schema validation |
| zustand | ^5.0.0 | State management |

### Dev dependencies (notable)

| Package | Version | Purpose |
|---------|---------|---------|
| vite | ^8.2.0 | Build tool |
| vitest | ^4.1.11 | Test runner |
| @vitejs/plugin-react | ^5.2.0 | React Vite plugin |
| typescript | ^5.7.0 | Type checking |
| eslint | ^9.20.0 | Linting |
| prettier | ^3.4.0 | Code formatting |
| @playwright/test | ^1.62.1 | E2E testing |
| @testing-library/react | ^16.3.3 | Component testing |
| fast-check | ^4.9.0 | Property-based testing |
| knip | ^6.33.0 | Unused dependency detection |
| madge | ^8.0.0 | Circular dependency detection |
| jscpd | ^5.0.16 | Copy-paste detection |
| lightningcss | ^1.28.0 | CSS minification |
| nitro | 3.0.260610-beta | Server runtime (Vercel preset) |
| fake-indexeddb | ^6.2.5 | IndexedDB mock for tests |
| jsdom | ^27.0.1 | DOM environment for tests |

### Pinned versions

- Node: `^22.13.0 || >=24.0.0` (CI uses 24)
- npm: `>=11.0.0` (pinned to 11.19.0 via `packageManager`)
- Override: `nf3` pinned to `0.3.17`

## Hermes plugin dependencies (Python)

| Dependency | Version | Purpose | Source |
|------------|---------|---------|--------|
| Hermes agent | 0.21.x | Agent runtime | Official repo |
| FastAPI | (via Hermes) | Dashboard API router | Hermes venv |
| pydantic | (via Hermes) | Request/response models | Hermes venv |
| pypdf | 6.18.0 | PDF form handling | Vendored to `vendor/` |
| qrcode | (one-time install) | QR code generation | build.sh |

The plugin runs inside Hermes' Python virtualenv
(`~/.hermes/hermes-agent/venv/bin/python`). It does not touch Hermes'
environment. CI installs official Hermes at commit
`b889e4e91cfc5a4a1d7738d8943c801143bf7c7c` for plugin tests.

## Mac notifier dependencies (Python)

Standard library only. Uses macOS notification APIs.

## MCP server dependencies (Node.js)

The cobalt-mcp server is in-tree (`mcp-servers/cobalt-mcp/`). It has its
own `package.json`. Its helpers are covered by
`node --test mcp-servers/cobalt-mcp/lib.test.mjs`.

## External services

| Service | Purpose | Required |
|---------|---------|----------|
| Hermes agent | Agent runtime | Yes |
| Model provider (OpenRouter, Anthropic, OpenAI, etc.) | LLM access | Yes |
| Tailscale | Network connectivity (typical) | Recommended |
| Vercel | Web companion hosting | Web only |
| Neon Postgres | Web companion database (prod) | Web only |
| changedetection.io | Page watching | On-demand |
| Chromium (CDP) | Shared browser | Plugin feature |

## Toolchain requirements

| Tool | Version | Purpose |
|------|---------|---------|
| Xcode | 26 | iOS development |
| XcodeGen | latest | Xcode project generation |
| Swift | 6.0 | iOS compilation |
| iOS SDK | 26.0 | Deployment target |
| Node.js | ^22.13 or >=24 | Web development |
| npm | 11.19.0 | Package management |
| Python | 3.11 | Plugin and notifier |
| gitleaks | 8.30.1 | Secret scanning |
| Playwright | 1.62.x | E2E testing |

## Dependency rules

1. **No new dependency without justification.** ([AGENTS.md](../AGENTS.md))
2. **Prefer existing native mechanisms where appropriate.**
   ([AGENTS.md](../AGENTS.md))
3. **iOS has no third-party packages.** Do not add SPM dependencies without
   strong justification.
4. **`npm run deps:check` (Knip)** fails on unlisted or unused packages.
5. **`npm run security:check` (npm audit)** fails on high+ vulnerabilities.
6. **`npm run cycles:check` (Madge)** fails on circular dependencies.
7. **`npm run duplicates:check` (jscpd)** fails on significant copy-paste.
8. **Bundle budgets** (`npm run bundles:check`) enforce size limits.
9. **The plugin vendors its own dependencies** (`pypdf` in `vendor/`) to
   avoid touching Hermes' environment.
10. **Security patches are applied promptly** — see commits
    `d90d46e` (brace-expansion) and `8ac7975` (undici).
