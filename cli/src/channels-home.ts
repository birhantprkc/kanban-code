/**
 * Channels home proxy. When this machine is paired with a channels home (the
 * master that holds channel and DM data, see `channels-home.json`), every
 * `kanban channel ...` and `kanban dm ...` runs there over HTTP. The caller card
 * is resolved here first, because only this machine knows which tmux session
 * the command was typed in.
 */

import { readLinks } from "./data.js";
import { cardForTmuxSession, cardFromEnvironment, currentTmuxSessionName } from "./broadcast.js";
import { readChannelsHome, type ChannelsHome } from "./machines.js";
import { buildProxyRequest, type ProxyRequest } from "./remote-proxy.js";
import type { Link } from "./types.js";

export const CHANNELS_HOME_TIMEOUT_MS = 60_000;

function positionals(argv: string[]): string[] {
  return argv.filter((arg) => !arg.startsWith("-"));
}

/** Subcommands that open the local app or host a local server stay here. */
const LOCAL_SUBCOMMANDS: Record<string, Set<string>> = {
  channel: new Set(["open", "share"]),
  dm: new Set(["open"]),
};

/** Subcommands that only read, and may fall back to the local mirror. */
const READ_ONLY_SUBCOMMANDS: Record<string, Set<string>> = {
  channel: new Set(["list", "history", "members"]),
  dm: new Set(["history"]),
};

/** Whether this invocation belongs on the channels home. */
export function routesToChannelsHome(argv: string[], env: NodeJS.ProcessEnv = process.env): boolean {
  if (env.KANBAN_CHANNELS_LOCAL) return false;
  if (argv.some((arg) => arg === "-h" || arg === "--help")) return false;
  const [command, sub] = positionals(argv);
  if (command !== "channel" && command !== "dm") return false;
  if (!sub) return false;
  return !LOCAL_SUBCOMMANDS[command].has(sub);
}

export function isReadOnlyChannelCommand(argv: string[]): boolean {
  const [command, sub] = positionals(argv);
  if (!command || !sub) return false;
  return READ_ONLY_SUBCOMMANDS[command]?.has(sub) ?? false;
}

function optionValue(argv: string[], name: string): string | undefined {
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === name) return argv[index + 1];
    if (arg.startsWith(`${name}=`)) return arg.slice(name.length + 1);
  }
  return undefined;
}

export interface CallerLookup {
  links?: () => Link[];
  env?: NodeJS.ProcessEnv;
  tmuxSession?: () => string | undefined;
}

/**
 * The card this command speaks for, resolved the way the channel commands do:
 * `--as-card-id`, then `KANBAN_CARD_ID`, then the card of the current tmux
 * session. `--as-user` speaks for the human, so there is no card.
 */
export function localCallerCardId(argv: string[], lookup: CallerLookup = {}): string | undefined {
  if (argv.includes("--as-user")) return undefined;
  const explicit = optionValue(argv, "--as-card-id")?.trim();
  if (explicit) return explicit;
  let links: Link[];
  try {
    links = (lookup.links ?? readLinks)();
  } catch {
    links = [];
  }
  const declared = cardFromEnvironment(links, lookup.env ?? process.env);
  if (declared) return declared.id;
  const session = (lookup.tmuxSession ?? currentTmuxSessionName)();
  if (!session) return undefined;
  return cardForTmuxSession(links, session)?.id;
}

export interface ChannelsHomeRequest extends Omit<ProxyRequest, "env"> {
  env: { KANBAN_CARD_ID?: string; KANBAN_HUMAN_HANDLE?: string };
}

export interface ChannelsHomeResponse {
  stdout?: string;
  stderr?: string;
  code?: number;
}

export function buildChannelsHomeRequest(
  argv: string[],
  options: { id?: string; cwd?: string; cardId?: string; humanHandle: string; readImage?: (path: string) => Buffer }
): ChannelsHomeRequest {
  const base = buildProxyRequest(argv, {
    id: options.id,
    cwd: options.cwd,
    readImage: options.readImage,
  });
  const env: ChannelsHomeRequest["env"] = { KANBAN_HUMAN_HANDLE: options.humanHandle };
  if (options.cardId) env.KANBAN_CARD_ID = options.cardId;
  const { stdin: _stdin, ...rest } = base;
  return { ...rest, env };
}

export async function postToChannelsHome(
  home: ChannelsHome,
  request: ChannelsHomeRequest,
  timeoutMs: number = CHANNELS_HOME_TIMEOUT_MS
): Promise<ChannelsHomeResponse> {
  const response = await fetch(`${home.url}/v1/cli`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${home.token}`,
    },
    body: JSON.stringify(request),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}${text ? `: ${text.trim().slice(0, 300)}` : ""}`);
  }
  try {
    return JSON.parse(text) as ChannelsHomeResponse;
  } catch {
    throw new Error(`invalid response: ${text.trim().slice(0, 300)}`);
  }
}

function describeError(error: unknown): string {
  if (error instanceof Error) {
    if (error.name === "TimeoutError") return "timed out";
    const cause = (error as Error & { cause?: unknown }).cause;
    if (cause instanceof Error && cause.message) return `${error.message} (${cause.message})`;
    return error.message;
  }
  return String(error);
}

export interface RunOnChannelsHomeOptions {
  home?: ChannelsHome;
  humanHandle: string;
  cardId?: string;
  cwd?: string;
  timeoutMs?: number;
  write?: (text: string) => void;
  writeError?: (text: string) => void;
}

/**
 * Runs the invocation on the channels home and returns the exit code, or
 * `"local"` when the caller should run it here instead: there is no home, or
 * a read-only command could not reach it and the local mirror answers.
 */
export async function runOnChannelsHome(
  argv: string[],
  options: RunOnChannelsHomeOptions
): Promise<number | "local"> {
  const home = options.home ?? readChannelsHome();
  if (!home) return "local";
  const write = options.write ?? ((text: string) => process.stdout.write(text));
  const writeError = options.writeError ?? ((text: string) => process.stderr.write(text));
  let request: ChannelsHomeRequest;
  try {
    request = buildChannelsHomeRequest(argv, {
      cwd: options.cwd,
      cardId: options.cardId,
      humanHandle: options.humanHandle,
    });
  } catch (error) {
    writeError(`Error: ${describeError(error)}\n`);
    return 1;
  }
  let response: ChannelsHomeResponse;
  try {
    response = await postToChannelsHome(home, request, options.timeoutMs);
  } catch (error) {
    const reason = describeError(error);
    if (isReadOnlyChannelCommand(argv)) {
      writeError(`Showing the local copy of the channels: ${home.name} did not answer (${reason}).\n`);
      return "local";
    }
    writeError(`Error: Channels live on ${home.name} (${home.url}), which did not answer: ${reason}\n`);
    return 1;
  }
  if (response.stdout) write(response.stdout);
  if (response.stderr) writeError(response.stderr);
  return typeof response.code === "number" ? response.code : 0;
}
