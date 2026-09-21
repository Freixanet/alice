/**
 * Pure helpers for cobalt-mcp, kept apart from the server so they can be
 * tested with `node --test` and never drift from what the iPhone expects.
 */
import fsSync from "node:fs";
import path from "node:path";

/** A filename the Mac, Alice and a markdown label all accept. */
export function safeFileName(name, fallback = `cobalt-${Date.now()}`) {
  const cleaned = String(name ?? "")
    .replace(/[\r\n\t]/g, " ")
    .replace(/[/\\:*?"<>|[\]]/g, "_")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^\.+/, "")
    .slice(0, 180)
    .trim();
  return cleaned || fallback;
}

/** `name.mp4` → `name (2).mp4` when `name.mp4` already exists in `dir`. */
export function uniquePath(
  dir,
  fileName,
  exists = (p) => fsSync.existsSync(p),
) {
  const ext = path.extname(fileName);
  const stem = fileName.slice(0, fileName.length - ext.length);
  let candidate = path.join(dir, fileName);
  for (let n = 2; exists(candidate) && n < 1000; n += 1) {
    candidate = path.join(dir, `${stem} (${n})${ext}`);
  }
  return candidate;
}

/**
 * Like encodeURIComponent, but also encodes the characters it leaves alone
 * that break a markdown link: `(`, `)`, `!`, `'`, `*`. A file called
 * `clip (1080p).mp4` must survive the trip through the model and the parser.
 */
export function encodeForLink(text) {
  return encodeURIComponent(text).replace(
    /[!'()*]/g,
    (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase(),
  );
}

/**
 * The one line the bot pastes so Alice draws a player in the chat.
 *
 * `alice://file?path=…` names the file on this machine; Alice fetches it over
 * its own authenticated Hermes connection, so it plays from anywhere and
 * never expires. `url` is the cobalt tunnel, kept as a fallback for a client
 * that has no file access. The label carries the extension — that is what
 * decides video, audio or image on the phone.
 */
export function mediaMarkdown(savedPath, mirrorUrl) {
  const label = path.basename(savedPath).replace(/[[\]]/g, "");
  const query = [`path=${encodeForLink(savedPath)}`];
  if (mirrorUrl) query.push(`url=${encodeForLink(mirrorUrl)}`);
  return `![${label}](alice://file?${query.join("&")})`;
}

/** File extension for a picker item / response, from its type or headers. */
export function extensionFor({ type, contentType, url } = {}) {
  const fromUrl = (() => {
    try {
      const ext = path.extname(new URL(url ?? "").pathname).toLowerCase();
      return /^\.[a-z0-9]{2,5}$/.test(ext) ? ext : "";
    } catch {
      return "";
    }
  })();
  if (fromUrl) return fromUrl;
  const mime = String(contentType ?? "")
    .split(";")[0]
    .trim()
    .toLowerCase();
  const byMime = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/heic": ".heic",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/webm": ".webm",
    "audio/mpeg": ".mp3",
    "audio/mp4": ".m4a",
    "audio/ogg": ".ogg",
    "audio/opus": ".opus",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
  };
  if (byMime[mime]) return byMime[mime];
  switch (type) {
    case "photo":
      return ".jpg";
    case "gif":
      return ".gif";
    case "video":
      return ".mp4";
    case "audio":
      return ".mp3";
    default:
      return "";
  }
}

/** cobalt's error codes, said so the bot can say them to a person. */
export function describeCobaltError(code, context) {
  const key = String(code ?? "").replace(/^error\.api\./, "");
  const known = {
    "service.unsupported": "That site isn't supported by cobalt.",
    "service.disabled": "That service is turned off on this cobalt instance.",
    "link.invalid": "That doesn't look like a valid link.",
    "link.unsupported": "That link isn't supported by cobalt.",
    "fetch.fail":
      "cobalt couldn't fetch the media. It may be private, deleted or region-locked.",
    "fetch.critical": "cobalt hit an internal error fetching this media.",
    "fetch.empty": "cobalt found nothing to download at that link.",
    "fetch.rate":
      "The source is rate-limiting cobalt. Try again in a few minutes.",
    "fetch.short_link": "cobalt couldn't resolve that short link.",
    "content.too_long": "The media is longer than this instance allows.",
    "content.video.unavailable":
      "That video is unavailable (private, deleted or region-locked).",
    "content.video.live":
      "That's a live stream; cobalt only downloads finished videos.",
    "content.video.private": "That video is private.",
    "content.video.age": "That video is age-restricted and needs a login.",
    "content.video.region": "That video isn't available in this region.",
    "content.post.unavailable": "That post is unavailable.",
    "content.post.private": "That post is private.",
    "content.post.age": "That post is age-restricted and needs a login.",
    "youtube.login": "YouTube is asking cobalt to sign in for this video.",
    "youtube.codec": "YouTube has no matching codec for the requested quality.",
    "auth.jwt.missing": "This cobalt instance requires authentication.",
    "auth.key.invalid": "The cobalt API key is not accepted.",
    rate_exceeded: "Too many requests to cobalt; wait a moment.",
    capacity: "cobalt is at capacity right now; try again shortly.",
    generic: "cobalt reported an error.",
    unknown_response: "cobalt gave an answer this tool doesn't understand.",
  };
  const said = known[key] ?? `cobalt error: ${key || "unknown"}`;
  const extra =
    context && typeof context === "object"
      ? Object.entries(context)
          .map(([k, v]) => `${k}=${v}`)
          .join(", ")
      : "";
  return extra ? `${said} (${extra})` : said;
}

/** Lines the bot reads back; the shape Alice's SOUL relies on. */
export function savedReport({
  dest,
  bytes,
  mirrorUrl,
  status,
  extraLines = [],
}) {
  const mb = (bytes / 1_048_576).toFixed(1);
  return [
    `SAVED: ${dest}`,
    `size: ${mb} MB`,
    `filename: ${path.basename(dest)}`,
    `status: ${status}`,
    `media_markdown: ${mediaMarkdown(dest, mirrorUrl)}`,
    ...(mirrorUrl ? [`fallback link (expires): ${mirrorUrl}`] : []),
    ...extraLines,
  ].join("\n");
}
