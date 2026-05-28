import { AgentIdentity } from "./identity.js";
import {
  hasTmuxSession,
  createTmuxSession,
  findSessionJsonl,
  readLinks,
} from "../data.js";
import { upsertCard, isoNow } from "../cards.js";
import { generateKsuid } from "../ksuid.js";
import { Link, ManualOverrides } from "../types.js";
import { runtimeSpec } from "./runtime.js";

export interface LaunchOptions {
  /// Working directory for the session (the agent's workspace / worktree root).
  cwd: string;
  /// Extra args appended to the agent invocation.
  extraArgs?: string[];
  /// Environment variables exported into the tmux session.
  env?: Record<string, string>;
  /// Model alias or full name.
  model?: string;
  /// Autonomous agents skip permission prompts by default.
  skipPermissions?: boolean;
  /// Override the agent binary (tests).
  bin?: string;
}

export type LaunchAction = "noop-running" | "launched" | "resumed";

export interface LaunchResult {
  action: LaunchAction;
  identity: AgentIdentity;
  sessionId: string;
  tmuxName: string;
  command?: string;
  card: Link;
}

const DEFAULT_OVERRIDES: ManualOverrides = {
  worktreePath: false,
  tmuxSession: false,
  name: false,
  column: false,
  prLink: false,
  issueLink: false,
};

/// Idempotently ensure an agent's session is running in tmux and its kanban card
/// reflects reality. Decides launch vs resume vs no-op:
///   - tmux session already alive            -> no-op (never restart a live agent)
///   - runtime can resume + transcript exists -> resume
///   - otherwise                              -> fresh launch
/// Codex mints its own session id and the reviewer is per-PR, so it always
/// launches fresh (canResume=false); tmux keeps it alive between prompts.
export function ensureAgentSession(
  identity: AgentIdentity,
  opts: LaunchOptions
): LaunchResult {
  const spec = runtimeSpec(identity.runtime);
  const bin = opts.bin ?? spec.bin;
  const skipPerms = opts.skipPermissions ?? true;

  const tmuxAlive = hasTmuxSession(identity.tmuxName);
  const sessionExists = spec.canResume && !!findSessionJsonl(identity.sessionId);

  let action: LaunchAction;
  let command: string | undefined;

  if (tmuxAlive) {
    action = "noop-running";
  } else {
    const args = spec.buildArgs({
      sessionId: identity.sessionId,
      slug: identity.slug,
      resume: sessionExists,
      skipPermissions: skipPerms,
      model: opts.model,
    });
    action = sessionExists ? "resumed" : "launched";
    if (opts.extraArgs?.length) args.push(...opts.extraArgs);
    command = [bin, ...args].join(" ");

    // Both runtimes' hooks correlate events to this agent via this env var, so
    // the daemon/bridge key on our stable session id regardless of the id the
    // runtime mints internally.
    const env = { ...(opts.env ?? {}), KANBAN_SESSION_ID: identity.sessionId, KANBAN_SLUG: identity.slug };
    const res = createTmuxSession(identity.tmuxName, opts.cwd, command, env);
    if (!res.ok) {
      throw new Error(`Failed to create tmux session "${identity.tmuxName}": ${res.error}`);
    }
  }

  const card = upsertAgentCard(identity, opts.cwd);
  return {
    action,
    identity,
    sessionId: identity.sessionId,
    tmuxName: identity.tmuxName,
    command,
    card,
  };
}

/// Reconcile the agent's card to current truth. Writes only when something
/// meaningful changed, so a healthy reconcile is a true no-op on disk.
function upsertAgentCard(identity: AgentIdentity, cwd: string): Link {
  const existing = readLinks().find((l) => l.name === identity.cardName);
  const sessionPath = findSessionJsonl(identity.sessionId);

  const unchanged =
    existing &&
    !existing.manuallyArchived &&
    existing.sessionLink?.sessionId === identity.sessionId &&
    existing.sessionLink?.sessionPath === sessionPath &&
    existing.tmuxLink?.sessionName === identity.tmuxName &&
    existing.worktreeLink?.path === cwd;
  if (unchanged) return existing;

  const now = isoNow();
  const card: Link = {
    id: existing?.id ?? generateKsuid("card"),
    name: identity.cardName,
    column: existing?.column ?? "in_progress",
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
    lastActivity: now,
    manualOverrides: existing?.manualOverrides ?? { ...DEFAULT_OVERRIDES, name: true },
    manuallyArchived: false,
    source: "manual",
    sessionLink: { sessionId: identity.sessionId, sessionPath },
    tmuxLink: { sessionName: identity.tmuxName },
    worktreeLink: { path: cwd },
    assistant: identity.runtime,
    isRemote: false,
  };
  upsertCard(card);
  return card;
}
