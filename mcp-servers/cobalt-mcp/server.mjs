#!/usr/bin/env node
/**
 * cobalt-mcp — MCP server wrapping a self-hosted cobalt API instance.
 *
 * Exposes three tools to the agent:
 *   - cobalt_download: process a media URL, save the file(s) to the Hermes
 *     workspace and return the saved path plus a ready-to-paste
 *     `media_markdown` line that Alice draws as a player in the chat
 *   - cobalt_services: list services the instance supports
 *   - cobalt_instance_info: instance version/status
 *
 * Config via env vars:
 *   COBALT_API_URL   (default: http://localhost:9000/)
 *   COBALT_API_KEY   (optional, sent as "Authorization: Api-Key <key>")
 *   COBALT_SAVE_DIR  (required: where files land; Alice's Files → Workspace)
 *   COBALT_PICKER_MAX (default 10: how many picker items are saved)
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import {
  describeCobaltError,
  extensionFor,
  mediaMarkdown,
  safeFileName,
  savedReport,
  uniquePath,
} from "./lib.mjs";

const API_URL = (
  process.env.COBALT_API_URL || "http://localhost:9000/"
).replace(/\/?$/, "/");
const API_KEY = process.env.COBALT_API_KEY || "";
const SAVE_DIR = process.env.COBALT_SAVE_DIR || "";
const PICKER_MAX = Math.max(1, Number(process.env.COBALT_PICKER_MAX) || 10);
const PROCESS_TIMEOUT_MS = 120_000;
const FILE_TIMEOUT_MS = 900_000;

function headers() {
  const h = { Accept: "application/json", "Content-Type": "application/json" };
  if (API_KEY) h.Authorization = `Api-Key ${API_KEY}`;
  return h;
}

function fail(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}

function ok(text) {
  return { content: [{ type: "text", text }] };
}

function unreachable(err) {
  return fail(
    `Cannot reach cobalt at ${API_URL}. Is the docker container running? (${err?.message ?? err})`,
  );
}

/** Streams `url` into a fresh file under SAVE_DIR; never overwrites. */
async function saveFromUrl(url, preferredName, { type } = {}) {
  await fs.mkdir(SAVE_DIR, { recursive: true });
  const res = await fetch(url, {
    signal: AbortSignal.timeout(FILE_TIMEOUT_MS),
  });
  if (!res.ok || !res.body) {
    throw new Error(`HTTP ${res.status} while downloading the file`);
  }
  let name = safeFileName(preferredName);
  if (!path.extname(name)) {
    name += extensionFor({
      type,
      contentType: res.headers.get("content-type"),
      url,
    });
  }
  const dest = uniquePath(SAVE_DIR, name);
  const partial = `${dest}.part`;
  try {
    await pipeline(res.body, fsSync.createWriteStream(partial));
    await fs.rename(partial, dest);
  } catch (err) {
    await fs.rm(partial, { force: true }).catch(() => {});
    throw err;
  }
  const stat = await fs.stat(dest);
  if (stat.size === 0) {
    await fs.rm(dest, { force: true }).catch(() => {});
    throw new Error("the download was empty");
  }
  return { dest, bytes: stat.size };
}

const server = new McpServer({ name: "cobalt", version: "0.3.0" });

server.registerTool(
  "cobalt_download",
  {
    title: "Download media",
    description:
      "Process a media URL (YouTube, TikTok, Instagram, Twitter/X, Reddit, SoundCloud, Vimeo and ~15 more) through the local cobalt instance, SAVE the file to the Hermes workspace and return the saved path plus a `media_markdown` line. Paste that line verbatim, on its own paragraph, so Alice shows a player in the chat. Use this when the user asks to download or save media from a link.",
    inputSchema: {
      url: z.string().url().describe("Source media URL"),
      downloadMode: z
        .enum(["auto", "audio", "mute"])
        .default("auto")
        .describe(
          "auto = video with audio; audio = audio only; mute = video only",
        ),
      audioFormat: z
        .enum(["best", "mp3", "ogg", "wav", "opus"])
        .default("mp3")
        .describe("Audio format when downloadMode is audio"),
      videoQuality: z
        .enum([
          "max",
          "2160",
          "1440",
          "1080",
          "720",
          "480",
          "360",
          "240",
          "144",
        ])
        .default("1080")
        .describe("Maximum video quality"),
    },
  },
  async ({ url, downloadMode, audioFormat, videoQuality }) => {
    if (!SAVE_DIR)
      return fail("COBALT_SAVE_DIR is not set — cannot save the file.");

    let res;
    try {
      res = await fetch(API_URL, {
        method: "POST",
        headers: headers(),
        // Server-side processing: one finished file per request. Local
        // processing would hand back raw streams this tool cannot merge.
        body: JSON.stringify({
          url,
          downloadMode,
          audioFormat,
          videoQuality,
          localProcessing: "disabled",
        }),
        signal: AbortSignal.timeout(PROCESS_TIMEOUT_MS),
      });
    } catch (err) {
      return unreachable(err);
    }

    let data;
    try {
      data = await res.json();
    } catch {
      return fail(`cobalt returned HTTP ${res.status} with a non-JSON body.`);
    }

    if (data.status === "error") {
      return fail(describeCobaltError(data.error?.code, data.error?.context));
    }

    // A post with several pieces: save each one, report each one.
    if (data.status === "picker" && Array.isArray(data.picker)) {
      const items = data.picker.slice(0, PICKER_MAX);
      const lines = [
        `status: picker (${data.picker.length} items, ${items.length} saved)`,
      ];
      const failures = [];
      const stem = safeFileName(
        data.audioFilename || data.filename || `cobalt-${Date.now()}`,
      ).replace(/\.[a-z0-9]{2,5}$/i, "");
      for (const [i, item] of items.entries()) {
        try {
          const saved = await saveFromUrl(item.url, `${stem} ${i + 1}`, {
            type: item.type,
          });
          lines.push(`SAVED: ${saved.dest}`);
          lines.push(`media_markdown: ${mediaMarkdown(saved.dest, item.url)}`);
        } catch (err) {
          failures.push(`  [${i + 1}] ${item.type}: ${err.message}`);
        }
      }
      if (data.audio) {
        try {
          const saved = await saveFromUrl(
            data.audio,
            data.audioFilename || `${stem} audio`,
            { type: "audio" },
          );
          lines.push(`SAVED: ${saved.dest}`);
          lines.push(
            `media_markdown: ${mediaMarkdown(saved.dest, data.audio)}`,
          );
        } catch (err) {
          failures.push(`  [audio] ${err.message}`);
        }
      }
      if (failures.length) lines.push("failed:", ...failures);
      if (data.picker.length > items.length) {
        lines.push(
          `note: only the first ${items.length} of ${data.picker.length} items were saved`,
        );
      }
      return lines.length > 1 && !lines.some((l) => l.startsWith("SAVED"))
        ? fail(lines.join("\n"))
        : ok(lines.join("\n"));
    }

    // Raw streams for the client to merge. One stream is a finished file;
    // several would need ffmpeg here, which this tool does not have.
    if (data.status === "local-processing") {
      const tunnels = Array.isArray(data.tunnel) ? data.tunnel : [];
      if (tunnels.length !== 1) {
        return fail(
          `cobalt asked for local processing (${data.type ?? "merge"}, ${tunnels.length} streams), which this tool cannot do. Set FORCE_LOCAL_PROCESSING=never on the cobalt instance.`,
        );
      }
      try {
        const saved = await saveFromUrl(
          tunnels[0],
          data.output?.filename || `cobalt-${Date.now()}`,
        );
        return ok(
          savedReport({ ...saved, mirrorUrl: tunnels[0], status: data.status }),
        );
      } catch (err) {
        return fail(
          `File save failed: ${err.message}. The link still works: ${tunnels[0]}`,
        );
      }
    }

    const downloadUrl = data.url || data.audio;
    if (!downloadUrl) {
      return fail(
        `cobalt answered ${data.status} but no download URL: ${JSON.stringify(data).slice(0, 300)}`,
      );
    }
    try {
      const saved = await saveFromUrl(
        downloadUrl,
        data.filename || data.audioFilename || `cobalt-${Date.now()}`,
        {
          type: downloadMode === "audio" ? "audio" : "video",
        },
      );
      return ok(
        savedReport({ ...saved, mirrorUrl: downloadUrl, status: data.status }),
      );
    } catch (err) {
      return fail(
        `File save failed: ${err.message}. The link still works: ${downloadUrl}`,
      );
    }
  },
);

server.registerTool(
  "cobalt_services",
  {
    title: "List supported services",
    description:
      "List the media services supported by the local cobalt instance.",
    inputSchema: {},
  },
  async () => {
    try {
      const res = await fetch(API_URL, {
        headers: headers(),
        signal: AbortSignal.timeout(15_000),
      });
      const data = await res.json();
      const services = data?.cobalt?.services ?? [];
      return ok(
        services.length
          ? `Supported services (${services.length}): ${services.join(", ")}`
          : "Could not read the services list from the cobalt instance.",
      );
    } catch (err) {
      return unreachable(err);
    }
  },
);

server.registerTool(
  "cobalt_instance_info",
  {
    title: "Cobalt instance info",
    description: "Get version and status of the local cobalt instance.",
    inputSchema: {},
  },
  async () => {
    try {
      const res = await fetch(API_URL, {
        headers: headers(),
        signal: AbortSignal.timeout(15_000),
      });
      const data = await res.json();
      const c = data?.cobalt ?? {};
      return ok(
        `cobalt ${c.version ?? "?"} @ ${c.url ?? API_URL}\nservices: ${(c.services ?? []).join(", ") || "unknown"}\nsave dir: ${SAVE_DIR || "(unset)"}`,
      );
    } catch (err) {
      return unreachable(err);
    }
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
