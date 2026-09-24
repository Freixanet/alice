"""Replies for channels that show text as typed (iMessage, SMS): readable, not a wall.

The model is asked to write plainly there (prompt section ``alice.canal``), but it still
slips into markdown and long paragraphs. This runs on the final reply for those channels
(the ``transform_llm_output`` hook) and makes it read like a text message:

- ``[text](url)`` becomes the text and, on its own line, the URL (iMessage makes it a link;
  Hermes' own markdown stripping dropped the URL);
- ``**bold**``, ``_x_``, backticks and ``#`` headings lose their symbols;
- list markers become ``•``;
- a paragraph longer than a couple of lines is split into its sentences, one per paragraph.
"""

from __future__ import annotations

import re

PLATFORMS = {"photon", "sms", "imessage", "bluebubbles"}
LONG_PARAGRAPH = 220

_LINK = re.compile(r"\[([^\]\n]+)\]\((https?://[^)\s]+)\)")
_BOLD = re.compile(r"(\*\*|__)(.+?)\1", re.S)
_ITALIC = re.compile(r"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])")
_CODE = re.compile(r"`{1,3}([^`]*)`{1,3}")
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+", re.M)
_BULLET = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+", re.M)
# A sentence ends at . ! ? … followed by a space and a capital, an opening ¿ ¡ or a quote.
_SENTENCE_END = re.compile(r"(?<=[.!?…])\s+(?=[A-ZÁÉÍÓÚÑ¿¡«\"“(0-9])")


def _paragraphs(text: str) -> list:
    return [p for p in re.split(r"\n\s*\n", text) if p.strip()]


def _split_long(paragraph: str) -> list:
    if len(paragraph) <= LONG_PARAGRAPH or "\n" in paragraph.strip():
        return [paragraph.strip()]
    sentences = [s.strip() for s in _SENTENCE_END.split(paragraph.strip()) if s.strip()]
    return sentences or [paragraph.strip()]


def plain(text: str) -> str:
    """The reply as a readable text message."""
    if not text:
        return text
    # Links become a placeholder first, so a paragraph holding one is still one line to split.
    links = []

    def keep(match):
        links.append(f"{match.group(1).strip()}:\n{match.group(2)}")
        return f"\x00{len(links) - 1}\x00"

    out = _LINK.sub(keep, text)
    out = _BOLD.sub(r"\2", out)
    out = _ITALIC.sub(r"\1", out)
    out = _CODE.sub(r"\1", out)
    out = _HEADING.sub("", out)
    out = _BULLET.sub("• ", out)
    blocks = []
    for paragraph in _paragraphs(out):
        blocks.extend(_split_long(paragraph))
    joined = "\n\n".join(blocks).strip()
    return re.sub(r"\x00(\d+)\x00", lambda m: links[int(m.group(1))], joined)


def transform(response_text=None, platform=None, **_):
    """``transform_llm_output``: only for plain-text channels; None leaves the reply alone."""
    if str(platform or "").lower() not in PLATFORMS or not isinstance(response_text, str):
        return None
    changed = plain(response_text)
    return changed if changed and changed != response_text else None
