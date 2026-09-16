/**
 * What Alice's agents write beyond plain Markdown, made renderable.
 *
 * Their style guide (hermes-agents/forja/skill/forja-crear-agentes/references/
 * estilo-mensajes.md) asks for GitHub callouts (`> [!WARNING]`), `<u>` for a
 * critical warning, and reply buttons as `[Title](alice://reply?text=…)`. The
 * iOS app draws those natively; here the reply stays untrusted Markdown with
 * raw HTML escaped, so the callout marker becomes a bold label the blockquote
 * recognises, `<u>` becomes bold, and a reply link becomes a button.
 *
 * Code is never touched: fenced blocks and inline spans pass through verbatim.
 */

type CalloutKind = "note" | "tip" | "important" | "warning" | "caution";

const CALLOUT_LABELS: Record<CalloutKind, string> = {
  note: "Note",
  tip: "Tip",
  important: "Important",
  warning: "Warning",
  caution: "Caution",
};

export const QUICK_REPLY_EVENT = "alice:quick-reply";

const CALLOUT = /^(\s*>\s?)\[!(note|tip|important|warning|caution)\][ \t]*(.*)$/i;
const UNKNOWN_CALLOUT = /^(\s*>\s?)\[!([a-z][a-z0-9_-]*)\][ \t]*(.*)$/i;
const QUOTE_LINE = /^(\s*>\s?)(.*)$/;
const FENCE = /^\s*(`{3,}|~{3,})/;
const QUICK_REPLY = /^alice:\/\/reply(?:[?#]|$)/i;

export function prepareMessageMarkup(text: string): string {
  if (!text.includes("[!") && !text.includes("<u>")) return text;
  let fence: string | null = null;
  let unwrapUnknown = false;
  return text
    .split("\n")
    .map((line) => {
      if (fence) {
        if (line.trimStart().startsWith(fence)) fence = null;
        unwrapUnknown = false;
        return line;
      }
      const open = FENCE.exec(line);
      if (open) {
        fence = open[1]!;
        unwrapUnknown = false;
        return line;
      }
      const callout = CALLOUT.exec(line);
      if (callout) {
        unwrapUnknown = false;
        const [, prefix = "> ", kind = "note", rest = ""] = callout;
        const label = `${prefix}**${CALLOUT_LABELS[kind.toLowerCase() as CalloutKind]}**`;
        // The label is a paragraph of its own, so the blockquote can find it.
        const gap = prefix.trimEnd();
        return rest
          ? `${label}\n${gap}\n${prefix}${underline(rest)}`
          : `${label}\n${gap}`;
      }
      const unknown = UNKNOWN_CALLOUT.exec(line);
      if (unknown) {
        unwrapUnknown = true;
        const rest = unknown[3] ?? "";
        return rest ? underline(rest) : "";
      }
      if (unwrapUnknown) {
        const quoted = QUOTE_LINE.exec(line);
        if (quoted) return underline(quoted[2] ?? "");
        unwrapUnknown = false;
      }
      return underline(line);
    })
    .join("\n");
}

function underline(line: string): string {
  if (!line.includes("<u>")) return line;
  // Odd parts are inline code spans, captured by the split.
  return line
    .split(/(`+[^`]*`+)/)
    .map((part, index) =>
      index % 2 ? part : part.replace(/<u>(.+?)<\/u>/g, "**$1**"),
    )
    .join("");
}

type HastNode = {
  type: string;
  tagName?: string;
  value?: string;
  children?: HastNode[];
};

/** The callout a rendered blockquote is, from the label paragraph it opens with. */
export function calloutKind(node: HastNode | undefined): CalloutKind | null {
  const first = node?.children?.find((child) => child.type === "element");
  if (first?.tagName !== "p") return null;
  const parts = (first.children ?? []).filter(
    (child) => !(child.type === "text" && !child.value?.trim()),
  );
  if (parts.length !== 1 || parts[0]?.tagName !== "strong") return null;
  const label = hastText(parts[0]);
  const kinds = Object.keys(CALLOUT_LABELS) as CalloutKind[];
  return kinds.find((kind) => CALLOUT_LABELS[kind] === label) ?? null;
}

export function hastText(node: HastNode | undefined): string {
  if (!node) return "";
  if (node.type === "text") return node.value ?? "";
  return (node.children ?? []).map(hastText).join("");
}

export function isQuickReply(href: string | undefined): href is string {
  return !!href && QUICK_REPLY.test(href.trim());
}

/** The text a reply button sends: its `text` parameter, else its title. */
export function quickReplyText(href: string, title: string): string {
  let text: string | null = null;
  try {
    text = new URL(href.trim()).searchParams.get("text");
  } catch {
    // A malformed link still has a title worth sending.
  }
  return (text ?? "").trim() || title.trim();
}
