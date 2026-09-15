import {
  isValidElement,
  memo,
  useEffect,
  useState,
  type ComponentProps,
  type ReactNode,
} from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { Check, Copy } from "lucide-react";
import { useT } from "@/lib/use-i18n";
import { normalizeMathDelimiters } from "@/lib/math-delimiters";
import {
  QUICK_REPLY_EVENT,
  calloutKind,
  hastText,
  isQuickReply,
  prepareMessageMarkup,
  quickReplyText,
} from "@/lib/message-markup";

/**
 * Renders assistant text as Markdown.
 *
 * The content comes from a model, so it is untrusted: raw HTML is never
 * enabled (no `rehype-raw`), which means any markup in the reply is escaped
 * rather than executed. `urlTransform` then decides what a link or image may
 * point at — `javascript:` and friends are dropped, and inline images are
 * allowed only as `data:image/...`, which is how Hermes returns generated
 * pictures.
 *
 * This module is loaded on demand. The parser and highlighter together are
 * larger than the whole initial bundle budget, and a reply reads fine as plain
 * text for the moment it takes to arrive.
 */

const SAFE_PROTOCOL = /^(https?:|mailto:|tel:)/i;
const SAFE_INLINE_IMAGE =
  /^data:image\/(png|jpe?g|gif|webp|bmp|svg\+xml);base64,/i;

function safeUrl(url: string, key: string): string {
  const value = url.trim();
  if (key === "src" && SAFE_INLINE_IMAGE.test(value)) return value;
  if (SAFE_PROTOCOL.test(value)) return value;
  // A reply button; it is drawn as a button and never navigated to.
  if (key === "href" && isQuickReply(value)) return value;
  if (value.startsWith("/") || value.startsWith("#")) return value;
  return "";
}

/**
 * `rehype-highlight` tags the inner `<code>` with `language-x`, either from the
 * fence or from its own detection. Surfacing it labels the block the way every
 * other chat surface does, and quietly says nothing when there is no guess.
 */
function fenceLanguage(children: ReactNode): string | null {
  if (!isValidElement<{ className?: string }>(children)) return null;
  const match = /language-([\w+#-]+)/.exec(children.props.className ?? "");
  const name = match?.[1];
  if (!name || name === "plaintext" || name === "undefined") return null;
  return name;
}

function CodeBlock({ children }: { children: ReactNode }) {
  const t = useT();
  const language = fenceLanguage(children);
  const [copied, setCopied] = useState(false);
  // `children` is the <code> element rehype-highlight produced; read the text
  // off the DOM node on click rather than trying to walk the React tree.
  const [node, setNode] = useState<HTMLPreElement | null>(null);

  async function copy() {
    const text = node?.querySelector("code")?.textContent ?? "";
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard blocked; leave the button untouched rather than lying.
    }
  }

  return (
    <div className="alice-code group relative my-3">
      {language ? (
        <span className="alice-code-lang" aria-hidden>
          {language}
        </span>
      ) : null}
      <button
        type="button"
        onClick={() => void copy()}
        aria-label={copied ? t("chat.copied") : t("chat.copy")}
        title={copied ? t("chat.copied") : t("chat.copy")}
        className="absolute top-2 right-2 grid size-8 place-items-center rounded-md text-muted-foreground opacity-0 hover:bg-accent hover:text-foreground focus-visible:opacity-100 group-hover:opacity-100"
      >
        {copied ? (
          <Check className="size-3.5" />
        ) : (
          <Copy className="size-3.5" />
        )}
      </button>
      <pre ref={setNode}>{children}</pre>
    </div>
  );
}

const components: Components = {
  a: ({ children, href, node }) => {
    if (isQuickReply(href)) {
      const text = quickReplyText(href, hastText(node));
      // The chat on screen sends it, as if typed (`QUICK_REPLY_EVENT`).
      return (
        <button
          type="button"
          className="alice-quick-reply"
          onClick={() =>
            window.dispatchEvent(
              new CustomEvent(QUICK_REPLY_EVENT, { detail: text }),
            )
          }
        >
          {children}
        </button>
      );
    }
    return (
      <a href={href} target="_blank" rel="noopener noreferrer nofollow">
        {children}
      </a>
    );
  },
  blockquote: ({ children, node }) => {
    const kind = calloutKind(node);
    return (
      <blockquote
        className={kind ? `alice-callout alice-callout-${kind}` : undefined}
      >
        {children}
      </blockquote>
    );
  },
  img: ({ src, alt }) => <img src={src} alt={alt || ""} loading="lazy" />,
  pre: ({ children }) => <CodeBlock>{children}</CodeBlock>,
  table: ({ children }) => (
    // Wide tables scroll inside the bubble instead of widening the page.
    <div className="alice-table-scroll">
      <table>{children}</table>
    </div>
  ),
};

// Derived from the renderer's own props rather than importing `unified`,
// which is only a transitive dependency here.
type MarkdownProps = ComponentProps<typeof ReactMarkdown>;
type MathPlugins = {
  remark: NonNullable<MarkdownProps["remarkPlugins"]>;
  rehype: NonNullable<MarkdownProps["rehypePlugins"]>;
};

/**
 * Loads the maths layer the first time a reply looks like it contains a
 * formula, and keeps it for the rest of the session. A `$` inside a shell
 * fence is a false positive that costs one fetch and changes nothing on
 * screen, which is the right way to be wrong here.
 */
function useMathPlugins(source: string): MathPlugins | null {
  const [plugins, setPlugins] = useState<MathPlugins | null>(loadedMath);
  const wanted = !plugins && source.includes("$");

  useEffect(() => {
    if (!wanted) return;
    let live = true;
    void import("./markdown-math")
      .then((module) => {
        loadedMath = {
          remark: module.remarkMathPlugins,
          rehype: module.rehypeMathPlugins,
        };
        if (live) setPlugins(loadedMath);
      })
      .catch(() => {
        // Formulas stay as text; the rest of the reply is unaffected.
      });
    return () => {
      live = false;
    };
  }, [wanted]);

  return plugins;
}

let loadedMath: MathPlugins | null = null;

function MarkdownBody({ text }: { text: string }) {
  const source = normalizeMathDelimiters(prepareMessageMarkup(text));
  const math = useMathPlugins(source);
  return (
    <div className="alice-markdown">
      <ReactMarkdown
        remarkPlugins={[remarkGfm, ...(math?.remark ?? [])]}
        rehypePlugins={[
          [rehypeHighlight, { detect: true, ignoreMissing: true }],
          ...(math?.rehype ?? []),
        ]}
        urlTransform={safeUrl}
        components={components}
      >
        {source}
      </ReactMarkdown>
    </div>
  );
}

/**
 * Replies stream in a token at a time, so this re-renders on every delta.
 * Skipping the work when the text has not changed keeps a long conversation
 * from re-parsing every message on each frame.
 */
export default memo(MarkdownBody, (prev, next) => prev.text === next.text);
