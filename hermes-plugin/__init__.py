"""Alice for Hermes.

Everything this plugin does lives in the dashboard: ``dashboard/plugin_api.py`` serves
pairing and memory under ``/api/plugins/alice/``, and ``dashboard/dist/index.js`` is the
Alice tab. The agent itself gains nothing — no tools, hooks or commands.
"""


def register(ctx) -> None:
    """Nothing to register outside the dashboard."""
    return None
