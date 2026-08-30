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
    await page.goto(route);
    await expect(page).toHaveTitle("Alice");
    await expect(page.locator("body")).not.toContainText("Un momento…", {
      timeout: 15_000,
    });
    await expect(page.locator("html")).toHaveAttribute("data-alice-app", "");

    const styles = await page.locator("body *").evaluateAll((elements) => ({
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
    }));

    expect(styles).toEqual({
      horizontalOverflow: false,
      shadows: 0,
      gradients: 0,
      backdrops: 0,
    });
  });
}

test("the empty chat is accessible", async ({ page }) => {
  await page.goto("/");
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
