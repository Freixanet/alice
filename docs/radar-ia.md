# Radar IA

Radar IA is a **Hermes bot/profile**, not a special scheduled-task type. Its stable
profile name is `radar-ia`; it owns standing editorial instructions, its normal bot
chat and sessions, and the routine that produces the daily briefing.

## Native iOS

Alice no longer hard-codes Radar IA into **Jobs**. After upgrading from the old
setup-card implementation, Alice offers to create the real `radar-ia` profile when
the Hermes dashboard is reachable. **Create & Configure**:

1. creates the profile if it does not already exist;
2. installs the Radar IA SOUL when the profile has no standing instructions;
3. opens the ordinary Radar IA bot conversation;
4. sends one setup request from that bot so Hermes can inspect the installed
   runtime and create or update the bot-owned daily routine safely.

After that, Radar IA appears in **Bots** and behaves like every other Hermes bot.
**Jobs** shows only jobs Hermes actually reports; if Radar IA has a working daily
routine, that routine appears there naturally instead of through a synthetic UI
row.

The requested default is **10:00 Europe/Madrid**. This time is the start of
research; delivery follows when the report is complete.

## Runtime verification

Alice deliberately does not manufacture a per-job timezone field. Hermes versions
can derive cron time from the effective profile/runtime timezone, and multi-profile
scheduler behavior has changed across releases. The setup request therefore makes
Radar IA inspect the installed version, reuse/update an existing Radar routine by
identifier, verify ownership by `radar-ia`, and read back the actual state before
claiming success.

It must not create a second Radar profile, duplicate the routine, invent a
`timezone` API field or `CRON_TZ` prefix, or convert Barcelona time to a fixed UTC
offset. If the installed runtime cannot guarantee the requested local time, it must
report that limitation rather than presenting the schedule as correct.

The runtime also needs current web search/page reading, a working model, persistent
history, an active scheduler and a verified path for the result to be readable from
Alice. Saving output locally is not by itself proof of delivery to Alice.

## Editorial behavior

The Radar IA SOUL covers current models and capabilities, tools, agents,
automation, Hermes/Alice, research, open models/local AI, prices, licenses and
availability. It prioritizes original/current sources, checks event dates and
product availability, qualifies evidence, deduplicates repeated announcements,
recovers missed important items, and produces a short daily Spanish briefing even
when there are no major developments.

The web client may still expose an assisted setup entry under scheduled tasks, but
that setup targets the same `radar-ia` Hermes profile. It does not change the data
model: Radar IA is the bot; the cron entry is only one routine owned by that bot.
