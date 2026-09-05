# Radar IA

Open **Scheduled tasks → Radar IA**. The initial requested schedule is daily
at **10:00 Europe/Madrid**. Change the time and named time zone, then select
**Configure with Hermes**. This opens a new chat with an editable setup request;
send it to your connected Hermes to perform setup or update an existing routine.

The form is a setup assistant, not a scheduler. Its values are proposed settings,
not saved job state. The request requires Hermes to read back the actual job,
effective time zone, delivery destination and next run before claiming success.
The selected time starts research; delivery follows completion, rather than
guaranteeing a completed report at precisely that minute.

Once Hermes confirms setup, select the owning profile and refresh Scheduled tasks.
Use **Edit** to change the routine's hour, **Pause/Resume**, or **Run now**.
Reopen the setup assistant to request a time-zone change. It must find and update
the existing Radar IA routine rather than create another one.

## Compatibility

The upstream dashboard create operation passes a schedule string to the scheduler;
the inspected implementation resolves cron expressions in the Hermes profile's
configured zone. Alice must not invent a per-job `timezone` field or a `CRON_TZ`
prefix, nor turn Barcelona time into a fixed UTC offset. The setup request asks
Hermes to check its installed version and, when necessary, use an isolated
`radar-ia` profile without changing other routines' time zones.

The runtime needs current web search and page reading, a working model, persistent
history, an active scheduler and a verified way to deliver or read reports in
Alice. `local` delivery alone only saves output; it does not prove Alice can show
it. If delivery is unavailable, setup must explain the missing destination instead
of inventing support or choosing an external service.

The editorial policy includes original sources, evidence qualification, event-date
checks, deduplication, catch-up after failures, transparent partial coverage, and
short daily reports even when nothing important changed. These are instructions
to Hermes; the UI cannot guarantee that a model follows them. No live schedule is
installed merely by deploying this UI change.

Upstream references inspected:

- https://github.com/NousResearch/hermes-agent/blob/main/cron/jobs.py
- https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/web_server_cron.py
