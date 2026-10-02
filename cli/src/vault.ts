/**
 * `kv`: secrets from the Kanban Code vault of the local master (docs/vault.md).
 *
 * The master (the Mac app or kanban-code-server) holds the secrets; kv asks
 * it over loopback for the ones a command needs. The master looks up the
 * calling process to find the card session it runs in, then decides: open
 * secrets come back at once, judged ones go past Jev, the rest wait for
 * Rogerio's approval on his phone or Mac. Values only ever reach the child
 * process environment (or stdout for `kv get`).
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { kanbanHome } from "./paths.js";

export const EXIT_DENIED = 77;

export interface VaultResponse {
  status: "granted" | "pending" | "denied";
  message: string;
  id?: string;
  values?: Record<string, string>;
  skipped?: string[];
  credentials?: AwsProcessCredentials;
  card?: string;
}

export interface AwsProcessCredentials {
  Version: number;
  AccessKeyId: string;
  SecretAccessKey: string;
  SessionToken: string;
  Expiration: string;
}

export interface VaultSecretInfo {
  name: string;
  tier: "open" | "judged" | "ask" | "never";
  rules: string;
  leasePolicy: { leaseSeconds: number; everyUseAsks: boolean };
  tags: string[];
  sources: string[];
  updatedAt: string;
  aws?: { sourceSecret: string; roleArn?: string; policyArns: string[] } | null;
}

export interface VaultAuditEntry {
  at: string;
  machine: string;
  cardId?: string;
  secret: string;
  tier?: string;
  outcome: string;
  decider: string;
  action: string;
  command?: string;
  reason?: string;
  detail?: string;
}

export class VaultCliError extends Error {
  constructor(message: string, readonly code = 1) {
    super(message);
  }
}

export interface VaultIO {
  env: NodeJS.ProcessEnv;
  fetch: typeof fetch;
  stderr: (text: string) => void;
  sleep: (ms: number) => Promise<void>;
}

export function defaultIO(): VaultIO {
  return {
    env: process.env,
    fetch: globalThis.fetch,
    stderr: (text) => process.stderr.write(text),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  };
}

// ── Talking to the master ────────────────────────────────────────────

export function vaultBaseUrl(env: NodeJS.ProcessEnv = process.env): string {
  if (env.KANBAN_VAULT_URL) return env.KANBAN_VAULT_URL.replace(/\/+$/, "");
  let port = 7780;
  try {
    const settings = JSON.parse(readFileSync(join(kanbanHome(), "settings.json"), "utf8"));
    if (typeof settings?.remoteControl?.port === "number") port = settings.remoteControl.port;
  } catch {
    // default port
  }
  return `http://127.0.0.1:${port}`;
}

export class VaultClient {
  constructor(
    readonly baseUrl: string,
    readonly io: VaultIO
  ) {}

  async call<T>(method: string, path: string, body?: unknown): Promise<{ status: number; body: T }> {
    let res: Response;
    try {
      res = await this.io.fetch(`${this.baseUrl}/v1/vault/${path}`, {
        method,
        headers: body === undefined ? {} : { "Content-Type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (error) {
      throw new VaultCliError(
        `kv: cannot reach the Kanban Code master at ${this.baseUrl} (${(error as Error).message}).\n` +
          "On the Mac the app must run with Settings > Remote Control on; on a server, kanban-code-server."
      );
    }
    const text = await res.text();
    let parsed: unknown;
    try {
      parsed = text ? JSON.parse(text) : {};
    } catch {
      throw new VaultCliError(`kv: the master answered HTTP ${res.status} with something unreadable`);
    }
    const err = (parsed as { error?: string }).error;
    if (err && res.status >= 400 && res.status !== 403) throw new VaultCliError(`kv: ${err}`);
    return { status: res.status, body: parsed as T };
  }

  /** Sends a vault request and waits out a pending approval. */
  async decide(path: string, body: unknown): Promise<VaultResponse> {
    let { body: r } = await this.call<VaultResponse>("POST", path, body);
    if (r.status !== "pending") return r;
    this.io.stderr(`kv: ${r.message}...\n`);
    const started = Date.now();
    let lastNote = started;
    while (r.status === "pending" && r.id) {
      await this.io.sleep(1500);
      r = (await this.call<VaultResponse>("GET", `pending/${encodeURIComponent(r.id)}`)).body;
      if (r.status === "pending" && Date.now() - lastNote > 60_000) {
        lastNote = Date.now();
        this.io.stderr(`kv: still waiting (${Math.round((Date.now() - started) / 60_000)} min)...\n`);
      }
    }
    if (r.status === "granted") this.io.stderr("kv: approved.\n");
    return r;
  }
}

export function callerContext(env: NodeJS.ProcessEnv): { cardId?: string; sessionId?: string; cwd: string } {
  return {
    cardId: env.KANBAN_CARD_ID || undefined,
    sessionId: env.KANBAN_SESSION_ID || env.CLAUDE_SESSION_ID || undefined,
    cwd: process.cwd(),
  };
}

export function deniedError(r: VaultResponse): VaultCliError {
  const hint = r.message.includes("kv request") ? "" : "\nIf the work needs it, ask with a reason: kv request NAME --reason \"...\"";
  return new VaultCliError(`kv: ${r.message}${hint}`, EXIT_DENIED);
}

// ── Commands and files ───────────────────────────────────────────────

/** Quotes a word for POSIX shells: safe to paste back as one argument. */
export function shellQuote(word: string): string {
  if (/^[A-Za-z0-9_\-./=:@%+,]+$/.test(word)) return word;
  return `'${word.replace(/'/g, `'\\''`)}'`;
}

export function commandLine(argv: string[]): string {
  return argv.map(shellQuote).join(" ");
}

export interface EnvVaultEntry {
  key: string;
  /** Vault secret name for `KEY={{vault:NAME}}`; undefined for a plain value. */
  secret?: string;
  value?: string;
}

/** Reads `.env.vault`: `KEY={{vault:NAME}}` lines name secrets, other `KEY=value` lines pass through. */
export function parseEnvVault(text: string): EnvVaultEntry[] {
  const out: EnvVaultEntry[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    const ref = /^\{\{\s*vault:([A-Za-z0-9_\-./:]+)\s*\}\}$/.exec(value);
    out.push(ref ? { key: m[1], secret: ref[1] } : { key: m[1], value });
  }
  return out;
}

export function envFromVault(entries: EnvVaultEntry[], values: Record<string, string>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const e of entries) {
    if (e.secret) {
      if (values[e.secret] !== undefined) env[e.key] = values[e.secret];
    } else if (e.value !== undefined) {
      env[e.key] = e.value;
    }
  }
  return env;
}

/** The nearest `.env.vault` from `dir` up to the repository root (or home). */
export function findEnvVault(dir: string, home = homedir()): string | undefined {
  let current = resolve(dir);
  for (let i = 0; i < 64; i++) {
    const candidate = join(current, ".env.vault");
    if (existsSync(candidate)) return candidate;
    if (existsSync(join(current, ".git")) || current === home) return undefined;
    const parent = dirname(current);
    if (parent === current) return undefined;
    current = parent;
  }
  return undefined;
}

export function exportLines(env: Record<string, string>): string {
  return Object.entries(env)
    .map(([k, v]) => `export ${k}=${shellQuote(v)}`)
    .join("\n");
}

/**
 * The PreToolUse hook's answer for a Bash call: when the session's project
 * has a `.env.vault`, the command first loads the vault env into its own
 * shell, so `cd` and shell syntax keep working as written.
 */
/**
 * The PreToolUse answer that makes a Bash command load the vault env first.
 * Codex applies `updatedInput` only next to `permissionDecision: "allow"`,
 * which there does not skip its own approval or sandbox; Claude Code takes
 * `updatedInput` alone, where "allow" would skip the permission prompt.
 */
export function hookRewrite(
  input: { tool_name?: string; tool_input?: { command?: string }; cwd?: string },
  kvPath: string,
  harness: "claude" | "codex" = "claude"
): unknown {
  if (input.tool_name !== "Bash") return undefined;
  const command = input.tool_input?.command;
  if (!command || command.includes("__kv_env=")) return undefined;
  const file = findEnvVault(input.cwd || process.cwd());
  if (!file) return undefined;
  const b64 = Buffer.from(command, "utf8").toString("base64");
  const wrapped =
    `__kv_env="$(${shellQuote(kvPath)} env ${shellQuote(file)} --export --command-b64 ${b64})" || exit $?\n` +
    `eval "$__kv_env"; unset __kv_env\n` +
    command;
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      ...(harness === "codex" ? { permissionDecision: "allow" } : {}),
      updatedInput: { ...input.tool_input, command: wrapped },
    },
  };
}

function parentCommand(): string | undefined {
  const r = spawnSync("ps", ["-o", "args=", "-p", String(process.ppid)], { encoding: "utf8" });
  return r.status === 0 ? r.stdout.trim() || undefined : undefined;
}

function readStdin(): Promise<string> {
  return new Promise((resolveText) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolveText(data));
  });
}

async function readSecretFromStdin(name: string): Promise<string> {
  if (!process.stdin.isTTY) return (await readStdin()).replace(/\r?\n$/, "");
  process.stderr.write(`Value for ${name} (not shown): `);
  return new Promise((resolveValue) => {
    const stdin = process.stdin;
    stdin.setRawMode(true);
    stdin.resume();
    stdin.setEncoding("utf8");
    let value = "";
    const onData = (ch: string) => {
      for (const c of ch) {
        if (c === "\r" || c === "\n" || c === "\u0004") {
          stdin.setRawMode(false);
          stdin.pause();
          stdin.off("data", onData);
          process.stderr.write("\n");
          resolveValue(value);
          return;
        }
        if (c === "\u0003") process.exit(130);
        if (c === "\u007f") value = value.slice(0, -1);
        else value += c;
      }
    };
    stdin.on("data", onData);
  });
}

function runChild(argv: string[], extraEnv: Record<string, string>): Promise<number> {
  if (argv.length === 0) throw new VaultCliError("kv: give the command after --");
  return new Promise((resolveCode) => {
    const child = spawn(argv[0], argv.slice(1), { stdio: "inherit", env: { ...process.env, ...extraEnv } });
    for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
      process.on(sig, () => child.kill(sig));
    }
    child.on("error", (e) => {
      process.stderr.write(`kv: could not run ${argv[0]}: ${e.message}\n`);
      resolveCode(127);
    });
    child.on("exit", (code, signal) => resolveCode(code ?? (signal ? 128 + 15 : 1)));
  });
}

function splitAtDashes(args: string[]): { before: string[]; after: string[] } {
  const i = args.indexOf("--");
  return i < 0 ? { before: args, after: [] } : { before: args.slice(0, i), after: args.slice(i + 1) };
}

function takeOption(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const value = args[i + 1];
  args.splice(i, 2);
  return value;
}

function takeFlag(args: string[], name: string): boolean {
  const i = args.indexOf(name);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
}

function takeAll(args: string[], name: string): string[] {
  const out: string[] = [];
  for (let v = takeOption(args, name); v !== undefined; v = takeOption(args, name)) out.push(v);
  return out;
}

export const USAGE = `kv: secrets from the Kanban Code vault

  kv run NAME [NAME..] [--reason "..."] -- <cmd> [args..]   run cmd with the secrets in its env
  kv env <.env.vault> [--reason "..."] -- <cmd> [args..]    same, names from KEY={{vault:NAME}} lines
  kv get NAME                                               print one secret (never one that asks)
  kv request NAME[:scope] [NAME..] --reason "..."           ask once for the card's whole task (2 days)
  kv aws <profile>                                          AWS credential_process JSON (1 h STS credentials)
  kv add NAME [--tier open|judged|ask|never] [--rules "..."] [--tag t]   value from stdin
  kv ls [--json]                                            names, tiers and rules
  kv log [--card ID] [--secret NAME] [--limit N] [--json]   the audit log, newest first
  kv leases [--card ID]                                     active card leases
  kv tier NAME <tier> | kv rules NAME "..."                 change a secret (asks Rogerio)
  kv status                                                 is the vault unlocked here
  kv import [--apply] [--secrets-only] [--only <dir>]..   plan (then do) the migration of plaintext secrets

Exit code ${EXIT_DENIED} means the vault denied the request.`;

export async function runKv(argv: string[], io: VaultIO = defaultIO()): Promise<number> {
  const [cmd, ...rest] = argv;
  const args = [...rest];
  const client = new VaultClient(vaultBaseUrl(io.env), io);
  const ctx = callerContext(io.env);
  const out = (text: string) => process.stdout.write(text);

  switch (cmd) {
    case undefined:
    case "-h":
    case "--help":
    case "help":
      out(USAGE + "\n");
      return 0;

    case "run": {
      const { before, after } = splitAtDashes(args);
      const reason = takeOption(before, "--reason");
      if (before.length === 0) throw new VaultCliError("kv run NAME [NAME..] -- <cmd>");
      const r = await client.decide("release", { mode: "run", names: before, command: commandLine(after), reason, ...ctx });
      if (r.status !== "granted") throw deniedError(r);
      return runChild(after, r.values ?? {});
    }

    case "env": {
      const { before, after } = splitAtDashes(args);
      const reason = takeOption(before, "--reason");
      const exportMode = takeFlag(before, "--export");
      const b64 = takeOption(before, "--command-b64");
      const file = before[0];
      if (!file) throw new VaultCliError("kv env <.env.vault> -- <cmd>");
      if (!existsSync(file)) throw new VaultCliError(`kv: no file ${file}`);
      const entries = parseEnvVault(readFileSync(file, "utf8"));
      const names = [...new Set(entries.filter((e) => e.secret).map((e) => e.secret!))];
      const command = b64 ? Buffer.from(b64, "base64").toString("utf8") : commandLine(after);
      let values: Record<string, string> = {};
      if (names.length > 0) {
        let r: VaultResponse;
        try {
          r = await client.decide("release", { mode: exportMode ? "hook" : "env", names, command, reason, ...ctx });
        } catch (error) {
          // A wrapped command still runs when the master is down: it just gets no vault env.
          if (!exportMode) throw error;
          io.stderr(`${(error as Error).message.split("\n")[0]} (running without the vault env)\n`);
          return 0;
        }
        if (r.status !== "granted") throw deniedError(r);
        values = r.values ?? {};
        const skippedKeys = entries.filter((e) => e.secret && r.skipped?.includes(e.secret)).map((e) => e.key);
        const mentioned = skippedKeys.filter((k) => command.includes(k));
        if (!exportMode && skippedKeys.length) io.stderr(`kv: ${r.message}\n`);
        else if (mentioned.length) {
          io.stderr(`kv: ${mentioned.join(", ")} need approval and were left out: kv request ${mentioned.map((k) => entries.find((e) => e.key === k)!.secret).join(" ")} --reason "..."\n`);
        }
      }
      const env = envFromVault(entries, values);
      if (exportMode) {
        out(exportLines(env) + "\n");
        return 0;
      }
      return runChild(after, env);
    }

    case "get": {
      const name = args[0];
      if (!name) throw new VaultCliError("kv get NAME");
      const r = await client.decide("release", { mode: "get", names: [name], command: parentCommand(), ...ctx });
      if (r.status !== "granted") throw deniedError(r);
      out((r.values ?? {})[name] ?? "");
      if (process.stdout.isTTY) out("\n");
      return 0;
    }

    case "request": {
      const reason = takeOption(args, "--reason");
      if (!reason || args.length === 0) throw new VaultCliError('kv request NAME[:scope] [NAME..] --reason "one sentence"');
      const r = await client.decide("request", { names: args, reason, ...ctx });
      if (r.status !== "granted") throw deniedError(r);
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "aws": {
      const profile = args[0];
      if (!profile) throw new VaultCliError("kv aws <profile>");
      const r = await client.decide("aws", { mode: "aws", names: [profile], command: parentCommand(), ...ctx });
      if (r.status !== "granted" || !r.credentials) throw deniedError(r);
      out(JSON.stringify(r.credentials) + "\n");
      return 0;
    }

    case "add": {
      const tier = takeOption(args, "--tier");
      const rules = takeOption(args, "--rules");
      const tags = takeAll(args, "--tag");
      const name = args[0];
      if (!name) throw new VaultCliError("kv add NAME [--tier t] [--rules '...']  (value on stdin)");
      const value = await readSecretFromStdin(name);
      if (!value) throw new VaultCliError("kv: empty value, nothing added");
      const { body } = await client.call<VaultResponse>("POST", `secrets${ctx.cardId ? `?card=${ctx.cardId}` : ""}`, {
        name,
        value,
        tier,
        rules,
        tags: tags.length ? tags : undefined,
      });
      const r = body.status === "pending" ? await waitPending(client, body) : body;
      if (r.status !== "granted") throw deniedError(r);
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "tier":
    case "rules": {
      const [name, value] = args;
      if (!name || value === undefined) throw new VaultCliError(`kv ${cmd} NAME <value>`);
      const patch = cmd === "tier" ? { tier: value } : { rules: value };
      const { body } = await client.call<VaultResponse>("PATCH", `secrets/${encodeURIComponent(name)}`, patch);
      const r = body.status === "pending" ? await waitPending(client, body) : body;
      if (r.status !== "granted") throw deniedError(r);
      io.stderr(`kv: ${r.message}\n`);
      return 0;
    }

    case "ls": {
      const json = takeFlag(args, "--json");
      const { body } = await client.call<VaultSecretInfo[]>("GET", "secrets");
      if (json) {
        out(JSON.stringify(body, null, 2) + "\n");
        return 0;
      }
      const width = Math.max(4, ...body.map((s) => s.name.length));
      for (const s of body) {
        const lease = s.leasePolicy.everyUseAsks ? " every use asks" : "";
        out(`${s.name.padEnd(width)}  ${s.tier.padEnd(6)}${lease}${s.rules ? `  ${s.rules.slice(0, 80)}` : ""}\n`);
      }
      return 0;
    }

    case "log": {
      const json = takeFlag(args, "--json");
      const q = new URLSearchParams();
      const card = takeOption(args, "--card");
      const secret = takeOption(args, "--secret");
      q.set("limit", takeOption(args, "--limit") ?? "50");
      if (card) q.set("card", card);
      if (secret) q.set("secret", secret);
      const { body } = await client.call<VaultAuditEntry[]>("GET", `log?${q}`);
      if (json) {
        out(JSON.stringify(body, null, 2) + "\n");
        return 0;
      }
      for (const e of body) {
        out(
          `${e.at.slice(0, 19)}  ${e.outcome.padEnd(7)} ${e.decider.padEnd(7)} ${e.action.padEnd(6)} ${e.secret}` +
            `${e.cardId ? `  card ${e.cardId}` : ""}${e.detail ? `  (${e.detail})` : ""}\n`
        );
      }
      return 0;
    }

    case "leases": {
      const card = takeOption(args, "--card");
      const { body } = await client.call<Array<{ cardId: string; secret: string; expiresAt: string; reason?: string }>>(
        "GET",
        `leases${card ? `?card=${card}` : ""}`
      );
      for (const l of body) out(`${l.secret}  card ${l.cardId}  until ${l.expiresAt.slice(0, 16)}${l.reason ? `  ${l.reason}` : ""}\n`);
      return 0;
    }

    case "status": {
      const { body } = await client.call<{ unlocked: boolean; recipient?: string; secrets: number; machine: string }>("GET", "status");
      out(`${body.machine}: ${body.unlocked ? "unlocked" : "LOCKED (no vault key on this machine)"}, ${body.secrets} secrets\n`);
      return 0;
    }

    case "hook": {
      const input = JSON.parse((await readStdin()) || "{}");
      const kvPath = io.env.KV_PATH || join(homedir(), ".local/bin/kv");
      const answer = hookRewrite(input, kvPath, args.includes("--codex") ? "codex" : "claude");
      if (answer) out(JSON.stringify(answer) + "\n");
      return 0;
    }

    case "import": {
      const { runImport } = await import("./vault-import.js");
      return runImport(args, client, io);
    }

    default:
      throw new VaultCliError(`kv: unknown command ${cmd}\n\n${USAGE}`);
  }
}

async function waitPending(client: VaultClient, first: VaultResponse): Promise<VaultResponse> {
  client.io.stderr(`kv: ${first.message}...\n`);
  let r = first;
  while (r.status === "pending" && r.id) {
    await client.io.sleep(1500);
    r = (await client.call<VaultResponse>("GET", `pending/${encodeURIComponent(r.id)}`)).body;
  }
  return r;
}

export function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}
