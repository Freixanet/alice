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

import re
from typing import Any, Dict

MAX_TURNS = 12
CONTINUATION_PREFIX = "[Continuing toward your standing goal]"

CONSTRAINTS = (
    "Never press a button that pays, sends, publishes or deletes without the person's explicit yes "
    "for this task (for a payment: their approval of the checkout sent with checkout_request). Never ask for or write a password, card number or code in the chat: "
    "those go through the secure cards. Anything else the person must choose or give (an option, how to pay, how to sign "
    "in, name, ID/NIF, address, phone, email) is asked with ask_person, never in the text of the reply, and the "
    "work that does not depend on the answer goes on meanwhile. Do not change what the person asked for (product, quantity, "
    "dates, price seen) on your own. Before claiming done, the facts the result depends on (price, "
    "date, availability, requirements) must have been checked with tools, not assumed; anything left "
    "unchecked must be named in the reply as «Sin comprobar: …». Done requires PROOF in the reply, read "
    "back after acting: an order or booking number, the confirmation text, the saved item as the page "
    "shows it. A claim of success without that proof is not done: continue and verify."
)
STOP_WHEN = (
    "Stop ONLY when the reply shows one of these, and asks the person one concrete question: "
    "(a) everything is ready and the next click is the irreversible one (pay, send, confirm), waiting "
    "for their yes — for a payment, checkout_request was called and the checkout waits for their approval; (b) continuing would change what they asked for (another product, a higher price, "
    "an extra cost, other dates); (c) something only the person has is needed (a password, a card, a "
    "code) and was asked through the secure card; or (d) a question is open with ask_person and nothing "
    "else can be done until it is answered — that is a wait, not a stop to repeat. A reply that asks "
    "the person something in its own text (a question mark addressed to them) is never a valid stop: "
    "continue, telling the agent to ask that same question with ask_person (a card) instead. A CAPTCHA or anti-bot "
    "check (Cloudflare, «verify you are human») is only the person's: ask them with ask_person to solve it in "
    "the live browser («Abrir navegador» in Alice) and wait. Any other obstacle on "
    "the site — a basket left from before, an incomplete or invalid form, a pop-up, an expired session, "
    "a page error, a button that does not respond — is NEVER a reason to stop: the agent must look at "
    "the page, fix it and try other ways. When what was asked does not exist exactly (that size, that "
    "flavour, out of stock), a reply that only says so is not a stop either: continue, telling the agent to "
    "ask with ask_person between the real alternatives it has checked on the page. A reply that only reports such an obstacle is not done and "
    "not blocked: continue. 'Not found' is an obstacle too, not a stop, until the agent has checked its "
    "past conversations for it, tried the official product name and variants, and searched the web "
    "restricted to that shop."
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


# An errand the person asked for: buy, order, book, or fill a basket. Left to the model, a
# "prepare the basket" was never given a goal, so nothing sent it back when it stopped to report
# that the size it wanted did not exist instead of offering the real ones.
ERRAND = re.compile(
    r"\b(c[oó]mpra(me|lo|la|los|las)?|comprar|p[ií]de(me|lo|la)?|pedir|res[eé]rva(me|lo|la)?|reservar"
    r"|carrito|cesta|a[nñ]ade\w*\s+al\s+carrito)\b", re.I)


def auto_start(user_message: Any, session_key: str) -> bool:
    """Opens the goal for an errand the person just asked for, when the agent has none yet."""
    from hermes_cli.goals import GoalManager

    text = " ".join(str(user_message or "").split())
    if not session_key or not text or text.startswith(("[respuesta:", CONTINUATION_PREFIX)):
        return False
    if not ERRAND.search(text) or GoalManager(session_id=session_key).is_active():
        return False
    return start(text, "What was asked is done or ready at the last step (in the basket, or at the pay "
                       "or confirm button waiting for the person), checked on the page itself.",
                 session_key).get("ok", False)


# The last reply to a goal continuation, by session, as its words.
_LAST_REPLY: Dict[str, set] = {}


def _words(text: str) -> set:
    return set(re.findall(r"\w{3,}", str(text or "").lower()))


def guard_repeat(user_message: Any, reply: Any, session_key: str) -> bool:
    """Pauses the goal when the agent, sent back by the judge, answers what it answered last time.

    Agent and judge could disagree for good: the agent would not change the basket without asking,
    the judge would not accept it, and the same message reached the person turn after turn. Only
    replies to the goal's own continuations count; the person's messages never do."""
    from hermes_cli.goals import GoalManager

    if not session_key or not str(user_message or "").startswith(CONTINUATION_PREFIX):
        return False
    manager = GoalManager(session_id=session_key)
    if not manager.is_active():
        _LAST_REPLY.pop(session_key, None)
        return False
    now, before = _words(reply), _LAST_REPLY.get(session_key)
    _LAST_REPLY[session_key] = now
    if before and len(now) >= 6 and len(now & before) / len(now | before) >= 0.6:
        manager.pause("sin avances: repetía la misma respuesta")
        _LAST_REPLY.pop(session_key, None)
        return True
    return False


def run_tool(args: Dict[str, Any]) -> Dict[str, Any]:
    from tools.approval_context import get_current_session_key

    return start(str(args.get("task") or ""), str(args.get("done_when") or ""),
                 get_current_session_key(default=""))


def prompt() -> str:
    return (
        "Cuando empieces una tarea de varios pasos (una compra, preparar un carrito, una reserva, un "
        "formulario, un alta), "
        "llama primero a `finish_task` con la tarea y cómo se ve terminada; vuelve a llamarla cuando la "
        "persona te dé lo que esperabas (su sí, una tarjeta, una elección). Así un juez revisa cada "
        "respuesta y te devuelve al trabajo si paraste por un obstáculo que podías resolver."
    )
