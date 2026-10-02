# ADR-0002: The phone never becomes the server

## STATUS

Accepted

## CONTEXT

Alice is an iPhone app that talks to a Hermes agent on a Mac. The phone
could theoretically host a server, use push notifications, or relay through
a cloud service. These approaches would make Alice more available but add
infrastructure, cost and privacy risk.

## DECISION

The iPhone talks directly to Hermes over the network (same LAN or
Tailscale). No push infrastructure, no cloud relay, no hosted server. The
phone is always the client.

## EVIDENCE

- README: "Not a hosted service. It needs a Hermes you run yourself."
- README: "The phone never becomes the server. No push infrastructure and no cloud of our own."
- architecture.md: "The iPhone talks to your Hermes over your network."
- `HermesAddress.swift` — validates addresses, restricts plain HTTP to private networks
- No APNs or push notification code in the iOS app

## ALTERNATIVES CONSIDERED

No evidence of alternatives being considered. The decision appears to be a
founding principle.

## WHY THIS APPROACH EXISTS

Alice is a personal project for one user. The user runs their own Hermes.
Adding push or cloud infrastructure would require servers, credentials and
maintenance that a personal project cannot justify. Direct network access
is sufficient for daily use.

## CONSEQUENCES

- When the phone is locked, a notification or approval can wait until the
  app is opened.
- Background delivery is best-effort, as iOS allows.
- No always-on guarantee while the app is closed.
- No cloud bills, no server maintenance, no third-party data access.

## RISKS

- The person misses time-sensitive approvals or notifications while the
  phone is locked or the Mac is sleeping.
- iOS background execution is unreliable.

## WHEN TO REVISIT

If Alice needs reliable background delivery (e.g., for time-sensitive
payments), a hosted relay/APNs path would be needed. This is a significant
infrastructure decision and should not be taken lightly.
