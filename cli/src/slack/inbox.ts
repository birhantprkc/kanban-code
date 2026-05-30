/// Download Slack file attachments to a local inbox directory so the agent
/// can read them with its own tools. Slack's `url_private` requires an
/// `Authorization: Bearer <bot token>` header — same scope (`files:read`)
/// the bridge already needs to discover them.

import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { SlackFile } from "./inbound.js";

/// Inbox root for downloaded Slack attachments. Override with SLACK_INBOX_DIR.
/// On the agents box this resolves to /home/ubuntu/agent-inbox/<slug>/.
export function inboxRoot(): string {
  return process.env.SLACK_INBOX_DIR || join(homedir(), "agent-inbox");
}

/// Default upper bound per file (50 MB). Slack's own upload cap is much
/// higher but we are running on a 30 GB root volume shared with worktrees,
/// so guard against an accidental huge dump.
export const DEFAULT_MAX_FILE_BYTES = 50 * 1024 * 1024;

export interface DownloadedFile {
  path: string;
  name: string;
  mimetype?: string;
  size: number;
}

export interface DownloadOptions {
  botToken: string;
  slug: string;
  /// Override the default fetch (tests).
  fetchImpl?: typeof fetch;
  /// Override the inbox root (tests).
  rootDir?: string;
  /// Override the per-file size cap.
  maxBytes?: number;
  /// Deterministic timestamp prefix (tests). Defaults to Date.now() at call.
  nowMs?: number;
}

/// Sanitize a Slack-provided file name so it cannot escape the inbox dir.
/// Slack does not pre-sanitize file.name — a user could attach `../../etc/passwd`.
export function sanitizeAttachmentName(raw: string | undefined): string {
  const fallback = "attachment.bin";
  if (!raw) return fallback;
  // Strip any path separators and NUL bytes, drop control chars, collapse
  // whitespace. Keep most printable characters so PDFs, zips etc. keep their
  // human-readable name.
  const cleaned = raw
    .replace(/[\\/\x00]/g, "_")
    .replace(/[\x01-\x1f]/g, "")
    .trim();
  if (!cleaned || cleaned === "." || cleaned === "..") return fallback;
  // Cap at 120 chars to keep the full path well under POSIX NAME_MAX (255).
  return cleaned.length > 120 ? cleaned.slice(0, 120) : cleaned;
}

/// Download one Slack file into the per-agent inbox dir. Throws on HTTP error
/// or when the file exceeds maxBytes (a partial file is removed by the caller's
/// try/catch chain via the size guard happening BEFORE the write).
export async function downloadSlackFile(file: SlackFile, opts: DownloadOptions): Promise<DownloadedFile> {
  const url = file.url_private_download || file.url_private;
  if (!url) throw new Error("slack file missing url_private");

  const fetchImpl = opts.fetchImpl ?? fetch;
  const res = await fetchImpl(url, {
    headers: { Authorization: `Bearer ${opts.botToken}` },
  });
  if (!res.ok) throw new Error(`download ${url} failed: HTTP ${res.status}`);

  const buf = Buffer.from(await res.arrayBuffer());
  const maxBytes = opts.maxBytes ?? DEFAULT_MAX_FILE_BYTES;
  if (buf.length > maxBytes) {
    throw new Error(`download ${url} exceeded max size (${buf.length} > ${maxBytes} bytes)`);
  }

  const dir = join(opts.rootDir ?? inboxRoot(), opts.slug);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

  const name = sanitizeAttachmentName(file.name);
  const ts = new Date(opts.nowMs ?? Date.now()).toISOString().replace(/[:.]/g, "-");
  const path = join(dir, `${ts}-${name}`);
  writeFileSync(path, buf);

  return { path, name, mimetype: file.mimetype, size: buf.length };
}

/// Stitch the original Slack text and any downloaded attachments into a
/// single prompt for the agent. Each attachment is rendered on its own line
/// so the agent can pass the path straight to Read.
export function formatPromptWithAttachments(text: string, files: DownloadedFile[]): string {
  if (files.length === 0) return text;
  const lines = files.map((f) => `[attachment: ${f.path}]`);
  return text ? `${text}\n\n${lines.join("\n")}` : lines.join("\n");
}
