# Radar IA

Radar IA is a **Hermes bot/profile**, not a special Alice product. Its stable
profile name is `radar-ia`. If that profile exists on the installation, Alice
treats it like every other agent: canonical bot chat, standing instructions,
and whatever routines Hermes actually reports.

## Native iOS

Alice does not offer, create or migrate Radar IA. There is no auto-presented
installer and no Jobs setup card. A briefing agent is made the same way as any
other: a sentence on **New Agent**. The new agent asks what it still needs.

An existing `radar-ia` profile is left untouched. Alice still recognises its
editorial routine when listing work Hermes already has, so a briefing that was
set up earlier keeps appearing under Routines. Alice does not write a Radar
SOUL, timezone or daily job unless the person does that themselves through the
ordinary agent and routine editors.

## Editorial behaviour

The standing instructions that used to ship with the installer cover current
models and capabilities, tools, agents, automation, Hermes/Alice, research,
open models/local AI, prices, licenses and availability. They prioritise
original sources, check event dates, qualify evidence, and produce a short
daily Spanish briefing even when there is nothing major.

The web companion may still expose an assisted setup entry under scheduled
tasks. That path targets the same `radar-ia` Hermes profile. It does not
change the data model: Radar IA is the bot; the cron entry is only one routine
owned by that bot.
