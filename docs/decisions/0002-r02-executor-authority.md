# ADR 0002 — Portable Alice purchase execution, independent of Hermes internals

**Status: Proposed / R02 P0 BLOCKED (revised 2026-10-11).** [PR #76](https://github.com/Freixanet/alice/pull/76)
is **DRAFT / NO-GO to merge**. This record replaces its earlier **upstream-Hermes-dependent proposal** while retaining the historical version in Git. It does **not** claim an Alice Secure Runner has been shipped, installed, secured or proven.

## Product invariant (non-negotiable)

Alice must be distributable to anyone who connects it to a **compatible, unmodified, official Hermes installation**. No private Hermes fork, core changes, monkeypatch, local hand-edit of an executor or upstream PR acceptance may be required. Necessary Alice components must be bundled and provisioned through an ordinary user-facing onboarding path, not individual operator instructions. Any platform/hosting restriction or explicit payment-merchant limitation must be shown honestly.

**Old ADR error corrected:** the previous text treated a new required `register_action_authorizer` API in Hermes core as a condition to unblock R02. That is **not an acceptable product dependency**. Upstream improvements can be proposed separately, but Alice's trust boundary and functionality must be owned by Alice itself.

## Evidence, official interfaces and non-solutions

- Official Hermes plugins can add scoped tools via `ctx.register_tool`, including a dedicated `alice_shopping` toolset; plugins also support installation/distribution and versioned configuration. [Official plugin documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins). This is a **coordination interface**, not an OS sandbox.
- Alice already talks to Hermes through its supported `POST /v1/runs`, polling/status and stop paths (`hermes-plugin/errands.py::Gateway`). This is a **potential zero-extra-plugin coordination transport**, not yet a proven multi-step planner protocol: Alice would send bounded observations, treat every Hermes text/action reply as an untrusted proposal, validate it against a strict schema and independently execute or reject it. The official API's ability to produce reliable typed plans across supported versions and model configurations still requires integration testing. There is no assumption of a new Hermes model-only or tool-free API.
- Hermes supports configurable toolsets per profile (`platform_toolsets` and dashboard profile configuration). They improve ergonomics for an Alice planning profile but do **not** stop a compromised/privileged Hermes process from accessing its machine, browser or network. They are never the payment security boundary.
- Hermes **browser-provider plugins are NOT the required security solution**: the official provider contract returns a CDP WebSocket URL to Hermes, whose own browser stack drives it. Doing that with Alice's secret-bearing browser would expose its control surface again. [Official browser-provider documentation](https://hermes-agent.nousresearch.com/docs/developer-guide/browser-provider-plugin).
- `pre_tool_call` and `tool_execution` middleware are **not mandatory fail-closed controls** for the inspected Hermes source: `_pre_tool_block` catches exceptions and permits a call; `_run_execution_chain` skips a failing middleware before `next_call`. `browser_exec` has inner subprocess actions; native clicks, console/JS, CDP and dialogs have other paths. `scripts/verify-r02-executor-contract.py` demonstrates five **synthetic policy-decision gaps** (exit 2 expected); this is not proof of a real charge.
- Current Alice's managed Chrome uses a shared Hermes-reachable CDP port, browser contexts only partition cookies, and password/card flows use Hermes Vault. This **cannot** be reclassified as Alice's isolated payment runner. Existing checkout “Pagar” resumes the autonomous Hermes run; existing browser takeover is temporary. These flows **must not** serve as the new authority.

## Decision: Alice owns the privileged execution boundary

Keep Hermes as a **planner/coordinator**, treating its prompts, model outputs, plugin calls, labels, URLs, session IDs and arguments as **untrusted input** for payment purposes. Alice Secure Runner (ASR) is a separate first-party service whose API accepts **typed, narrowly scoped commands**, never arbitrary JS, CDP, a terminal, filesystem paths or user-chosen network requests.

```text
Alice app (user approval + device-authenticated signing)
                  │
                  ▼
Alice Coordinator / Policy Service (trusted principal, durable state)
     │                                     │
     │ plan/observation (no secrets)       │ authorized typed operations
     ▼                                     ▼
Official Hermes /v1/runs             Alice Secure Runner
or optional official Alice toolset   • private browser + network boundary
(untrusted coordinator)              • exclusive isolated cookies/login data
                                      • credentials/payment token custody
                                      • verifier + one-use checkout execution
                                              │
                                              ▼
                                   merchant / PSP permitted integration
```

### Portable delivery and onboarding

1. **Default portable path (not universal service coverage yet):** Alice-hosted, tenant-isolated ASR reachable over authenticated HTTPS. The customer installs Alice, pairs an official compatible Hermes instance, consents to Alice-hosted shopping, and signs in to merchants **inside ASR's isolated user-controlled flow**. No executable is installed on the Hermes host and no special Hermes setting is needed for the security boundary. This makes the **technical integration independent of the user's Hermes OS**, but actual availability still depends on Alice running a reliable hosted service, supported network/region, user consent, eligibility and possibly a paid plan. Serving every otherwise compatible user/region is a **release obligation still unproven**; failure means no autonomous ASR service, with an honest fallback. The service must fund compute/bandwidth, protect tenant data and sessions, encrypt at rest/in transit, define data residency/retention and incident response, and use appropriate PCI/PSP tokenization rather than assuming a browser vault alone makes payment data compliant. No free/offline/always-on guarantee is implied.
2. **Optional private path:** a signed Alice Runner package with unattended setup on **verified** OS/container/VM isolation primitives, separate OS/security principal, private IPC and enforced egress. Provisioning must fail closed when permissions or runtime prerequisites are absent; never quietly fall back to same-user `launchd`, a plain local CDP port or a Python in-process plugin. No blanket guarantee of automatic private hosting on every OS.
3. **Hermes integration:** the proposed _base_ adapter uses `/v1/runs` as a planning channel, **conditional on demonstrated structured-turn and recovery compatibility**. A packaged official Alice plugin/`alice_shopping` toolset can optionally streamline callbacks, observations, status and activity (installed through Hermes' documented plugin flow, with any required user consent). The runner does not rely on that plugin for authorization. Probe the actual supported API/version during pairing; do not presume host administration or plugin installation rights. Without a plugin Alice must itself operate the plan/execute loop and validate/fail closed on malformed model replies; this has **not** been integrated or verified.
4. **Account/key lifecycle:** Alice, not Hermes, pairs the runner to the user, stores runner access and user secrets in its own custody, rotates/revokes credentials and encrypts tenant state. Hermes receives only public item information, redacted observations, opaque non-authorizing correlation IDs and results. Never return runner browser WebSocket, raw cookies, vault IDs, bearer capabilities or payment details through Hermes, logs or model context.

### Non-bypass boundary (explicit scope)

Only ASR holds merchant sessions, payment instruments, checkout APIs and the private browser profile. Hermes has **no route** to ASR's CDP/IPC, private keys or raw browser network endpoint. ASR accepts no script, `Runtime.evaluate`, native CDP, shell, arbitrary HTTP or out-of-band browser action from the model. Network egress from the runner is mediated with policy and isolated per user/job; authentication and quotas are enforced **by ASR**, not by `pre_tool_call`.

Hermes can retain its **own** standard browser, terminal and network on its **own** host for unrelated tasks. A `/v1/runs` call may itself invoke ordinary tools and produce effects on that host, **even when Alice only wants a plan**; Alice must not send protected checkout data or authorize those effects. Toolset/profile selection is advisory for this threat model, and the no-plugin planning transport must be tested for unexpected tool calls. This architecture cannot claim to restrict arbitrary actions made by a separately privileged Hermes agent or payment credentials already stored **outside Alice** (including the existing shared Hermes Vault). The defensible claim is narrower and testable: **Hermes cannot access or actuate ASR-owned browser sessions, payment instruments, checkout intents or final-submission endpoints except through the runner's checked API**. This **does not guarantee** Hermes cannot act on the same external merchant account by using other credentials already held by the user/Hermes. For the Alice-scoped guarantee the user must enter/migrate purchase credentials into Alice's private vault and avoid giving equivalent payment credentials to Hermes. The existing Alice buying flow must stop using the shared CDP/vault before ASR can be enabled.

No same-user local process isolation is accepted merely because it has a separate port. A local runner without proven platform isolation/egress is unavailable, not a degraded security mode; hosted ASR remains the default path.

### Action and approval protocol (proposed, not implemented)

Every call from Hermes is a **proposal**, not permission. Alice Coordinator authenticates the actual account, session/run association and request provenance from its paired connection, not from model-supplied identifiers. ASR checks its own current context and policy immediately before dispatch. Unsupported/unknown actions are denied:

```text
ProposedAction v1 (untrusted): {job_id, action: navigate|inspect|select|input|cart_adjust|checkout_prepare|checkout_commit,
                               target_ref, typed_values}

TrustedAction v1 (Alice Coordinator → ASR):
  tenant_id, actor_id, job_id, step_id, operation_hash
  runner_session_id, context_id, target_id, frame_id, document_epoch
  current_origin, allowed_destination, exact operation and resolved target
  expiry, monotonic_step, policy_version, authorization_id (when required)

CheckoutAuthorization v1 (created only by Alice after real user confirmation):
  user_id, merchant_id / trusted merchant account, checkout_id, cart/order fingerprint
  item IDs, variants, quantities, delivery and recipient commitment
  amount_minor, ISO currency, taxes/shipping, selected payment method
  recipient merchant payment endpoint/integration, one-use intent ID, expiry
  user confirmation signature or server-authenticated decision bound to exact digest
```

Runner compares trustworthy merchant/PSP state with approved digest, consumes a **single-use** authorization with transactional durable compare-and-swap before a **known** final operation, and does not grant any other operation by implication. Cross-user, tab, frame, item, amount, currency, recipient, destination, currency conversion, reused token, stale document, unknown price or approval mismatch **deny**. Serialize competing submits. If a request was sent and its effect is unknown, mark `unknown/reconciliation_required` and **never retry blindly**, including after restart. A database transaction cannot be atomic with an external merchant charge; reconcile using merchant-supported idempotency/status/receipts or human confirmation, with no false “paid” claim.

### Actual charge semantics: autonomy without invented protection

**Arbitrary clicks are not independently provable safe.** A product button can execute JavaScript, contact a merchant API or submit a GET with side effects. A generic HTTP proxy cannot reliably distinguish every merchant's definitive payment API from ordinary cart mutations, and browser-origin scripts can trigger redirects and opaque PSP actions. Merchant page text or a DOM selector is not a reliable payment authorization source.

ASR therefore defines **levels of execution**:

| Flow                                                                                        | Allowed autonomy                                              | Security condition / fallback                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Product research, compare, visible reads                                                    | High; Hermes plans, ASR returns bounded redacted observations | Clean Alice browser with no payment/login secrets; no arbitrary JS API, restricted navigation and egress                                                                                                                                                                               |
| Cart preparation and ordinary selection                                                     | High for verified no-payment contexts                         | Typed ASR actions; adapter, capability restrictions and risk controls; uncertain side effect stops for user                                                                                                                                                                            |
| Login, address, account data                                                                | Coordinated; secrets entered/handled only inside ASR          | Trusted secure user-entry flow, origin binding, privacy protection; do not feed secrets to Hermes                                                                                                                                                                                      |
| **Autonomous approved purchase**                                                            | **Enabled only per certified merchant/PSP adapter**           | Merchant/API returns **independently verifiable** order and exact payable amount and supports a uniquely bound final submit, idempotent/reconcilable outcome. ASR submits one approved intent from its backend, **not a generic browser click**. No blanket merchant coverage promised |
| Unsupported shop, unknown charge semantics, card-on-file purchase or uncertain PSP redirect | Agent prepares a review but cannot submit final effect        | User completes checkout in ASR's human-only browser/PSP surface after agent control is revoked, or opens merchant independently; do not promise transferable cookies                                                                                                                   |

ASR's commerce adapters require independent review/versioning per supported merchant/PSP and fail closed on markup/API drift. **Adapter admission requirements:** an authorized and sufficiently stable merchant/PSP API or documented integration; an independently read final cart/recipient/charge amount; precisely scoped payment credential/tokenization; evidence of definitive server-side submission semantics; replay/idempotency or transaction status/reconciliation; handling of taxes, shipping, refunds, PSP authentication/3DS and API drift; and tests proving that bypassed/unknown network effects never charge. A proprietary undocumented checkout discovered by browsing is **not certified** just because it passed mock tests. Merchant terms, automation restrictions, fraud controls, CAPTCHAs and regional payment methods may restrict adapter coverage. Remote browser sessions may break passkeys/WebAuthn, Apple Pay, device-bound payments, IP/location-sensitive prices and anti-bot policies. Detect incompatibility and hand off without claiming the remote cart transfers to the person's device. A card-on-file account can purchase without a visible card form: this is why merely refusing card fill or blocking a labeled “Pay” button is inadequate. User auth must be captured by trusted Alice UI, not Hermes's generic approval or a model-generated tool result.

### Manual finalization is a real transition, not the current approval button

The coordinator requests stopping Hermes's shopping run **and independently revokes/fences all ASR write capabilities using a monotonic runner epoch**, drains or records in-flight effects, persists `awaiting_human_finalization`, then issues a user-only browser session or safe merchant link. `POST /v1/runs/{id}/stop` alone cannot guarantee a submitted merchant request was canceled. If an effect was already dispatched, mark `unknown` and reconcile rather than granting an ambiguous agent/human race. Human actions authenticate separately; Hermes cannot access the human session. On reconnect/restart, `ensure_running` must **not** restart a paused write-capable run. The current `decide_checkout` → `approved_message` → `resume` and `_answer_approval` automatic card consent **must be separated** from the new flow before enabling it. UI displays exact product/total/currency, timestamp and a clear “Revisar y finalizar personalmente”; never calls an unverified checkout `paid`.

## Compatibility matrix and release gates

| Requirement                                     | Proven today                                                    | Must verify before release                                                                                                                                                            |
| ----------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Official unmodified Hermes can be a coordinator | Existing `/v1/runs` API + plugin registration; source inspected | Multi-turn plan/result contract across supported released Hermes versions, pairing, replay/reconnect/cancel, fallback without plugin                                                  |
| No Hermes access to ASR secrets/browser         | **Not implemented**; old Chrome/Vault are shared                | Hostile-Hermes adversarial tests: read env/files, CDP probes, private URLs, subagent, arbitrary network, forged tool results, cross-tenant isolation                                  |
| Setup works for any compatible installation     | **Not demonstrated**                                            | Fresh user onboarding on Linux/macOS/Windows Hermes hosts, hosted runner by default without manual executor setup, offline/permissions/region handling, UI consent                    |
| Typed actions and ordinary site usability       | Existing **plugin** unit tests only                             | Real hosted ASR+Hermes synthetic HTTPS shop, product search, variant/cart, login and total; concurrency, tabs/popups, redirects, DOM read and denial UX                               |
| Approved autonomous checkout                    | **Not implemented or certified**                                | Independently verifiable checkout intent, exact digest+signature+amount/currency+cart, one-use submit, external timeout/reconciliation, certified adapters, zero actual charges in CI |
| Safe unsupported-shop handoff                   | **Not implemented**                                             | Stop/revoke/hand over browser including crash/restart, no auto card consent, preserve honest `pending/unknown` status                                                                 |

### Threat tests required (fail securely)

Negative cases include opaque final button, immediate/deferred JS/network, CDP/console/keyboard/dialog, tab/frame switch, stale document, other merchant/recipient/item/qty/currency/total, expired/denied/forged/replayed consent, concurrent submit, bridge disconnection, server restart, unknown outcome, merchant checkout drift, PSP cross-origin/3DS, malicious tool outputs, tenant confusion, direct probing of ASR URL/ports/files, and Hermes terminal+browser with no ASR credentials. Runner egress tests include SSRF/cloud metadata, DNS rebinding, WebSockets, service workers, `sendBeacon`, hidden iframes and delayed network effects. User approval tests include a device-authenticated challenge signing the exact digest (`user_id`, checkout ID, cart/recipient, amount in minor units, ISO currency, nonce and expiry), replay/tampering, revocation and another device/session. Also verify absence of default stored merchant cards in the clean runner. In a fictional HTTPS shop, record no outbound financial operation without the exact approved adapter intent and no second submission after consumed/unknown intent.

Positive cases include browsing and DOM reads without secrets, step-by-step ordinary interactions, adding/removing products, cart accuracy, checkout preparation, full user-approved **synthetic** adapter purchase exactly once and independently confirmed receipt, and human handoff with no agent write capability. Real browser E2E is mandatory; synthetic source canaries and a green plugin CI cannot establish these guarantees.

## Delivery and migration plan (nothing here is implemented)

1. Introduce independent Alice Coordinator/ASR protocol, tenant isolation and hosted runner prototype with fictional shop; Hermes generic `/v1/runs` adapter first. **Do not reuse shared Hermes Chrome/Vault**.
2. Test official Alice plugin enhancement separately (optional) and capability probing. Make pairing/onboarding handle runner registration and user consent automatically.
3. Migrate **only Alice purchase tasks** to the new runner; gate/disallow old autonomous checkout path until tested, including old shared-browser and Hermes Vault checkout. Never mutate users' unrelated Hermes tools/profiles globally. Existing users need a consented migration/re-authentication flow, with cleanup of old Alice-owned shared-browser sessions and clear instructions to revoke or remove duplicate Hermes merchant/payment credentials where desired; a copy of a Hermes-vault secret does not revoke the Hermes original, and Alice cannot silently delete unrelated user credentials.
4. Add human-only fallback, then certified payment adapters, closed-loop amount verification, durable idempotency and risk controls; test end-to-end across platforms and merchants.
5. Only enable autonomous checkout for adapters which pass all threat/positive gates. If hosted runner or merchant adapter unavailable, display a usable explicit human completion flow, not a silent downgrade.

**Decision:** R02 remains **P0 / NO-GO**. PR #76 is **DRAFT, unmerged**. No Hermes core changes, private fork or installation-specific executor configuration are prerequisites. Contributing generic upstream APIs later may improve ergonomics, but is **not** on Alice's critical path. The prior Hermes-core-dependent design is superseded by this **proposed** Alice-owned boundary; compatibility, privacy and security guarantees remain pending real implementation and tests. R03/R07 remain separate.

**Scope warning:** this ADR corrects the **purchase-security architecture**, not every existing Alice feature. The current compatibility matrix still records macOS-specific QR provisioning and optional host-browser dependencies elsewhere. Alice's broader requirement for every feature to work across compatible Hermes installations needs separate product-wide compatibility evidence; it is **not** established by writing this ADR or by PR #76, and no unrelated platform work is initiated here.
