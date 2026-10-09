"""Local equivalents of Dash's MIT detectors; see THIRD_PARTY_NOTICES.

No GPS, Contacts read, travel-time inference or automatic external actions.
Birthdays and follow-up timers are explicitly supplied by the user/agent.
"""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from zoneinfo import ZoneInfo


TRIAGE_CODE = '''
questions = {"action": {"type": "choice", "options": {"notify": "Useful next step now", "quiet": "Nothing to tell", "defer": "Uncertain; reconsider later"}}}
decision = classify({"event": event, "checkpoint": state.get()}, questions)
action = decision["action"]
if action["key"] == "quiet":
    ack(event["id"])
elif action["key"] == "notify" and action["confidence"] >= 0.8:
    notify(event["body"], event["id"])
    ack(event["id"])
'''


def timestamp(text):
    date = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if date.tzinfo is None:
        raise ValueError("Use an explicit time zone for watcher dates.")
    return date.timestamp()


def items(home, config, now):
    kind = config["kind"]
    today = datetime.fromtimestamp(now, ZoneInfo(config.get("time_zone", "UTC"))).date()
    out = []
    if kind == "birthday":
        for person in config.get("birthdays", []):
            when = datetime.strptime(person["date"], "%Y-%m-%d").date()
            try:
                when = when.replace(year=today.year)
                if when < today:
                    when = when.replace(year=today.year + 1)
            except ValueError:  # Feb 29: do not invent another birthday date.
                continue
            if (when - today).days in (0, 1):
                out.append({"id": f"birthday:{person['name']}:{when}", "subject": person["name"], "category": "family",
                            "body": f"{person['name']}'s birthday is {when}. Consider drafting a message or planning a gift."})
    elif kind == "follow_up":
        for reminder in config.get("follow_ups", []):
            if not reminder.get("resolved") and timestamp(reminder["due_at"]) <= now:
                out.append({"id": "follow-up:" + reminder["id"], "subject": reminder["subject"], "category": "social",
                            "body": reminder["body"], "sender": reminder.get("sender", "")})
    elif kind == "leave_now":
        snapshot = json.loads((Path(home) / ".alice/calendar.json").read_text())
        if not snapshot.get("connected") or now - timestamp(snapshot.get("updated_at", "1970-01-01T00:00:00Z")) > 900:
            raise ValueError("Connect or refresh the calendar before using leave-now watches.")
        minutes = config.get("travel_minutes")
        if not isinstance(minutes, (int, float)) or isinstance(minutes, bool) or not 0 <= minutes <= 240:
            raise ValueError("Supply a verified travel time in minutes; Alice will not guess it.")
        for event in snapshot.get("events", []):
            location = event.get("location", "").strip()
            if not location or event.get("all_day") or any(word in location.lower() for word in ("http", "zoom", "online", "virtual", "tbd", "teams")):
                continue
            start = timestamp(event["start"])
            if start > now >= start - (minutes + 10) * 60:
                identity = str(event.get("id") or event.get("title")) + ":" + event["start"]
                out.append({"id": "leave:" + identity, "subject": event["title"], "category": "schedule",
                            "body": f"{event['title']} starts at {event['start']} at {location}. Travel takes {minutes} minutes plus a 10-minute buffer. Time to leave."})
    return out
