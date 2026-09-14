# Radar IA

Radar IA is a **Hermes bot/profile**, not a special scheduled-task type. Its stable
profile name is `radar-ia`; it owns standing editorial instructions, its normal bot
chat and sessions, and the routine that produces the daily briefing.

## Native iOS

Alice no longer hard-codes Radar IA into **Jobs**. After upgrading from the old
setup-card implementation, Alice offers to create the real `radar-ia` profile when
the Hermes dashboard is reachable. **Create & Configure**:

1. creates the profile if it does not already exist;
2. installs or migrates Alice's versioned Radar IA SOUL without overwriting a
   SOUL the user customized;
3. sets and reads back the selected IANA time zone on that profile;
4. creates or updates exactly one bot-owned daily routine through Hermes'
   native management API, then reads it back before reporting success;
5. opens the ordinary Radar IA bot conversation.

After that, Radar IA appears in **Bots** and behaves like every other Hermes bot.
**Jobs** shows only jobs Hermes actually reports; if Radar IA has a working daily
routine, that routine appears there naturally instead of through a synthetic UI
row.

The requested default is **10:00 Europe/Madrid**. This time is the start of
research; delivery follows when the report is complete.

## Runtime verification

Alice deliberately does not manufacture a per-job timezone field. It writes the
selected zone to the `radar-ia` profile configuration, uses the schedule syntax
accepted by Hermes' native routine editor, and reads back the profile timezone and
the profile-owned routine before setup can complete.

It does not create a second Radar profile, duplicate an ambiguous routine, invent
a per-job `timezone` field or `CRON_TZ` prefix, or convert Barcelona time to a fixed
UTC offset. A conflicting custom routine is left untouched and surfaced as an
error.

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
