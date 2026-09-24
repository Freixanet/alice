"""Keep an agent on a task until it is done, not until it meets the first obstacle.

Instructions alone do not stop a model from ending a turn to report a problem it could
have solved (a basket left from an earlier try, an address the shop marks incomplete).
Hermes has the mechanism for this: a session goal (``hermes_cli.goals``, the ``/goal``
command). After each turn a separate judge model reads the goal, its completion contract
and the agent's reply; unless the reply shows the goal done or a real stop condition, it
sends the agent back to work with a continuation message, up to a turn budget.

The ``finish_task`` tool lets the agent open that goal itself when it takes on a task of
several steps, with a contract that says what counts as done and that an obstacle on the
site is never a reason to stop. The only stops are the ones that need the person: the
final irreversible click, a change to what was asked, or something only the person has.
"""

from __future__ import annotations

from typing import Any, Dict

MAX_TURNS = 12
CONTINUATION_PREFIX = "[Continuing toward your standing goal]"

CONSTRAINTS = (
    "Never press a button that pays, sends, publishes or deletes without the person's explicit yes "
    "for this task (in the chat, or for a card payment in Hermes' card confirmation). Never ask for or write a password, card number or code in the chat: "
    "those go through the secure cards. Do not change what the person asked for (product, quantity, "
    "dates, price seen) on your own. Before claiming done, the facts the result depends on (price, "
    "date, availability, requirements) must have been checked with tools, not assumed; anything left "
    "unchecked must be named in the reply as «Sin comprobar: …». Done requires PROOF in the reply, read "
    "back after acting: an order or booking number, the confirmation text, the saved item as the page "
    "shows it. A claim of success without that proof is not done: continue and verify."
)
STOP_WHEN = (
    "Stop ONLY when the reply shows one of these, and asks the person one concrete question: "
    "(a) everything is ready and the next click is the irreversible one (pay, send, confirm), waiting "
    "for their yes — for a card payment, Hermes' card confirmation is that yes; (b) continuing would change what they asked for (another product, a higher price, "
    "an extra cost, other dates); (c) something only the person has is needed (a password, a card, a "
    "code, a choice about their personal data) and was asked through the secure card. An obstacle on "
    "the site — a basket left from before, an incomplete or invalid form, a pop-up, an expired session, "
    "a page error, a button that does not respond — is NEVER a reason to stop: the agent must look at "
    "the page, fix it and try other ways. A reply that only reports such an obstacle is not done and "
    "not blocked: continue."
)

SCHEMA: Dict[str, Any] = {
    "name": "finish_task",
    "description": (
        "Commit to finishing a task of several steps (a purchase, a booking, a form, a sign-up, a "
        "search that needs a website). Call it once when you start such a task, and again when the "
        "person gives you what you were waiting for (their yes, a card, a choice). After each of your "
        "replies a judge checks the result and, unless the task is done or needs the person, sends you "
        "back to keep working. Not for simple questions."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "task": {
                "type": "string",
                "description": "What the person asked, in their words and with the details that matter "
                               "(what, how many, where, for when, any limit on price).",
            },
            "done_when": {
                "type": "string",
                "description": "What the finished result looks like, the proof you will quote (order number, "
                               "confirmation text) and what must be checked to trust it, e.g. "
                               "'order confirmation page with an order number' or, before their yes, "
                               "'checkout ready at the pay button with 1 × item, total and delivery'.",
            },
        },
        "required": ["task", "done_when"],
    },
}


def start(task: str, done_when: str, session_key: str) -> Dict[str, Any]:
    """Open (or replace) the session goal for this task."""
    from hermes_cli.goals import GoalContract, GoalManager

    task = " ".join(str(task or "").split())[:1000]
    done_when = " ".join(str(done_when or "").split())[:600]
    if not task:
        return {"ok": False, "error": "Say what the task is."}
    if not session_key:
        return {"ok": False, "error": "No chat session to keep the task in; carry on without it."}
    contract = GoalContract(outcome=task, verification=done_when, constraints=CONSTRAINTS, stop_when=STOP_WHEN)
    manager = GoalManager(session_id=session_key, default_max_turns=MAX_TURNS)
    manager.set(task, max_turns=MAX_TURNS, contract=contract)
    return {"ok": True, "max_turns": MAX_TURNS,
            "next": "Work until done_when is met or a real stop condition; obstacles on the site are yours to solve."}


def run_tool(args: Dict[str, Any]) -> Dict[str, Any]:
    from tools.approval_context import get_current_session_key

    return start(str(args.get("task") or ""), str(args.get("done_when") or ""),
                 get_current_session_key(default=""))


def prompt() -> str:
    return (
        "Cuando empieces una tarea de varios pasos (una compra, una reserva, un formulario, un alta), "
        "llama primero a `finish_task` con la tarea y cómo se ve terminada; vuelve a llamarla cuando la "
        "persona te dé lo que esperabas (su sí, una tarjeta, una elección). Así un juez revisa cada "
        "respuesta y te devuelve al trabajo si paraste por un obstáculo que podías resolver."
    )
