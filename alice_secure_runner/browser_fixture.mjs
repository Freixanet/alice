// Synthetic Alice-owned browser engine. NOT an OS sandbox or a hosted service.
// Invoked over private inherited stdin/stdout by the Alice Python runner only;
// Hermes must never receive the process, its handles, or any credential.
import readline from "node:readline";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const playwright = require(process.env.ALICE_TEST_PLAYWRIGHT_MODULE);
const origin = new URL(process.env.ALICE_FIXTURE_ORIGIN).origin;
if (!/^https:\/\/localhost:\d+$/.test(origin))
  throw Error("fixture loopback TLS only");
const browser = await playwright.chromium.launch({
  headless: true,
  ...(process.env.ALICE_TEST_CHROME_PATH
    ? { executablePath: process.env.ALICE_TEST_CHROME_PATH }
    : {}),
  args: ["--no-first-run", "--disable-extensions"],
});
const contexts = new Map();
let blockedRequests = 0;
let blockedCheckoutPosts = 0;

async function getPage(id) {
  if (typeof id !== "string" || !/^[a-zA-Z0-9_-]{10,64}$/.test(id))
    throw Error("invalid session");
  if (!contexts.has(id)) {
    // New private browser context per runner job. Does not use system Chrome
    // profile, shared Hermes CDP, persistent cookies or remote debug ports.
    const context = await browser.newContext({
      ignoreHTTPSErrors: true, // TEST CERT ONLY. Not a real TLS security claim.
      serviceWorkers: "block",
      extraHTTPHeaders: {
        Authorization: `Bearer ${process.env.ALICE_FIXTURE_BROWSER_READ_TOKEN}`,
      },
    });
    await context.addCookies([
      {
        name: "fixture_partition",
        value: id,
        url: origin,
        httpOnly: true,
        secure: true,
      },
    ]);
    await context.route("**/*", async (route) => {
      const request = route.request();
      const parsed = new URL(request.url());
      const allowed =
        parsed.origin === origin &&
        request.method() === "GET" &&
        request.resourceType() === "document" &&
        (parsed.pathname === "/browse/search" ||
          parsed.pathname === "/browse/product/FAKE-ALICE-1");
      if (!allowed) {
        blockedRequests += 1;
        if (request.method() === "POST" && parsed.pathname === "/commit")
          blockedCheckoutPosts += 1;
        await route.abort("blockedbyclient");
        return;
      }
      await route.continue();
    });
    if (typeof context.routeWebSocket === "function") {
      await context.routeWebSocket("**/*", (socket) => socket.close());
    }
    contexts.set(id, { context, page: await context.newPage() });
  }
  return contexts.get(id).page;
}

async function dispatch(command) {
  if (!command || typeof command !== "object") throw Error("invalid command");
  if (command.op === "close") {
    if (contexts.has(command.session)) {
      await contexts.get(command.session).context.close();
      contexts.delete(command.session);
    }
    return { closed: true, session: command.session };
  }
  if (command.op === "stats") {
    return {
      sessions: contexts.size,
      blocked_requests: blockedRequests,
      blocked_checkout_posts: blockedCheckoutPosts,
    };
  }
  if (!["search", "read_product"].includes(command.op))
    throw Error("forbidden browser operation");
  const page = await getPage(command.session);
  if (command.op === "search") {
    if (
      typeof command.query !== "string" ||
      command.query.length > 100 ||
      !command.query.length
    )
      throw Error("invalid search");
    await page.goto(
      `${origin}/browse/search?q=${encodeURIComponent(command.query)}`,
      { waitUntil: "domcontentloaded", timeout: 10000 },
    );
    const items = await page
      .locator("#results li[data-sku]")
      .evaluateAll((nodes) =>
        nodes
          .slice(0, 10)
          .map((el) => ({ sku: el.dataset.sku, name: el.dataset.name })),
      );
    return { products: items };
  }
  if (command.sku !== "FAKE-ALICE-1")
    throw Error("product outside allowed fixture");
  await page.goto(
    `${origin}/browse/product/${encodeURIComponent(command.sku)}`,
    { waitUntil: "domcontentloaded", timeout: 10000 },
  );
  const product = await page.locator("#product").evaluate((el) => ({
    sku: el.dataset.sku,
    name: el.querySelector("h1")?.textContent,
    description: el.querySelector("p")?.textContent,
    unit_minor: Number(el.dataset.unitMinor),
    currency: el.dataset.currency,
  }));
  // Wait for the hostile page's rejected POST so tests observe the effect.
  await page.waitForTimeout(50);
  return product;
}

function emit(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}
emit({ ready: true });
let pending = Promise.resolve();
for await (const line of readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
})) {
  pending = pending.then(async () => {
    let request;
    try {
      request = JSON.parse(line);
      if (!Number.isSafeInteger(request.id) || request.id < 1)
        throw Error("invalid command id");
      emit({ id: request.id, op: request.op, ok: await dispatch(request) });
    } catch (e) {
      emit({
        id: request?.id || null,
        op: request?.op || null,
        error: String(e.message).slice(0, 120),
      });
    }
  });
  await pending;
}
for (const { context } of contexts.values()) await context.close();
await browser.close();
