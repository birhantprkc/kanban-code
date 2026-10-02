import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  EXIT_DENIED,
  VaultClient,
  envFromVault,
  findEnvVault,
  hookRewrite,
  execProviderAnswer,
  parseEnvVault,
  runKv,
  shellQuote,
  type VaultIO,
} from "./vault.js";
import { envVaultFor, isSecret, planAws, planSecrets, renderPlan, tierFor } from "./vault-import.js";

test("parses .env.vault references and plain values", () => {
  const entries = parseEnvVault(`# comment\nOPENAI_API_KEY={{vault:OPENAI_API_KEY}}\nexport DB={{ vault:DB_URL }}\nPORT=3000\nNAME="a b"\n`);
  assert.deepEqual(entries, [
    { key: "OPENAI_API_KEY", secret: "OPENAI_API_KEY" },
    { key: "DB", secret: "DB_URL" },
    { key: "PORT", value: "3000" },
    { key: "NAME", value: "a b" },
  ]);
  assert.deepEqual(envFromVault(entries, { OPENAI_API_KEY: "v1" }), { OPENAI_API_KEY: "v1", PORT: "3000", NAME: "a b" });
});

test("shell quoting survives quotes", () => {
  assert.equal(shellQuote("plain-word"), "plain-word");
  assert.equal(shellQuote("it's"), `'it'\\''s'`);
  assert.equal(shellQuote("a b"), "'a b'");
});

test("the hook wraps Bash commands only in projects with .env.vault", () => {
  const root = mkdtempSync(join(tmpdir(), "kv-hook-"));
  mkdirSync(join(root, "repo/.git"), { recursive: true });
  mkdirSync(join(root, "repo/sub"), { recursive: true });
  mkdirSync(join(root, "other/.git"), { recursive: true });
  writeFileSync(join(root, "repo/.env.vault"), "A={{vault:A}}\n");
  assert.equal(findEnvVault(join(root, "repo/sub"), root), join(root, "repo/.env.vault"));
  assert.equal(findEnvVault(join(root, "other"), root), undefined);

  const out = hookRewrite({ tool_name: "Bash", tool_input: { command: "cd x && pnpm test" }, cwd: join(root, "repo/sub") }, "/bin/kv") as {
    hookSpecificOutput: { updatedInput: { command: string } };
  };
  const cmd = out.hookSpecificOutput.updatedInput.command;
  assert.match(cmd, /env .*\.env\.vault --export --command-b64 /);
  assert.ok(cmd.endsWith("\ncd x && pnpm test"));
  assert.equal(hookRewrite({ tool_name: "Bash", tool_input: { command: cmd }, cwd: join(root, "repo") }, "/bin/kv"), undefined);
  assert.equal(hookRewrite({ tool_name: "Read", tool_input: {}, cwd: join(root, "repo") }, "/bin/kv"), undefined);
  assert.equal(hookRewrite({ tool_name: "Bash", tool_input: { command: "ls" }, cwd: join(root, "other") }, "/bin/kv"), undefined);
});

test("the hook answers Codex with permissionDecision allow and Claude Code without it", () => {
  const root = mkdtempSync(join(tmpdir(), "kv-hook-"));
  mkdirSync(join(root, "repo/.git"), { recursive: true });
  writeFileSync(join(root, "repo/.env.vault"), "A={{vault:A}}\n");
  const input = { tool_name: "Bash", tool_input: { command: "pnpm test" }, cwd: join(root, "repo") };
  type Out = { hookSpecificOutput: { permissionDecision?: string; updatedInput: { command: string } } };
  const claude = hookRewrite(input, "/bin/kv") as Out;
  const codex = hookRewrite(input, "/bin/kv", "codex") as Out;
  assert.equal(claude.hookSpecificOutput.permissionDecision, undefined);
  assert.equal(codex.hookSpecificOutput.permissionDecision, "allow");
  assert.equal(codex.hookSpecificOutput.updatedInput.command, claude.hookSpecificOutput.updatedInput.command);
});

async function fakeMaster(handler: (method: string, path: string, body: any) => { status: number; body: unknown }) {
  const calls: { method: string; path: string; body: any }[] = [];
  const server = createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      const body = data ? JSON.parse(data) : undefined;
      calls.push({ method: req.method!, path: req.url!, body });
      const r = handler(req.method!, req.url!, body);
      res.writeHead(r.status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(r.body));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { url, calls, close: () => server.close() };
}

function io(url: string, notes: string[]): VaultIO {
  return { env: { KANBAN_VAULT_URL: url, KANBAN_CARD_ID: "card_x" }, fetch, stderr: (t) => notes.push(t), sleep: async () => {} };
}

test("a pending release waits for the approval and says so", async () => {
  let polls = 0;
  const m = await fakeMaster((method, path) => {
    if (path === "/v1/vault/release") return { status: 202, body: { status: "pending", id: "vault_1", message: "Waiting for Rogerio's approval on his phone or Mac (card X)" } };
    polls++;
    return polls < 3
      ? { status: 202, body: { status: "pending", id: "vault_1", message: "still waiting" } }
      : { status: 200, body: { status: "granted", message: "released", values: { A: "1" } } };
  });
  const notes: string[] = [];
  const r = await new VaultClient(m.url, io(m.url, notes)).decide("release", { mode: "run", names: ["A"] });
  m.close();
  assert.equal(r.status, "granted");
  assert.deepEqual(r.values, { A: "1" });
  assert.match(notes.join(""), /Waiting for Rogerio's approval/);
});

test("a denial exits with the denied code and a hint", async () => {
  const m = await fakeMaster(() => ({ status: 403, body: { status: "denied", message: "Rogerio denied it." } }));
  await assert.rejects(runKv(["run", "A", "--", "true"], io(m.url, [])), (e: any) => {
    assert.equal(e.code, EXIT_DENIED);
    assert.match(e.message, /kv request NAME --reason/);
    return true;
  });
  m.close();
});

test("kv run passes the command line for Jev", async () => {
  const m = await fakeMaster(() => ({ status: 200, body: { status: "granted", message: "released", values: { A: "v" } } }));
  const code = await runKv(["run", "A", "--reason", "check", "--", "sh", "-c", 'test "$A" = v'], io(m.url, []));
  m.close();
  assert.equal(code, 0);
  assert.equal(m.calls[0].body.command, `sh -c 'test "$A" = v'`);
  assert.equal(m.calls[0].body.reason, "check");
});

test("import finds secrets, skips config and placeholders", () => {
  assert.ok(isSecret("OPENAI_API_KEY", "sk-proj-abcdefghijklmnopqrstuvwxyz0123"));
  assert.ok(isSecret("DATABASE_URL", "postgres://user:pa55word@db.example.com:5432/app"));
  assert.ok(!isSecret("DATABASE_URL", "postgres://localhost:5432/app"));
  assert.ok(!isSecret("PORT", "3000"));
  assert.ok(!isSecret("OPENAI_API_KEY", "your-key-here"));
  assert.ok(!isSecret("API_KEY", "changeme"));
  assert.ok(!isSecret("NODE_ENV", "development"));
  assert.equal(tierFor("OPENAI_API_KEY", "sk-proj-x").tier, "open");
  assert.equal(tierFor("CLOUDFLARE_API_TOKEN", "abc").tier, "judged");
  assert.equal(tierFor("STRIPE_SECRET_KEY", "sk_live_abc").tier, "ask");
  assert.equal(tierFor("KANBAN_TOKEN", "kc_abc").tier, "never");
});

test("import dedupes by value and never writes values into the plan", () => {
  const plans = planSecrets(
    [
      { key: "OPENAI_API_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/a/.env" },
      { key: "OPENAI_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/b/.env" },
      { key: "OPENAI_API_KEY", value: "sk-proj-value-one-aaaaaaaaaaaa", file: "/h/Projects/c/.env" },
      { key: "OPENAI_API_KEY", value: "sk-proj-value-two-bbbbbbbbbbbb", file: "/h/Projects/d/.env" },
    ],
    "/h"
  );
  assert.deepEqual(plans.map((p) => p.name), ["OPENAI_API_KEY", "OPENAI_API_KEY__D"]);
  assert.equal(plans[0].sources.length, 3);
  const md = renderPlan(plans, ["/h/Projects/a/.env"], "/h");
  assert.ok(!md.includes("sk-proj-value"));
  assert.match(md, /`OPENAI_API_KEY`: ~\/Projects\/a\/.env OPENAI_API_KEY/);
});

test("import plans AWS profiles with read leases for prod", () => {
  const plans = planAws(
    `[root]\naws_access_key_id = AKIAEXAMPLE\naws_secret_access_key = s3cr3t\n\n[lw-prod]\nsource_profile = root\nrole_arn = arn:aws:iam::1:role/R\n\n[lw-dev]\nsource_profile = root\nrole_arn = arn:aws:iam::2:role/R\n`,
    "/h"
  );
  const byName = Object.fromEntries(plans.map((p) => [p.name, p]));
  assert.equal(byName["AWS_KEY_ROOT"].tier, "never");
  assert.equal(byName["aws:lw-dev"].tier, "judged");
  assert.equal(byName["aws:lw-prod:read"].tier, "ask");
  assert.deepEqual(byName["aws:lw-prod:read"].aws?.policyArns, ["arn:aws:iam::aws:policy/ReadOnlyAccess"]);
  assert.equal(byName["aws:lw-prod"].everyUseAsks, true);
});

test(".env.vault keeps names and plain config only", () => {
  const out = envVaultFor("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz\nPORT=3000\nWEIRD=Zx9kLmQ2vB7nR4tY8uW1eA3sD6fG\n", new Map([["OPENAI_API_KEY", "OPENAI_API_KEY"]]));
  assert.match(out, /OPENAI_API_KEY=\{\{vault:OPENAI_API_KEY\}\}/);
  assert.match(out, /PORT=3000/);
  assert.ok(!out.includes("sk-proj"));
  assert.ok(!out.includes("Zx9kLmQ2"));
});

test("the exec provider answers OpenClaw's protocol without waiting on a human", async () => {
  const m = await fakeMaster((_method, _path, body) => {
    const name = body.names[0];
    if (name === "OPEN") return { status: 200, body: { status: "granted", message: "released", values: { OPEN: "v1" } } };
    if (name === "ASK") return { status: 202, body: { status: "pending", id: "vault_1", message: "Waiting" } };
    return { status: 403, body: { status: "denied", message: `no secret named ${name} in the vault` } };
  });
  const client = new VaultClient(m.url, io(m.url, []));
  const answer = await execProviderAnswer(client, { protocolVersion: 1, provider: "kv", ids: ["OPEN", "ASK", "GONE"] }, { cwd: "/" });
  m.close();
  assert.deepEqual(answer, {
    protocolVersion: 1,
    values: { OPEN: "v1" },
    errors: { ASK: { code: "NEEDS_APPROVAL" }, GONE: { code: "NOT_FOUND" } },
  });
  assert.equal(m.calls.length, 3);
  assert.equal(m.calls[0].body.mode, "get");
});
