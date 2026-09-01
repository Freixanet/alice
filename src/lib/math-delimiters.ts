/**
 * Normalise LaTeX delimiters so one math parser can handle every dialect a
 * model emits.
 *
 * `remark-math` understands `$…$` and `$$…$$`. Models also emit the LaTeX
 * forms `\(…\)` and `\[…\]` — which one you get depends on the model and on
 * how the prompt asked for it — so those are rewritten to the dollar forms
 * before parsing.
 *
 * The rewrite must not reach inside code. A shell snippet is full of `$`, and
 * a regex or a Windows path can contain `\(` or `\[`; turning those into math
 * would corrupt the block. So fenced blocks and inline spans are copied
 * through untouched, and an escaped `\\(` is left alone as well.
 */
export function normalizeMathDelimiters(text: string): string {
  if (!text.includes("\\(") && !text.includes("\\[")) return text;

  let out = "";
  let i = 0;
  const n = text.length;

  while (i < n) {
    const char = text[i]!;

    // Fenced block: copy verbatim to the closing fence, or to the end when the
    // reply is still streaming and the fence has not arrived yet.
    if ((char === "`" || char === "~") && isFenceStart(text, i)) {
      const fence = readFence(text, i);
      out += text.slice(i, fence.end);
      i = fence.end;
      continue;
    }

    // Inline span: a run of backticks closes on an equal run.
    if (char === "`") {
      const span = readInlineCode(text, i);
      out += text.slice(i, span.end);
      i = span.end;
      continue;
    }

    if (char === "\\") {
      const next = text[i + 1];
      if (next === "(" || next === ")") {
        out += "$";
        i += 2;
        continue;
      }
      if (next === "[" || next === "]") {
        out += "$$";
        i += 2;
        continue;
      }
      // Any other escape, `\\` included, passes through as a pair so the
      // second backslash is never read as the start of a delimiter.
      out += text.slice(i, i + 2);
      i += next === undefined ? 1 : 2;
      continue;
    }

    out += char;
    i += 1;
  }

  return out;
}

function isFenceStart(text: string, index: number): boolean {
  if (index > 0 && text[index - 1] !== "\n") return false;
  const char = text[index]!;
  return text.startsWith(char.repeat(3), index);
}

function readFence(text: string, index: number): { end: number } {
  const char = text[index]!;
  let run = 0;
  while (text[index + run] === char) run += 1;
  const marker = char.repeat(run);
  const bodyStart = text.indexOf("\n", index);
  if (bodyStart === -1) return { end: text.length };

  let cursor = bodyStart + 1;
  while (cursor < text.length) {
    const lineEnd = text.indexOf("\n", cursor);
    const line = text.slice(cursor, lineEnd === -1 ? text.length : lineEnd);
    if (line.trimStart().startsWith(marker)) {
      return { end: lineEnd === -1 ? text.length : lineEnd + 1 };
    }
    if (lineEnd === -1) break;
    cursor = lineEnd + 1;
  }
  return { end: text.length };
}

function readInlineCode(text: string, index: number): { end: number } {
  let run = 0;
  while (text[index + run] === "`") run += 1;
  const marker = "`".repeat(run);
  const close = text.indexOf(marker, index + run);
  // Unclosed span: treat the backticks as ordinary text so a streaming reply
  // does not swallow the rest of the message.
  if (close === -1) return { end: index + run };
  return { end: close + run };
}
