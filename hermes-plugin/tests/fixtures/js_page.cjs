// A page for the shop engine's tests: jsdom, driven line by line over stdin/stdout.
// Every request the page makes (navigation or fetch) is answered by the Python fixture shop,
// so the same shop serves these tests and the real-Chrome script.
"use strict";
const path = require("path");
const readline = require("readline");
const roots = [
  process.cwd(),
  path.resolve(__dirname, "../../.."),
  ...(process.env.NODE_PATH || "").split(path.delimiter),
].filter(Boolean);
const { JSDOM, VirtualConsole } = require(
  require.resolve("jsdom", { paths: roots }),
);

const rl = readline.createInterface({ input: process.stdin });
const commands = [];
const pending = new Map();
let nextId = 0;
let inflight = 0;
rl.on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.op === "response") {
    const done = pending.get(msg.id);
    pending.delete(msg.id);
    if (done) done(msg);
    return;
  }
  const next = commands.shift();
  if (next) next(msg);
});
const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const ask = (msg) =>
  new Promise((resolve) => {
    const id = ++nextId;
    pending.set(id, resolve);
    inflight++;
    send({ ...msg, id });
  }).finally(() => {
    inflight--;
  });
const quiet = async () => {
  for (let i = 0; i < 400; i++) {
    await new Promise((r) => setTimeout(r, 5));
    if (!inflight) break;
  }
};

let dom = null;
function layout(window) {
  // jsdom has no layout: an element is "on screen" unless it or an ancestor is hidden.
  const hidden = (e) => {
    for (let n = e; n && n.nodeType === 1; n = n.parentElement) {
      if (
        n.hidden ||
        n.getAttribute("aria-hidden") === "true" ||
        /display:\s*none/.test(n.getAttribute("style") || "")
      )
        return true;
    }
    return false;
  };
  window.Element.prototype.getClientRects = function () {
    return hidden(this) ? [] : [{ top: 0, left: 0, width: 10, height: 10 }];
  };
  // As a browser: the rendered text, without scripts, styles or hidden parts.
  const rendered = (node) => {
    if (node.nodeType === 3) return node.nodeValue;
    if (
      node.nodeType !== 1 ||
      /^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT)$/.test(node.tagName) ||
      hidden(node)
    )
      return "";
    let out = "";
    for (const child of node.childNodes) out += rendered(child);
    return /^(P|DIV|LI|TR|H[1-6]|SECTION|ARTICLE|HEADER|FOOTER|UL|OL|TABLE|FORM|BR|DL|DT|DD)$/.test(
      node.tagName,
    )
      ? "\n" + out + "\n"
      : out;
  };
  Object.defineProperty(window.HTMLElement.prototype, "innerText", {
    get() {
      return hidden(this)
        ? ""
        : rendered(this)
            .replace(/\n{2,}/g, "\n")
            .trim();
    },
    set(v) {
      this.textContent = v;
    },
  });
  window.fetch = async (url, init = {}) => {
    const target = new window.URL(url, window.location.href).href;
    const res = await ask({
      op: "request",
      method: (init.method || "GET").toUpperCase(),
      url: target,
      body: init.body || "",
    });
    const headers = new Map(
      Object.entries(res.headers || {}).map(([k, v]) => [k.toLowerCase(), v]),
    );
    return {
      ok: res.status >= 200 && res.status < 300,
      status: res.status,
      headers: { get: (k) => headers.get(k.toLowerCase()) || null },
      text: async () => res.body,
      json: async () => JSON.parse(res.body),
    };
  };
  window.HTMLFormElement.prototype.requestSubmit = function () {
    this.dispatchEvent(
      new window.Event("submit", { cancelable: true, bubbles: true }),
    );
  };
}
async function load(url) {
  const res = await ask({ op: "request", method: "GET", url, body: "" });
  const finalUrl = res.url || url;
  dom = new JSDOM(res.body, {
    url: finalUrl,
    runScripts: "dangerously",
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
    beforeParse: layout,
  });
  await quiet();
  return { ok: res.status < 400, url: finalUrl };
}
(async () => {
  for (;;) {
    const cmd = await new Promise((resolve) => commands.push(resolve));
    try {
      if (cmd.op === "load") {
        send({ op: "done", value: await load(cmd.url) });
        continue;
      }
      if (cmd.op === "eval") {
        let value = dom.window.eval(cmd.js);
        if (value && typeof value.then === "function") value = await value;
        await quiet();
        send({
          op: "done",
          value: value === undefined ? null : JSON.parse(JSON.stringify(value)),
        });
        continue;
      }
      if (cmd.op === "quit") process.exit(0);
    } catch (e) {
      send({ op: "done", error: String((e && e.stack) || e) });
    }
  }
})();
