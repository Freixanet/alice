import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

test("Radar IA prepares an editable chat request with the selected schedule", async ({
  page,
}) => {
  await page.goto("/cron");
  await expect(page.locator(".alice-app")).toHaveAttribute("data-ready", "", {
    timeout: 15_000,
  });
  await expect(page.getByRole("heading", { name: "Radar IA" })).toBeVisible();
  await expect(page.getByLabel("Daily start time")).toHaveValue("10:00");
  await expect(page.getByLabel("Time zone", { exact: true })).toHaveValue(
    "Europe/Madrid",
  );
  await page.getByLabel("Daily start time").fill("11:45");
  await page.getByLabel("Time zone", { exact: true }).fill("Europe/Paris");
  const audit = await new AxeBuilder({ page }).analyze();
  expect(
    audit.violations.filter((v) =>
      ["critical", "serious"].includes(v.impact ?? ""),
    ),
  ).toEqual([]);
  await page.getByRole("button", { name: "Configure with Hermes" }).click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator("textarea")).toHaveValue(
    /11:45, zona horaria IANA Europe\/Paris/,
  );
});
