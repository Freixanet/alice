import { describe, expect, it } from "vitest";
import { normalizeMathDelimiters } from "./math-delimiters";

describe("math delimiters", () => {
  it("rewrites the LaTeX forms to the dollar forms", () => {
    expect(normalizeMathDelimiters("cost is \\(x^2\\) per unit")).toBe(
      "cost is $x^2$ per unit",
    );
    expect(normalizeMathDelimiters("\\[E = mc^2\\]")).toBe("$$E = mc^2$$");
  });

  it("leaves text that already uses dollars alone", () => {
    const text = "inline $x^2$ and block $$y = 1$$";
    expect(normalizeMathDelimiters(text)).toBe(text);
  });

  it("never touches a fenced block", () => {
    // A shell fence is full of `$`, and a regex fence of `\(`.
    const text = [
      "before \\(a\\)",
      "```bash",
      'grep -E "\\\\(foo\\\\)" "$FILE" && echo "$?"',
      "```",
      "after \\(b\\)",
    ].join("\n");
    const out = normalizeMathDelimiters(text);
    expect(out).toContain('grep -E "\\\\(foo\\\\)" "$FILE"');
    expect(out).toContain("before $a$");
    expect(out).toContain("after $b$");
  });

  it("never touches an inline code span", () => {
    const out = normalizeMathDelimiters(
      "use `\\(x\\)` literally, but \\(y\\) is math",
    );
    expect(out).toContain("`\\(x\\)`");
    expect(out).toContain("but $y$ is math");
  });

  it("handles a tilde fence too", () => {
    const text = '~~~python\nre.match(r"\\\\(", s)\n~~~';
    expect(normalizeMathDelimiters(text)).toBe(text);
  });

  it("leaves an escaped backslash as an escape, not a delimiter", () => {
    expect(normalizeMathDelimiters("a \\\\(b) c")).toBe("a \\\\(b) c");
  });

  it("survives a fence that has not finished streaming", () => {
    const partial = "text \\(x\\)\n```ts\nconst a = 1;";
    const out = normalizeMathDelimiters(partial);
    expect(out).toContain("text $x$");
    expect(out).toContain("const a = 1;");
  });

  it("survives an unclosed inline span mid-stream", () => {
    expect(() => normalizeMathDelimiters("half `code")).not.toThrow();
    expect(normalizeMathDelimiters("half `code \\(x\\)")).toContain("$x$");
  });

  it("returns the input untouched when there is nothing to rewrite", () => {
    const text = "plain reply with no math at all";
    expect(normalizeMathDelimiters(text)).toBe(text);
  });
});
