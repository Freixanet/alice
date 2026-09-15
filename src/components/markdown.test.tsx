// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import Markdown from "./markdown";

vi.mock("@/lib/use-i18n", () => ({
  useT: () => (key: string) => key,
}));

afterEach(cleanup);

function html(text: string): string {
  const { container } = render(<Markdown text={text} />);
  return container.innerHTML;
}

describe("assistant Markdown", () => {
  it("renders the structure a model actually emits", () => {
    const { container } = render(
      <Markdown
        text={[
          "## Heading",
          "",
          "**bold**, _italic_, ~~struck~~ and `inline`.",
          "",
          "- [x] done",
          "- [ ] todo",
          "",
          "| a | b |",
          "| --- | --- |",
          "| 1 | 2 |",
          "",
          "> quoted",
          "",
          "```ts",
          "const x = 1;",
          "```",
        ].join("\n")}
      />,
    );
    expect(container.querySelector("h2")).toHaveTextContent("Heading");
    expect(container.querySelector("strong")).toHaveTextContent("bold");
    expect(container.querySelector("em")).toHaveTextContent("italic");
    expect(container.querySelector("del")).toHaveTextContent("struck");
    expect(container.querySelector("table")).toBeInTheDocument();
    expect(container.querySelector("blockquote")).toHaveTextContent("quoted");
    expect(container.querySelectorAll('input[type="checkbox"]')).toHaveLength(
      2,
    );
    expect(container.querySelector("pre code")).toHaveTextContent(
      "const x = 1;",
    );
  });

  it("labels a fenced block with its language", () => {
    const { container } = render(<Markdown text={"```python\nx = 1\n```"} />);
    expect(container.querySelector(".alice-code-lang")).toHaveTextContent(
      "python",
    );
  });

  describe("untrusted content", () => {
    // Replies come from a model, which may be relaying text from a web page,
    // a file or a tool result. None of it may become live markup.
    it("escapes raw HTML instead of rendering it", () => {
      const { container } = render(
        <Markdown text={'<img src=x onerror="alert(1)"><b>hi</b>'} />,
      );
      expect(container.querySelector("img")).toBeNull();
      expect(container.querySelector("b")).toBeNull();
      expect(container.textContent).toContain("<b>hi</b>");
    });

    it("does not execute an inline script block", () => {
      const { container } = render(
        <Markdown text={"<script>window.__pwned = true</script>"} />,
      );
      expect(container.querySelector("script")).toBeNull();
      expect(
        (window as unknown as Record<string, unknown>).__pwned,
      ).toBeUndefined();
    });

    it("strips a javascript: link but keeps its text", () => {
      const { container } = render(
        <Markdown text={"[click](javascript:alert(1))"} />,
      );
      const link = container.querySelector("a");
      expect(link).toHaveTextContent("click");
      expect(link?.getAttribute("href") ?? "").not.toContain("javascript:");
    });

    it("refuses a data: URL that is not an image", () => {
      const { container } = render(
        <Markdown text={"[x](data:text/html;base64,PHNjcmlwdD4=)"} />,
      );
      expect(container.querySelector("a")?.getAttribute("href") ?? "").toBe("");
    });

    it("keeps inline images, which is how Hermes returns pictures", () => {
      const src =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
      const { container } = render(<Markdown text={`![alt](${src})`} />);
      expect(container.querySelector("img")).toHaveAttribute("src", src);
    });

    it("opens external links without handing over the opener", () => {
      render(<Markdown text={"[docs](https://example.com)"} />);
      const link = screen.getByRole("link", { name: "docs" });
      expect(link).toHaveAttribute("target", "_blank");
      expect(link.getAttribute("rel")).toContain("noopener");
      expect(link.getAttribute("rel")).toContain("noreferrer");
    });
  });

  it("renders a half-written fence while a reply is still streaming", () => {
    // Deltas arrive mid-token; an unclosed block must not throw.
    expect(() => html("```ts\nconst partial =")).not.toThrow();
    expect(html("| a | b |\n| --- |")).toContain("a");
  });
});

describe("what Alice's agents write", () => {
  it("draws a GitHub callout as a labelled card", () => {
    const { container } = render(
      <Markdown text={"> [!WARNING]\n> Mind the <u>deadline</u>."} />,
    );
    const quote = container.querySelector("blockquote");
    expect(quote).toHaveClass("alice-callout", "alice-callout-warning");
    expect(quote?.querySelector("p")).toHaveTextContent("Warning");
    expect(container.textContent).not.toContain("[!WARNING]");
    expect(container.textContent).not.toContain("<u>");
    expect(container.querySelectorAll("strong")[1]).toHaveTextContent(
      "deadline",
    );
  });

  it("leaves a plain quote and code alone", () => {
    const { container } = render(
      <Markdown
        text={"> just a quote\n\n```md\n> [!NOTE]\n<u>x</u>\n```\n\n`<u>y</u>`"}
      />,
    );
    expect(container.querySelector("blockquote")).not.toHaveClass(
      "alice-callout",
    );
    expect(container.querySelector("pre code")?.textContent).toContain(
      "> [!NOTE]\n<u>x</u>",
    );
    expect(container.textContent).toContain("<u>y</u>");
  });

  it("turns a reply link into a button that sends its text", () => {
    const heard: string[] = [];
    const listener = (event: Event) =>
      heard.push((event as CustomEvent<string>).detail);
    window.addEventListener("alice:quick-reply", listener);
    try {
      render(
        <Markdown
          text={
            "[Go ahead](alice://reply?text=Go%20ahead%2C%20please)\n[Wait](alice://reply)"
          }
        />,
      );
      expect(screen.queryByRole("link")).toBeNull();
      screen.getByRole("button", { name: "Go ahead" }).click();
      screen.getByRole("button", { name: "Wait" }).click();
      expect(heard).toEqual(["Go ahead, please", "Wait"]);
    } finally {
      window.removeEventListener("alice:quick-reply", listener);
    }
  });
});

describe("math", () => {
  // KaTeX is a lazy chunk. Under the full coverage suite the first dynamic
  // import can legitimately take longer than Testing Library's 1 s default,
  // especially on the self-hosted runner. The product has no 1 s deadline, so
  // give the test a bounded window that measures the actual contract instead
  // of scheduler/load noise.
  const mathReady = (container: HTMLElement, count = 1) =>
    waitFor(
      () =>
        expect(
          container.querySelectorAll(".katex").length,
        ).toBeGreaterThanOrEqual(count),
      { timeout: 5_000 },
    );

  it("renders inline and display formulas", async () => {
    const { container } = render(
      <Markdown text={"Given $E = mc^2$, then:\n\n$$\\int_0^1 x^2 dx$$"} />,
    );
    await mathReady(container, 2);
    expect(container.textContent).toContain("Given");
  });

  it("accepts the LaTeX delimiters models also emit", async () => {
    const { container } = render(
      <Markdown text={"area is \\(\\pi r^2\\) and \\[a^2 + b^2 = c^2\\]"} />,
    );
    await mathReady(container, 2);
  });

  it("leaves shell code alone even though it is full of dollars", () => {
    const { container } = render(
      <Markdown text={'```bash\necho "$HOME" && test $? -eq 0\n```'} />,
    );
    expect(container.querySelector(".katex")).toBeNull();
    expect(container.querySelector("pre code")?.textContent).toContain(
      '"$HOME"',
    );
  });

  it("shows a malformed formula as text rather than losing the reply", () => {
    const { container } = render(
      <Markdown text={"before $\\frac{1}{$ after"} />,
    );
    expect(container.textContent).toContain("before");
    expect(container.textContent).toContain("after");
  });

  it("refuses a formula command that reaches outside the equation", async () => {
    const { container } = render(
      <Markdown text={"$\\href{javascript:alert(1)}{click}$"} />,
    );
    await mathReady(container);
    expect(container.querySelector('a[href^="javascript:"]')).toBeNull();
  });
});
