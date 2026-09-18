#!/usr/bin/env node
/**
 * cobalt-mcp — MCP server wrapping a self-hosted cobalt API instance.
 *
 * Exposes three tools to the agent:
 *   - cobalt_download: process a media URL and get a download link
 *   - cobalt_services: list services the instance supports
 *   - cobalt_instance_info: instance version/status
 *
 * Config via env vars:
 *   COBALT_API_URL  (default: http://localhost:9000/)
 *   COBALT_API_KEY  (optional, sent as "Authorization: Api-Key <key>")
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";

const API_URL = (process.env.COBALT_API_URL || "http://localhost:9000/").replace(
  /\/?$/,
  "/",
);
const API_KEY = process.env.COBALT_API_KEY || "";

function headers() {
  const h = { Accept: "application/json", "Content-Type": "application/json" };
  if (API_KEY) h.Authorization = `Api-Key ${API_KEY}`;
  return h;
}

function fail(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}

const server = new McpServer({
  name: "cobalt",
  version: "0.1.0",
});

server.registerTool(
  "cobalt_download",
  {
    title: "Download media",
    description:
      "Process a media URL (YouTube, TikTok, Instagram, Twitter/X, Reddit, SoundCloud, Vimeo and ~15 more) through the local cobalt instance, SAVE the file to the Hermes workspace and return the saved path plus a fallback download link. Use this when the user asks to download or save media from a link.",
    inputSchema: {
      url: z.string().url().describe("Source media URL"),
      downloadMode: z
        .enum(["auto", "audio", "mute"])
        .default("auto")
        .describe("auto = video with audio; audio = audio only; mute = video only"),
      audioFormat: z
        .enum(["best", "mp3", "ogg", "wav", "opus"])
        .default("mp3")
        .describe("Audio format when downloadMode is audio"),
      videoQuality: z
        .enum(["max", "2160", "1440", "1080", "720", "480", "360", "240", "144"])
        .default("1080")
        .describe("Maximum video quality"),
    },
  },
  async ({ url, downloadMode, audioFormat, videoQuality }) => {
    let res;
    try {
      res = await fetch(API_URL, {
        method: "POST",
        headers: headers(),
        body: JSON.stringify({ url, downloadMode, audioFormat, videoQuality }),
        signal: AbortSignal.timeout(120_000),
      });
    } catch (err) {
      return fail(
        `Cannot reach cobalt at ${API_URL}. Is the docker container running? (${err.message})`,
      );
    }

    let data;
    try {
      data = await res.json();
    } catch {
      return fail(`cobalt returned HTTP ${res.status} with a non-JSON body.`);
    }

    if (data.status === "error") {
      return fail(`cobalt error: ${data.error?.code ?? JSON.stringify(data)}`);
    }

    // Handle pickers (multiple items) by listing them; single tunnel/redirect gets saved.
    if (Array.isArray(data.picker)) {
      const lines = [`status: picker (${data.picker.length} items, saved none — tell the user to pick)`];
      for (const [i, item] of data.picker.entries()) {
        lines.push(`  [${i}] ${item.type}: ${item.url}`);
      }
      return { content: [{ type: "text", text: lines.join("\n") }] };
    }

    const downloadUrl = data.url || data.audio;
    if (!downloadUrl) {
      return fail(`cobalt answered ${data.status} but no download URL: ${JSON.stringify(data).slice(0, 300)}`);
    }

    // Save the file locally so it shows up in Alice's Files screen.
    const name = data.filename || data.audioFilename || `cobalt-${Date.now()}`;
    const saveDir = process.env.COBALT_SAVE_DIR || "";
    if (!saveDir) {
      return fail("COBALT_SAVE_DIR is not set — cannot save the file.");
    }

    const safeName = name.replace(/[/\\:*?"<>|]/g, "_").slice(0, 180) || `cobalt-${Date.now()}`;
    const dest = path.join(saveDir, safeName);
    try {
      await fs.mkdir(saveDir, { recursive: true });
      const fileRes = await fetch(downloadUrl, { signal: AbortSignal.timeout(600_000) });
      if (!fileRes.ok) {
        return fail(`Downloading the file failed: HTTP ${fileRes.status} from ${downloadUrl}`);
      }
      await pipeline(fileRes.body, fsSync.createWriteStream(dest));
      const stat = await fs.stat(dest);
      const mb = (stat.size / 1_048_576).toFixed(1);
      return {
        content: [{
          type: "text",
          text: `SAVED: ${dest}\nsize: ${mb} MB\nfilename: ${safeName}\nstatus: ${data.status}\nfallback link (expires): ${downloadUrl}`,
        }],
      };
    } catch (err) {
      return fail(`File save failed: ${err.message}. The link still works: ${downloadUrl}`);
    }
  },
);

server.registerTool(
  "cobalt_services",
  {
    title: "List supported services",
    description: "List the media services supported by the local cobalt instance.",
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
      return {
        content: [
          {
            type: "text",
            text: services.length
              ? `Supported services (${services.length}): ${services.join(", ")}`
              : "Could not read the services list from the cobalt instance.",
          },
        ],
      };
    } catch (err) {
      return fail(
        `Cannot reach cobalt at ${API_URL}. Is the docker container running? (${err.message})`,
      );
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
      return {
        content: [
          {
            type: "text",
            text: `cobalt ${c.version ?? "?"} @ ${c.url ?? API_URL}\nservices: ${(c.services ?? []).join(", ") || "unknown"}`,
          },
        ],
      };
    } catch (err) {
      return fail(
        `Cannot reach cobalt at ${API_URL}. Is the docker container running? (${err.message})`,
      );
    }
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
