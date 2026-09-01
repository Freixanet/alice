import { expect, test, type Page } from "@playwright/test";

type Preferences = {
  theme?: "light" | "dark";
  fontSize?: "sm" | "md" | "lg";
  accent?: "stone" | "sage" | "sky" | "violet" | "rose" | "amber";
  locale?: "en" | "es";
  sidebarCollapsed?: boolean;
};

const preferenceKey = "alice-cockpit-v1:preferences:dev-user";
const screenshotOptions = {
  animations: "disabled" as const,
  caret: "hide" as const,
  scale: "css" as const,
  maxDiffPixelRatio: 0.025,
  threshold: 0.2,
};

async function openStablePage(
  page: Page,
  path: string,
  viewport: { width: number; height: number },
  preferences: Preferences = {},
) {
  await page.setViewportSize(viewport);
  await page.addInitScript(
    ({ key, state }) => {
      localStorage.setItem(key, JSON.stringify({ state, version: 11 }));
    },
    { key: preferenceKey, state: preferences },
  );
  await page.goto(path, { waitUntil: "domcontentloaded" });
  await expect(page.locator(".alice-app")).toHaveAttribute("data-ready", "", {
    timeout: 15_000,
  });
  await page.evaluate(async () => {
    await document.fonts.ready;
    window.scrollTo(0, 0);
    for (const element of document.querySelectorAll<HTMLElement>("*")) {
      element.scrollTop = 0;
      element.scrollLeft = 0;
    }
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
    );
  });
}

test("empty chat remains visually stable at the compact breakpoint", async ({
  page,
}) => {
  await openStablePage(page, "/", { width: 320, height: 700 });
  await expect(page).toHaveScreenshot("chat-empty-320-light.png", {
    ...screenshotOptions,
  });
});

test("empty chat remains visually stable at the mobile breakpoint", async ({
  page,
}) => {
  await openStablePage(
    page,
    "/",
    { width: 390, height: 844 },
    { theme: "dark", fontSize: "lg", accent: "sage", locale: "es" },
  );
  await expect(page).toHaveScreenshot("chat-empty-390-dark-es-large.png", {
    ...screenshotOptions,
  });
});

test("empty chat remains visually stable on desktop", async ({ page }) => {
  await openStablePage(
    page,
    "/",
    { width: 1440, height: 900 },
    { sidebarCollapsed: false },
  );
  await expect(page).toHaveScreenshot("chat-empty-1440-light.png", {
    ...screenshotOptions,
  });
});

test("mobile Settings remains a complete full-screen surface", async ({
  page,
}) => {
  await openStablePage(page, "/settings", { width: 320, height: 700 });
  await expect(page.getByRole("dialog")).toHaveScreenshot(
    "settings-320-light.png",
    { ...screenshotOptions },
  );
});

for (const surface of ["skills", "connect", "memory"] as const) {
  test(`${surface} remains visually stable on mobile`, async ({ page }) => {
    await openStablePage(page, `/${surface}`, { width: 390, height: 844 });
    await expect(page).toHaveScreenshot(`${surface}-390-light.png`, {
      ...screenshotOptions,
    });
  });
}
