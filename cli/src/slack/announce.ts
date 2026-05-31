import { SlackClient } from "./client.js";
import { loadAgentsConfig } from "../agents/config.js";
import { join } from "node:path";
import { homedir } from "node:os";

/// Mirrors every prompt injected into an agent (scheduled nudges, self-compact,
/// auto-sent queued prompts, and any `kanban send` someone runs by hand) to the
/// agent's Slack channel. Messages relayed *from* a Slack human must NOT go
/// through here, they already appear in Slack as that person's message.

// The received-message formatting lives in format.ts (all Slack rendering does);
// re-exported here so the Claude announce path and existing imports stay stable.
export { RECEIVED_MESSAGE_HEADER, formatReceivedMessage } from "./format.js";
import { formatReceivedMessage } from "./format.js";
import { writeThreadRoot } from "./thread-root.js";

/// Single plain label shown for the entire "agent is working" state — no
/// tool name, no emoji. Slack's setStatus already renders its own animated
/// indicator next to the text. Shared between announce + bridge so they
/// don't drift.
export const WORKING_PILL_LABEL = "is working…";

function defaultConfigPath(): string {
  return process.env.KANBAN_AGENTS_CONFIG || join(homedir(), ".kanban-code", "agents.yaml");
}

// slug -> resolved channel id, cached per process.
const channelCache = new Map<string, string | null>();
let cachedClient: SlackClient | undefined;

function client(token?: string): SlackClient | undefined {
  const t = token || process.env.SLACK_BOT_TOKEN;
  if (!t) return undefined;
  if (!cachedClient) cachedClient = new SlackClient(t);
  return cachedClient;
}

async function channelForSlug(slug: string, configPath: string, c: SlackClient): Promise<string | undefined> {
  if (channelCache.has(slug)) return channelCache.get(slug) ?? undefined;
  let id: string | undefined;
  try {
    const file = loadAgentsConfig(configPath);
    const agent = file.agents.find((a) => a.slug === slug);
    if (agent?.slackChannel) id = await c.resolveChannelId(agent.slackChannel);
  } catch {
    /* no config / unresolvable */
  }
  channelCache.set(slug, id ?? null);
  return id;
}

export interface AnnounceOptions {
  token?: string;
  configPath?: string;
}

/// Announce text to an agent's channel. No-op (returns false) if no token is
/// configured or the agent has no resolvable channel.
export async function announceToSlack(slug: string, text: string, opts: AnnounceOptions = {}): Promise<boolean> {
  return announceRawToSlack(slug, formatReceivedMessage(text), opts);
}

/// Same as announceToSlack but posts the body verbatim (no "Received user
/// message" header). Used for system-style notifications like self-compact
/// triggers where the wording is fully owned by the caller. Still opens the
/// thread for the turn and lights the pill so the bridge's later assistant
/// posts thread under this anchor.
export async function announceRawToSlack(slug: string, text: string, opts: AnnounceOptions = {}): Promise<boolean> {
  const c = client(opts.token);
  if (!c) return false;
  const channel = await channelForSlug(slug, opts.configPath ?? defaultConfigPath(), c);
  if (!channel) return false;
  try {
    const ts = await c.post(channel, text);
    if (ts) {
      writeThreadRoot(slug, ts);
      try {
        await c.setStatus(channel, ts, WORKING_PILL_LABEL);
      } catch {
        /* setStatus is best-effort; channel + thread already exist */
      }
    }
    return true;
  } catch {
    return false;
  }
}
