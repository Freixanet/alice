import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { AppErrorComponent } from "./error-component";

vi.mock("@/lib/use-i18n", () => ({
  useLocale: () => "en",
  useT: () => (key: string) => key,
}));

describe("route errors from TanStack Router", () => {
  it.each([
    new Error("Synthetic route failure"),
    { message: "Synthetic route failure" },
  ])("preserves messages from Error and serialized errors", (error) => {
    const html = renderToStaticMarkup(
      <AppErrorComponent reset={() => undefined} error={error} />,
    );
    expect(html).toContain("Synthetic route failure");
    expect(html).not.toContain("error.pageHint");
  });

  it.each([null, undefined, "failure", {}, { message: 42 }, { message: "" }])(
    "renders the existing fallback for unknown errors: %j",
    (error) => {
      const html = renderToStaticMarkup(
        <AppErrorComponent reset={() => undefined} error={error} />,
      );
      expect(html).toContain("error.pageHint");
      expect(html).toContain("error.pageTitle");
    },
  );

  it("renders an error message as text rather than HTML", () => {
    const html = renderToStaticMarkup(
      <AppErrorComponent
        reset={() => undefined}
        error={{ message: '<script>alert("fixture")</script>' }}
      />,
    );
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });
});
