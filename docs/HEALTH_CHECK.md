# Alice Health Check

**Analyzed HEAD SHA:** `2420a2f89a229ceb334d06e933e1c7a1881f9271`

A lightweight diagnostic that answers: **"Is Alice healthy right now? If not,
which layer is failing?"**

## How to run

### On the Mac (Hermes host)

```bash
bash scripts/alice-doctor.sh
```

This checks every layer Alice depends on: Node.js, the web build, the Hermes
plugin, the gateway, the dashboard, local ports, and the notifier.

### On the iPhone

Settings → Advanced → Developer mode → Checks. This runs the in-app diagnostic
which checks Hermes reachability, plugin, calendar, notifications, storage, and
more. See [verification](verification.md) for details.

## Output format

The script prints one line per check:

```
[OK]    node         Node.js v24.0.0 found
[OK]    npm          npm 11.19.0 found
[FAIL]  hermes       Hermes command not found
[DEGRADED] gateway   Port 8643 not listening
[OK]    dashboard    Dashboard responding on port 9119
[OK]   plugin        Alice plugin installed at ~/.hermes/plugins/alice
[FAIL]  notifier     LaunchAgent not loaded
```

Exit code: `0` if all checks pass or are degraded, `1` if any check fails.

## Health states

| State       | Meaning                                                |
| ----------- | ------------------------------------------------------ |
| `HEALTHY`   | All critical checks pass                               |
| `DEGRADED`  | Non-critical component missing or partially available   |
| `BROKEN`    | A critical component is missing or not responding       |

## Checks performed

### Mac-side checks (`scripts/alice-doctor.sh`)

| Check            | What it verifies                          | Critical |
| ---------------- | ------------------------------------------ | -------- |
| `node`           | Node.js 22.13+ installed                  | Yes      |
| `npm`            | npm 11+ installed                         | Yes      |
| `xcodegen`       | XcodeGen installed (iOS builds)            | No       |
| `hermes`         | Hermes CLI available                      | Yes      |
| `gateway`        | Gateway port listening                    | Yes      |
| `dashboard`      | Dashboard port responding                 | Yes      |
| `plugin`         | Alice plugin installed and enabled        | Yes      |
| `plugin-tests`   | Plugin test suite passes                  | No       |
| `notifier`       | Notifier LaunchAgent loaded               | No       |
| `web-deps`       | `node_modules` present                    | No       |
| `web-build`      | Web build succeeds                        | No       |
| `migrations`     | All migrations applied                    | Yes      |
| `env-config`     | Required env vars set (production only)   | Context  |
| `tailscale`      | Tailscale running (if expected)           | No       |
| `disk-space`     | At least 5 GB free                        | No       |
| `cdp-port`       | Port 9222 not in use by tests             | No       |

### iPhone-side checks (in-app, Developer mode)

| Check            | What it verifies                          |
| ---------------- | ------------------------------------------ |
| Hermes reach     | Gateway responds to probe                  |
| Hermes latency   | Gateway responds within timeout            |
| Plugin present   | Alice plugin endpoints respond             |
| Time zones       | Single time zone across all agents         |
| Calendar         | Calendar access granted                    |
| Notifications    | Notification permissions set               |
| Bark             | Bark key configured (if notifier used)     |
| Routines         | Proactive routines configured              |
| Storage size     | Settings under 256 KB (warns if over)      |
| Freezes          | No main-thread freezes in last 10 min      |
| Unknown events   | No unrecognized Hermes events              |

## Interpreting results

### Common failures and remediation

| Symptom                          | Likely cause                          | Remediation                                           |
| -------------------------------- | ------------------------------------- | ----------------------------------------------------- |
| `hermes` not found               | Hermes not installed or not in PATH   | Install Hermes 0.21.x; add to PATH                     |
| `gateway` port not listening     | Gateway not started or wrong port     | Check `~/.hermes/profiles/<name>/.env` for `API_SERVER_PORT` |
| `dashboard` not responding       | Dashboard service not running         | `launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard` |
| `plugin` not installed           | `hermes-plugin/install.sh` not run    | Run `hermes-plugin/install.sh`                          |
| `plugin` not enabled             | Plugin disabled in Hermes config      | `hermes plugins enable alice --no-allow-tool-override`  |
| `notifier` not loaded            | Notifier not installed                | Run `mac/notifier/install.sh`                           |
| `migrations` pending             | `npm run db:migrate` not run           | Run `npm run db:migrate` against production database    |
| `tailscale` not running          | Tailscale not connected                | Check `tailscale status`; start if needed              |
| Hermes unreachable from iPhone   | Network or Tailscale issue             | Verify same network or Tailscale; check firewall       |
| CORS error in web direct mode    | Hermes not configured for Alice origin | Add Alice origin to Hermes CORS config                  |

## Safety

The health check never prints:
- API keys, tokens, or passwords
- Private message content
- Hermes addresses or URLs with credentials
- User account identifiers

It is safe to share the output with an AI coding agent or in a GitHub issue.
