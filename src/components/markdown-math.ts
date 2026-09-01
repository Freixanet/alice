import type { ComponentProps } from "react";
import type ReactMarkdown from "react-markdown";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";

/**
 * KaTeX and its stylesheet are about as heavy as the Markdown parser and the
 * syntax highlighter combined, and most replies contain no formula at all.
 * Keeping them in a module of their own means a conversation that never asks
 * for maths never pays for them.
 */
// Typed from the renderer's own props; `unified` is only transitive here.
type Props = ComponentProps<typeof ReactMarkdown>;

export const remarkMathPlugins: NonNullable<Props["remarkPlugins"]> = [
  remarkMath,
];

export const rehypeMathPlugins: NonNullable<Props["rehypePlugins"]> = [
  [
    rehypeKatex,
    {
      // The formula comes from a model: `trust: false` refuses the commands
      // that reach outside the equation (`\href`, `\includegraphics`), and not
      // throwing means a half-typed formula mid-stream shows as text rather
      // than blanking the reply.
      trust: false,
      throwOnError: false,
      strict: false,
      errorColor: "var(--muted-foreground)",
    },
  ],
];
