/// Runtime abstraction for the headless agent engine. The engine was built for
/// Claude Code; this table lets a single agent be driven by a different CLI
/// (currently Codex) without branching all over launch/daemon/bridge. It mirrors
/// the macOS app's CodingAssistant entity, scoped to what the headless path needs.

export type Runtime = "claude" | "codex";

export const RUNTIMES: readonly Runtime[] = ["claude", "codex"] as const;

export function isRuntime(v: unknown): v is Runtime {
  return v === "claude" || v === "codex";
}

export interface BuildArgsInput {
  /// The stable session id (uuidv5 of the slug). Used as Claude's --session-id
  /// and, for both runtimes, as the hook-events correlation key via env.
  sessionId: string;
  /// Readable agent slug.
  slug: string;
  /// Resume an existing session rather than launching fresh.
  resume: boolean;
  /// Skip permission/approval prompts (autonomous agents).
  skipPermissions: boolean;
  /// Model alias/name, if pinned.
  model?: string;
}

export interface RuntimeSpec {
  /// The CLI binary.
  bin: string;
  /// Build the argv after the binary.
  buildArgs(input: BuildArgsInput): string[];
  /// Whether this runtime can resume a prior session by our session id. Claude
  /// can (--resume <uuid>); Codex generates its own id and the headless reviewer
  /// is per-PR, so we always launch it fresh and rely on tmux to keep it alive.
  canResume: boolean;
  /// Whether the daemon's context-threshold self-compaction applies. Codex
  /// auto-compacts on its own and exposes no context introspection, so off.
  selfCompact: boolean;
  /// Config dir under $HOME (for hooks/skills install).
  configDirName: string;
}

const claude: RuntimeSpec = {
  bin: "claude",
  canResume: true,
  selfCompact: true,
  configDirName: ".claude",
  buildArgs({ sessionId, slug, resume, skipPermissions, model }) {
    const args: string[] = [];
    if (resume) args.push("--resume", sessionId);
    else args.push("--session-id", sessionId, "--name", slug);
    if (skipPermissions) args.push("--dangerously-skip-permissions");
    if (model) args.push("--model", model);
    return args;
  },
};

const codex: RuntimeSpec = {
  bin: "codex",
  canResume: false,
  selfCompact: false,
  configDirName: ".codex",
  buildArgs({ skipPermissions, model }) {
    // --no-alt-screen keeps Codex inline so tmux send-keys paste works (no TUI
    // alt-screen). The bypass flags are Codex's equivalent of Claude's
    // --dangerously-skip-permissions; --dangerously-bypass-hook-trust skips the
    // interactive hook-trust gate so our hooks run unattended.
    const args = ["--no-alt-screen"];
    if (skipPermissions) {
      args.push("--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust");
    }
    if (model) args.push("-m", model);
    return args;
  },
};

const SPECS: Record<Runtime, RuntimeSpec> = { claude, codex };

export function runtimeSpec(runtime: Runtime): RuntimeSpec {
  return SPECS[runtime];
}
