# Alice release operations

Every API response includes `X-Alice-Version` and `X-Alice-Environment`.
`GET /api/status` returns the same closed release identity with `Cache-Control:
no-store`; it contains no deployment URL, account identifier or secret.

## Verify a deployment

Run `npm run release:verify -- https://alice-ten-phi.vercel.app`. Verification
fails unless the endpoint is healthy and its body and release header identify the
same version. Record that version alongside the immutable Vercel deployment URL
before promoting it.

## Alerts

Runtime logs use two machine-readable record types:

- `alice_operational` for bounded anonymous measurements.
- `alice_alert` for stable alert codes and `warning` or `critical` severity.

Configure the production log monitor to page on every `critical` Alice alert and
notify the engineering channel on `warning`. Keep logs for no more than 30 days.
The monitor deliberately excludes prompts, responses, user/account identifiers,
Hermes addresses, filenames and arbitrary error text.

Immediate critical signals cover server and sync failures, severely slow local
handlers and severely degraded Web Vitals. Burst thresholds protect auth,
client-runtime and Hermes-connection alerts from isolated noise. Repeated alerts
are cooled down for one minute per code, route and metric.

## Rollback

1. Select the last known-good immutable production deployment in Vercel.
2. Promote that deployment to the production alias; do not rebuild it.
3. Run the release verifier against the production alias and confirm that its
   version matches the selected deployment.
4. Exercise login, `/connect`, one Hermes read and one chat request.
5. Preserve the failed release logs and open a corrective change from `main`.

Database changes remain additive and backward-compatible across releases, so a
code rollback must never require a destructive database rollback.
