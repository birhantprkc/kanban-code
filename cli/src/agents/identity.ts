import { uuidv5 } from "../uuid.js";
import { Runtime } from "./runtime.js";

/// A stable, readable identity for a long-lived agent. Everything humans see or
/// type is the readable slug; the session id is a deterministic UUID. For Claude
/// it is the --session-id / --resume key; for Codex (which mints its own id) it
/// is still the stable hook-events correlation key, passed to the hook via env.
export interface AgentIdentity {
  /// Readable slug, e.g. "dependabot-scout". Source of truth for the identity.
  slug: string;
  /// Which agent CLI drives this agent.
  runtime: Runtime;
  /// Deterministic UUIDv5 of the slug. Claude --session-id/--resume key, and the
  /// hook-events correlation key for both runtimes.
  sessionId: string;
  /// tmux session name (== slug).
  tmuxName: string;
  /// kanban card name (== slug).
  cardName: string;
  /// git worktree name (== slug).
  worktreeName: string;
}

const SLUG_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;

export function isValidSlug(slug: string): boolean {
  return SLUG_RE.test(slug) && slug.length <= 60;
}

export function agentIdentity(slug: string, runtime: Runtime = "claude"): AgentIdentity {
  if (!isValidSlug(slug)) {
    throw new Error(
      `Invalid agent slug "${slug}" (use lowercase letters, digits and hyphens; max 60 chars)`
    );
  }
  return {
    slug,
    runtime,
    sessionId: uuidv5(slug),
    tmuxName: slug,
    cardName: slug,
    worktreeName: slug,
  };
}
