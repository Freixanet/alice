import { expect, test } from "@playwright/test";

test.describe.configure({ mode: "serial" });

async function waitForAlice(page: import("@playwright/test").Page) {
  await expect(page.locator(".alice-app")).toHaveAttribute("data-ready", "", {
    timeout: 15_000,
  });
}

test("normal API handler p95 stays below 100 ms", async ({
  request,
}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium");

  for (let warmup = 0; warmup < 3; warmup += 1) {
    await request.get("/api/phone");
  }

  const durations: number[] = [];
  for (let sample = 0; sample < 30; sample += 1) {
    const response = await request.get("/api/phone");
    expect(response.ok()).toBe(true);
    const timing = response.headers()["server-timing"] ?? "";
    const duration = Number(/alice;dur=([\d.]+)/.exec(timing)?.[1]);
    expect(Number.isFinite(duration), timing).toBe(true);
    durations.push(duration);
  }

  durations.sort((left, right) => left - right);
  const p95 = durations[Math.ceil(durations.length * 0.95) - 1] ?? Infinity;
  expect(p95, `Alice handler p95: ${p95} ms`).toBeLessThan(100);
});

test("telemetry ingestion accepts only the anonymous contract", async ({
  request,
}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium");
  const safe = {
    kind: "client_error",
    route: "/skills",
    browser: "safari",
    viewport: "narrow",
    code: "runtime_error",
  };
  const accepted = await request.post("/api/telemetry", { data: safe });
  expect(accepted.status()).toBe(204);
  expect(accepted.headers()["server-timing"]).toMatch(/^alice;dur=[\d.]+$/);

  const rejected = await request.post("/api/telemetry", {
    data: { ...safe, message: "private error detail" },
  });
  expect(rejected.status()).toBe(400);
  await expect(rejected.json()).resolves.toEqual({
    ok: false,
    error: { code: "invalid_request" },
  });
});

test("a 500-message conversation keeps a bounded DOM while remaining scrollable", async ({
  page,
}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium");
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await waitForAlice(page);
  await page.evaluate(async () => {
    const messages = Array.from({ length: 500 }, (_, index) => ({
      id: `message-${index}`,
      role: index % 2 === 0 ? "user" : "assistant",
      content: `Virtualized message ${index}`,
      createdAt: index,
    }));
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("alice-private-v1", 1);
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains("account-state")) {
          request.result.createObjectStore("account-state");
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction("account-state", "readwrite");
      transaction.objectStore("account-state").put(
        {
          state: {
            activeId: "long-conversation",
            conversations: [
              {
                id: "long-conversation",
                title: "Long conversation",
                createdAt: 0,
                updatedAt: 500,
                messages,
              },
            ],
          },
          version: 11,
        },
        "alice-cockpit-v1:dev-user",
      );
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });
    db.close();
  });
  await page.reload({ waitUntil: "domcontentloaded" });
  await waitForAlice(page);
  await expect(page.locator('[data-message-id="message-499"]')).toBeVisible();
  await expect
    .poll(() => page.locator("[data-message-id]").count())
    .toBeLessThan(30);

  await page.locator(".alice-chat-scroller").evaluate((element) => {
    element.scrollTop = 0;
    element.dispatchEvent(new Event("scroll", { bubbles: true }));
  });
  await expect(page.locator('[data-message-id="message-0"]')).toBeVisible();
  await expect
    .poll(() => page.locator("[data-message-id]").count())
    .toBeLessThan(30);
});

test("LCP, INP and CLS stay inside the mobile budgets", async ({
  page,
}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.addInitScript(() => {
    const values = { lcp: 0, inp: 0, cls: 0, interactions: 0 };
    Object.defineProperty(window, "__aliceVitals", { value: values });
    if (
      PerformanceObserver.supportedEntryTypes.includes(
        "largest-contentful-paint",
      )
    ) {
      new PerformanceObserver((list) => {
        const last = list.getEntries().at(-1);
        if (last) values.lcp = last.startTime;
      }).observe({ type: "largest-contentful-paint", buffered: true });
    }
    if (PerformanceObserver.supportedEntryTypes.includes("layout-shift")) {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as Array<
          PerformanceEntry & { value: number; hadRecentInput: boolean }
        >) {
          if (!entry.hadRecentInput) values.cls += entry.value;
        }
      }).observe({ type: "layout-shift", buffered: true });
    }
    if (PerformanceObserver.supportedEntryTypes.includes("event")) {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as Array<
          PerformanceEntry & { duration: number; interactionId: number }
        >) {
          if (entry.interactionId <= 0) continue;
          values.interactions += 1;
          values.inp = Math.max(values.inp, entry.duration);
        }
      }).observe({
        type: "event",
        buffered: true,
        durationThreshold: 16,
      } as PerformanceObserverInit);
    }
  });
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await waitForAlice(page);
  await page.locator(".alice-composer textarea").click();
  await page.keyboard.type("Alice");
  await page.waitForTimeout(500);
  const vitals = await page.evaluate(
    () =>
      (
        window as unknown as {
          __aliceVitals: {
            lcp: number;
            inp: number;
            cls: number;
            interactions: number;
          };
        }
      ).__aliceVitals,
  );
  expect(vitals.lcp, `LCP: ${vitals.lcp} ms`).toBeGreaterThan(0);
  expect(vitals.lcp, `LCP: ${vitals.lcp} ms`).toBeLessThan(2_500);
  expect(vitals.interactions).toBeGreaterThan(0);
  expect(vitals.inp, `INP: ${vitals.inp} ms`).toBeLessThan(200);
  expect(vitals.cls, `CLS: ${vitals.cls}`).toBeLessThan(0.1);
});
