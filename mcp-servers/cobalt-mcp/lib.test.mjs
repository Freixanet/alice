import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import {
  describeCobaltError,
  encodeForLink,
  extensionFor,
  mediaMarkdown,
  safeFileName,
  savedReport,
  uniquePath,
} from "./lib.mjs";

test("safeFileName keeps a readable name and strips what a filesystem or a label rejects", () => {
  assert.equal(safeFileName("Pole - una moto.mp4"), "Pole - una moto.mp4");
  assert.equal(safeFileName('a/b\\c:d*e?f"g<h>i|j[k]l.mp4'), "a_b_c_d_e_f_g_h_i_j_k_l.mp4");
  assert.equal(safeFileName("  ..hidden.mp3 "), "hidden.mp3");
  assert.equal(safeFileName("line\nbreak.mp4"), "line break.mp4");
  assert.equal(safeFileName("", "fallback"), "fallback");
  assert.equal(safeFileName("x".repeat(400) + ".mp4").length, 180);
});

test("uniquePath never overwrites an earlier download", () => {
  const taken = new Set(["/d/clip.mp4", "/d/clip (2).mp4"]);
  const exists = (p) => taken.has(p);
  assert.equal(uniquePath("/d", "clip.mp4", exists), path.join("/d", "clip (3).mp4"));
  assert.equal(uniquePath("/d", "fresh.mp4", exists), path.join("/d", "fresh.mp4"));
  assert.equal(uniquePath("/d", "noext", (p) => p === "/d/noext"), path.join("/d", "noext (2)"));
});

test("encodeForLink encodes the characters that break a markdown link", () => {
  assert.equal(encodeForLink("clip (1080p).mp4"), "clip%20%281080p%29.mp4");
  assert.equal(encodeForLink("it's *big*!"), "it%27s%20%2Abig%2A%21");
  assert.equal(decodeURIComponent(encodeForLink("🚀 ¿Cuántas？.mp4")), "🚀 ¿Cuántas？.mp4");
});

test("mediaMarkdown is one line Alice parses back to the same path and mirror", () => {
  const dest = "/Users/m/.hermes/profiles/descargas/workspace/descargas/Pole (1080p, h264).mp4";
  const mirror = "http://MacBook-Pro-de-Marcos.local:9000/tunnel?id=6skTcd&exp=1&sig=HFpW";
  const line = mediaMarkdown(dest, mirror);
  assert.match(line, /^!\[Pole \(1080p, h264\)\.mp4\]\(alice:\/\/file\?path=.+&url=.+\)$/);
  assert.ok(!line.includes("\n"));
  const inner = line.slice(line.indexOf("](") + 2, -1);
  const params = new URL(inner).searchParams;
  assert.equal(params.get("path"), dest);
  assert.equal(params.get("url"), mirror);
});

test("mediaMarkdown without a mirror carries only the path", () => {
  const line = mediaMarkdown("/x/song.mp3");
  assert.equal(line, "![song.mp3](alice://file?path=%2Fx%2Fsong.mp3)");
});

test("mediaMarkdown strips brackets from the label so the link stays one link", () => {
  const line = mediaMarkdown("/x/weird [take 2].mp4", "https://m/t");
  assert.ok(line.startsWith("![weird take 2.mp4]("));
});

test("extensionFor prefers the URL, then the content type, then the picker type", () => {
  assert.equal(extensionFor({ url: "https://cdn/x/photo.JPG?x=1" }), ".jpg");
  assert.equal(extensionFor({ url: "https://cdn/tunnel?id=1", contentType: "video/mp4; charset=x" }), ".mp4");
  assert.equal(extensionFor({ url: "https://cdn/tunnel", type: "photo" }), ".jpg");
  assert.equal(extensionFor({ type: "gif" }), ".gif");
  assert.equal(extensionFor({}), "");
});

test("describeCobaltError speaks for the common codes and never crashes on unknown ones", () => {
  assert.equal(describeCobaltError("error.api.content.video.private"), "That video is private.");
  assert.match(describeCobaltError("error.api.fetch.fail"), /private, deleted or region-locked/);
  assert.equal(describeCobaltError("weird.code"), "cobalt error: weird.code");
  assert.equal(describeCobaltError(undefined), "cobalt error: unknown");
  assert.match(describeCobaltError("error.api.content.too_long", { limit: 10800 }), /\(limit=10800\)$/);
});

test("savedReport lists the fields the SOUL reads, media_markdown included", () => {
  const report = savedReport({
    dest: "/w/descargas/clip.mp4", bytes: 3 * 1_048_576, mirrorUrl: "https://m/t", status: "tunnel",
  });
  const lines = report.split("\n");
  assert.equal(lines[0], "SAVED: /w/descargas/clip.mp4");
  assert.equal(lines[1], "size: 3.0 MB");
  assert.equal(lines[2], "filename: clip.mp4");
  assert.equal(lines[3], "status: tunnel");
  assert.ok(lines[4].startsWith("media_markdown: ![clip.mp4](alice://file?path="));
  assert.equal(lines[5], "fallback link (expires): https://m/t");
});
