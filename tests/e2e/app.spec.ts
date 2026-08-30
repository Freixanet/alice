import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

const routes = [
  "/",
  "/skills",
  "/tools",
  "/addons",
  "/projects",
  "/memory",
  "/cron",
  "/connect",
];

for (const route of routes) {
  test(`${route} preserves the Alice visual invariants`, async ({ page }) => {
    await page.goto(route, { waitUntil: "domcontentloaded" });
    await expect(page).toHaveTitle("Alice");
    await expect(page.locator("body")).not.toContainText("Un momento…", {
      timeout: 15_000,
    });
    await expect(page.locator("html")).toHaveAttribute("data-alice-app", "");

    await expect
      .poll(
        () =>
          page.locator("body *").evaluateAll((elements) => ({
            horizontalOverflow:
              document.documentElement.scrollWidth > window.innerWidth,
            shadows: elements.filter(
              (element) => getComputedStyle(element).boxShadow !== "none",
            ).length,
            gradients: elements.filter(
              (element) => getComputedStyle(element).backgroundImage !== "none",
            ).length,
            backdrops: elements.filter(
              (element) => getComputedStyle(element).backdropFilter !== "none",
            ).length,
          })),
        { timeout: 15_000 },
      )
      .toEqual({
        horizontalOverflow: false,
        shadows: 0,
        gradients: 0,
        backdrops: 0,
      });
  });
}

test("the empty chat is accessible", async ({ page }) => {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect(
    page.getByRole("heading", { name: "What are we working on?" }),
  ).toBeVisible();
  const results = await new AxeBuilder({ page }).analyze();
  expect(
    results.violations.filter((item) =>
      ["critical", "serious"].includes(item.impact ?? ""),
    ),
  ).toEqual([]);
});

test("mobile interactive targets are at least 44px", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect(page.locator("html")).toHaveAttribute("data-alice-app", "");
  const violations = await page
    .locator(
      'button, [role="button"], [role="menuitem"], a[href], input, select',
    )
    .evaluateAll((elements) =>
      elements.flatMap((element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        if (
          rect.width === 0 ||
          rect.height === 0 ||
          style.visibility === "hidden" ||
          style.display === "none"
        ) {
          return [];
        }
        return rect.width >= 44 && rect.height >= 44
          ? []
          : [
              {
                tag: element.tagName,
                label:
                  element.getAttribute("aria-label") ?? element.textContent,
                width: rect.width,
                height: rect.height,
              },
            ];
      }),
    );
  expect(violations).toEqual([]);
});
