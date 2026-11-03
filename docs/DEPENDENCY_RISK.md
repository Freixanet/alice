# Alice Dependency Risk Audit

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

This document inventories Alice's major dependencies and classifies them by
lock-in risk. The goal is independence without architecture astronautics —
seams are recommended only where provider failure is plausible and
consequential.

## Classification

| Class                       | Meaning                                                      |
| --------------------------- | ------------------------------------------------------------ |
| CRITICAL + HARD TO REPLACE  | Failure stops Alice; replacement is expensive or uncertain   |
| IMPORTANT BUT REPLACEABLE   | Failure degrades Alice; replacement is feasible              |
| COMMODITY                   | Standard, widely available; replacement is trivial           |
| UNNECESSARY                 | Could be removed without significant loss                    |

## Inventory

### Model providers and AI APIs

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| Model provider (OpenAI/Anthropic/etc.) | CRITICAL + HARD TO REPLACE | Alice talks to models through Hermes' gateway. The provider key lives in the Hermes profile `.env`. Alice itself does not call model APIs directly. |

**Analysis:**
1. **Alice-specific logic coupled to it?** No. Alice sends messages through Hermes; the model is chosen through Hermes' model catalog. Alice does not format requests for a specific provider.
2. **Data Alice owns?** Conversations, prompts, tool results — all in Alice/iOS storage.
3. **If pricing changes dramatically?** Switch providers in Hermes profile settings. Alice's UI supports model selection and fallback providers.
4. **If the API changes?** Hermes handles API compatibility. Alice uses Hermes' standardized chat/run endpoints.
5. **If the service disappears?** Configure a new provider. Fallback providers mitigate.
6. **Replacement difficulty?** Low for Alice (just change Hermes config). The coupling is to Hermes, not to the provider.
7. **Seam justified?** No. Alice already has no direct coupling to model providers. Hermes is the seam.

### Hermes

| Dependency | Class                       | Coupling                                                          |
| ---------- | --------------------------- | ----------------------------------------------------------------- |
| Hermes 0.21.x | CRITICAL + HARD TO REPLACE | Alice's entire architecture is built on Hermes. The plugin uses Hermes' hooks, the iOS app talks to Hermes' gateway and dashboard. |

**Analysis:**
1. **Alice-specific logic?** The plugin (`hermes-plugin/`) is deeply integrated with Hermes' plugin API, dashboard auth, and vault system.
2. **Data Alice owns?** Conversations on iOS, sync records in web DB. Hermes owns its databases.
3. **If pricing changes?** Hermes is open-source (Nous Research). Self-hosting is free.
4. **If the API changes?** Alice has contract fixtures and capability detection. The compatibility matrix tracks versions.
5. **If the service disappears?** Fork Hermes. The codebase is open.
6. **Replacement difficulty?** Very high. Alice is architecturally built around Hermes.
7. **Seam justified?** No — Hermes IS the seam. Alice is intentionally built on it.

### Search/research providers

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| Exa (search)         | IMPORTANT BUT REPLACEABLE   | Plugin `free_web.py` and `hermes-agents/internet` use Exa for web search. The key is stored in Hermes vault. |
| Firecrawl            | IMPORTANT BUT REPLACEABLE   | Used for page fetching in Hermes agents. |
| GitHub CLI (`gh`)     | COMMODITY                   | Used for GitHub operations in Hermes agents. |
| RSS feeds (EL PAÍS, BBC, NASA) | COMMODITY        | iOS Feed feature fetches RSS directly. No API key needed. |

**Analysis for Exa:**
1. **Alice-specific logic?** The plugin's `free_web.py` wraps Exa. The internet agent uses it through `reach`.
2. **Data Alice owns?** None — Exa returns search results.
3. **If pricing changes?** Switch to alternative search (SearXNG, Brave Search API).
4. **If the API changes?** Update the wrapper in `free_web.py`.
5. **If the service disappears?** Fall back to Firecrawl or direct URL fetching.
6. **Replacement difficulty?** Medium — the wrapper is isolated in one file.
7. **Seam justified?** Partial. The `free_web.py` wrapper already acts as a seam. No additional abstraction needed.

### External services

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| Vercel (web hosting) | IMPORTANT BUT REPLACEABLE   | Web companion is deployed on Vercel. Could self-host. |
| Neon (Postgres)      | IMPORTANT BUT REPLACEABLE   | Production database. PGLite fallback exists for dev. `DATABASE_URL` swap. |
| Tailscale            | COMMODITY                   | Network transport. Could use any VPN or LAN. |
| Bark (notifications) | COMMODITY                   | Free iOS push service. Could use APNs directly with a paid account. |
| Photon (iMessage)    | COMMODITY                   | iMessage bridge. Could remove without breaking core functionality. |
| changedetection.io   | COMMODITY                   | Page watch feature. Self-hosted, Docker-based. |

### Swift packages

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| SwiftUI (Apple)      | CRITICAL + HARD TO REPLACE  | The entire iOS app is SwiftUI. Cannot change without full rewrite. |
| HealthKit (Apple)    | IMPORTANT BUT REPLACEABLE   | Health features. Could remove without breaking core chat. |
| Foundation (Apple)   | CRITICAL + HARD TO REPLACE  | Standard library. |

### Backend packages (npm)

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| React 19             | CRITICAL + HARD TO REPLACE  | Web companion UI. Full rewrite to change. |
| TanStack Start/Router | CRITICAL + HARD TO REPLACE | Web framework. Full rewrite to change. |
| Better Auth          | IMPORTANT BUT REPLACEABLE   | Web auth. Could replace with custom auth. |
| Kysely               | IMPORTANT BUT REPLACEABLE   | SQL query builder. Could swap for raw SQL or Drizzle. |
| PGLite               | IMPORTANT BUT REPLACEABLE   | Local dev database. Fallback for Neon. |
| Zod                  | IMPORTANT BUT REPLACEABLE   | Schema validation. Could swap for Valibot or ArkType. |
| Zustand               | COMMODITY                   | State management. Could swap for Jotai or native React state. |
| pypdf (Python)        | COMMODITY                   | PDF form filling. Standard library. |

### Web packages

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| Tailwind CSS 4       | IMPORTANT BUT REPLACEABLE   | Styling. Deeply integrated but replaceable. |
| Radix UI             | COMMODITY                   | Headless UI primitives. |
| Vite 8               | IMPORTANT BUT REPLACEABLE   | Build tool. Could swap for esbuild/turbopack. |
| Vitest 4             | COMMODITY                   | Test runner. |
| Playwright            | COMMODITY                   | E2E testing. |

### MCP/tool integrations

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| Cobalt MCP server    | IMPORTANT BUT REPLACEABLE   | Media extraction. Self-contained in `mcp-servers/cobalt-mcp/`. |
| Hermes MCP catalog   | CRITICAL + HARD TO REPLACE  | Tightly coupled to Hermes' MCP system. |

### Infrastructure providers

| Dependency           | Class                       | Coupling                                                          |
| -------------------- | --------------------------- | ----------------------------------------------------------------- |
| GitHub (repo + CI)    | IMPORTANT BUT REPLACEABLE   | Could migrate to GitLab or self-host. CI uses GitHub Actions. |
| Apple Developer Program | CRITICAL + HARD TO REPLACE | Required for iOS signing. No alternative. |

## Critical dependency deep-dive

### Hermes (CRITICAL + HARD TO REPLACE)

**What Alice-specific logic is coupled to it?**
- Plugin API (pairing, memory, notes, vault, health, places, browser, errands)
- Gateway protocol (chat, runs, models, approvals, streaming)
- Dashboard RPC (profiles, sessions, groups)
- Capability detection (version, features)

**What data does Alice own?**
- iOS conversations (Keychain + UserDefaults)
- Web sync records (encrypted, in Neon/PGLite)
- User preferences

**What happens if pricing changes?**
Hermes is open-source and self-hosted. No pricing changes affect Alice.

**What happens if the API changes?**
Contract fixtures catch breaking changes. Capability detection gates new
features. The compatibility matrix tracks supported versions.

**What happens if the service disappears?**
Fork Hermes. The plugin uses only official hooks. Alice's iOS app uses standard
HTTP — it would work against any compatible gateway.

**How difficult is replacement?**
Very high. Alice is architecturally built around Hermes. Replacing it would
require rewriting the plugin, the iOS networking layer, and the web companion.

**Is a seam justified?** No. Hermes IS the seam. Alice is intentionally a
front-end for Hermes.

### Model provider (CRITICAL + HARD TO REPLACE)

**What Alice-specific logic is coupled to it?**
None. Alice sends messages through Hermes. The model is chosen through
Hermes' model catalog. Alice does not format requests for specific providers.

**Is a seam justified?** No. Alice already has no direct coupling. Hermes is
the seam.

### Vercel (IMPORTANT BUT REPLACEABLE)

**What Alice-specific logic is coupled to it?**
- `vercel.json` (CSP headers, caching)
- Vercel-specific env vars
- Immutable deployment URLs

**What happens if pricing changes?**
Self-host the web companion. The app is a standard TanStack Start app.

**Is a seam justified?** No. The app is framework-agnostic enough to deploy
elsewhere. The `vercel.json` is configuration, not coupling.

### Neon (IMPORTANT BUT REPLACEABLE)

**What Alice-specific logic is coupled to it?**
None beyond standard Postgres. The `db.ts` module already has a PGLite
fallback for development.

**What happens if pricing changes?**
Set `DATABASE_URL` to any Postgres provider. No code changes needed.

**Is a seam justified?** Already exists. The `DbSource` type and `getSql()`
function in `db.ts` abstract the database backend.

## Recommended seams

Based on the audit, only one additional seam is recommended:

### No new seams needed

Alice's architecture already has the right boundaries:
- Hermes is the seam between Alice and model providers.
- The plugin is the seam between Alice and Hermes internals.
- `db.ts` is the seam between the web app and the database.
- `gateway-contracts.ts` is the seam between Alice and Hermes' API.
- Capability detection is the seam between Alice and new Hermes features.

Adding more abstraction layers would be architecture astronautics. The
existing boundaries are well-chosen and tested.

## Dependency pinning status

| Layer       | Pinned?          | Mechanism                          |
| ----------- | ---------------- | ---------------------------------- |
| npm         | Yes              | `package-lock.json` (exact versions)|
| Swift       | Yes              | `ios/project.yml` (version specs)  |
| Python      | Yes              | `pypdf==6.18.0` in install.sh       |
| Hermes      | Yes              | Commit hash in CI workflow          |
| Skills      | Yes              | `skills-lock.json` (hash-pinned)    |
| Node.js     | Yes              | `engines` in package.json           |
| Xcode       | Partial          | `deploymentTarget` in project.yml  |

## Conclusion

Alice's dependency strategy is sound. The critical dependencies (Hermes,
Apple ecosystem) are intentionally chosen and not realistically replaceable.
The important dependencies (Vercel, Neon) already have fallbacks or seams.
No additional abstraction layers are warranted at this time.
