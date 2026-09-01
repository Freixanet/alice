import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

async function waitForAlice(page: import("@playwright/test").Page) {
  await expect(page.locator(".alice-app")).toHaveAttribute("data-ready", "", {
    timeout: 15_000,
  });
}

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
  await waitForAlice(page);
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
  await waitForAlice(page);
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

test("keyboard users can skip directly to the main content", async ({
  page,
  browserName,
}) => {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await waitForAlice(page);

  await page.keyboard.press(browserName === "webkit" ? "Alt+Tab" : "Tab");
  const skipLink = page.getByRole("link", { name: "Skip to content" });
  await expect(skipLink).toBeFocused();
  await expect(skipLink).toBeVisible();

  await page.keyboard.press("Enter");
  await expect(page.getByRole("main")).toBeFocused();
});

test("the mobile sidebar isolates the background and restores focus", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await waitForAlice(page);

  const sidebar = page.locator("#alice-mobile-sidebar");
  const main = page.locator("#alice-main-content");
  const toggle = page.getByRole("button", { name: "Open sidebar" });
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(sidebar).toHaveAttribute("inert", "");
  await expect(sidebar).toHaveAttribute("aria-hidden", "true");

  await toggle.click();
  await expect(
    page.getByRole("button", { name: "Close sidebar" }),
  ).toHaveAttribute("aria-expanded", "true");
  await expect(sidebar).not.toHaveAttribute("inert", "");
  await expect(sidebar).toHaveAttribute("aria-hidden", "false");
  await expect(main).toHaveAttribute("inert", "");
  await expect(main).toHaveAttribute("aria-hidden", "true");
  await expect
    .poll(() =>
      sidebar.evaluate((element) => element.contains(document.activeElement)),
    )
    .toBe(true);

  await page.keyboard.press("Escape");
  await expect(toggle).toBeFocused();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(sidebar).toHaveAttribute("inert", "");
  await expect(main).not.toHaveAttribute("inert", "");
  await expect(main).not.toHaveAttribute("aria-hidden", "true");
});

test("mobile settings is modal, focus-trapped and accessible", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await waitForAlice(page);

  await page.getByRole("button", { name: "Open sidebar" }).click();
  await page.getByRole("button", { name: "Settings" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await expect(dialog).toHaveAttribute("aria-modal", "true");
  await expect
    .poll(() =>
      dialog.evaluate((element) => element.contains(document.activeElement)),
    )
    .toBe(true);

  for (let index = 0; index < 12; index += 1) {
    await page.keyboard.press("Tab");
    expect(
      await dialog.evaluate((element) =>
        element.contains(document.activeElement),
      ),
    ).toBe(true);
  }

  const results = await new AxeBuilder({ page })
    .include("[role=dialog]")
    .analyze();
  expect(
    results.violations.filter((item) =>
      ["critical", "serious"].includes(item.impact ?? ""),
    ),
  ).toEqual([]);

  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
});
