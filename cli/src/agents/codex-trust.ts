/**
 * Recording that a workspace is trusted, so codex does not stop to ask.
 *
 * Codex asks about a directory the first time it is started in one, and waits
 * on the answer before it draws anything. A headless agent has nobody to
 * answer it, so its very first launch in a fresh workspace sits on the
 * question until a person opens the pane. The answer is written to
 * `config.toml` as a `[projects."<path>"]` table, which is what codex itself
 * writes once the question is answered, so recording it up front is the same
 * state arrived at earlier.
 *
 * It grants codex nothing it does not already have here: agents launch with
 * `--dangerously-bypass-approvals-and-sandbox`, so the sandbox this question
 * guards is already off for them.
 *
 * A directory the operator has already ruled on is left alone, trusted or
 * not: only a directory codex has no entry for gets one.
 *
 * Spec: specs/sessions/headless-reconcile.feature
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

/// Honours CODEX_HOME the same way codex does, so a relocated config home is
/// the one written to.
export function codexConfigPath(): string {
  return join(process.env.CODEX_HOME ?? join(homedir(), ".codex"), "config.toml");
}

/// The TOML table header codex files a directory's answer under.
function projectHeader(cwd: string): string {
  const quoted = cwd.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `[projects."${quoted}"]`;
}

/// Record the workspace as trusted, unless codex already has an answer for it.
/// Answers whether this call wrote one. Never throws: a config that cannot be
/// written costs the launch its first frame, not the launch.
export function trustCodexDirectory(
  cwd: string,
  configPath: string = codexConfigPath()
): boolean {
  const header = projectHeader(cwd);
  try {
    const existing = existsSync(configPath) ? readFileSync(configPath, "utf-8") : "";
    if (existing.includes(header)) return false;
    // A new table at the end of the file, so nothing above it is reinterpreted
    // as belonging to this one, and any marker-managed block keeps its shape.
    const separator = existing === "" || existing.endsWith("\n") ? "" : "\n";
    mkdirSync(dirname(configPath), { recursive: true });
    writeFileSync(configPath, `${existing}${separator}\n${header}\ntrust_level = "trusted"\n`);
    return true;
  } catch {
    return false;
  }
}
