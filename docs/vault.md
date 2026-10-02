# Vault

The vault keeps secrets out of plaintext files. Every master (the Mac app and `kanban-code-server`) runs it; the box is its home and the Mac keeps a replica.

## Storage

`~/.kanban-code/vault/` on each master:

| File | Content |
|------|---------|
| `vault.age` | All secrets, age-encrypted to the vault key, with an HMAC keyed from the same key so only key holders can write a replica |
| `leases.json` | Card leases: card, secret, expiry. No values |
| `audit.jsonl` | Append-only log of this machine: time, card, secret, tier, outcome, decider, command |

The key is an age X25519 identity. On the box it is `vault/identity.txt` (0600, root). On the Mac it is the login keychain item `io.kanbancode.vault` / `age-identity`, readable without a prompt only by the signed app. To give a machine the key, write it to `~/.kanban-code/vault/identity.import`; the master imports it at start and deletes the file.

Recovery without Kanban Code: `age -d -i identity.txt vault.age` gives `{"doc": <base64 JSON>, "auth": ...}`; the `doc` field is the secrets.

Replicas sync with the configured peers every minute (`GET`/`POST /v1/vault/replica`, full-scope peer token). Each secret's newest edit wins; a delete is an edit.

## Tiers and decisions

| Tier | Release |
|------|---------|
| open | Any card session, logged |
| judged | Jev reads the command, the reason, the card title and the secret's rules: allow, ask or deny |
| ask | Rogerio approves on the Mac or the phone |
| never | Refused |

Order, first match wins:

1. Tier never: deny.
2. The caller is not inside a card session: ask, whatever the tier.
3. More than 20 releases of the secret in 5 minutes: ask.
4. The card holds a lease and the secret allows leases: allow.
5. Open: allow. Judged: Jev (allow needs at least 60% probability; Jev unreachable asks). Ask: the human.

"Inside a card session" is checked by the master, not claimed by the client. kv calls the local master over loopback; the master finds the calling process from the TCP connection (`lsof` on macOS, `/proc/net/tcp` on Linux), walks its parents, and matches them against the pane shells of the cards' tmux sessions and the assistant processes agtop hosts for cards. An agtop or rush host belongs to the card whose terminal is `agtop-<host id>` in Kanban's links, never to the card its own `--meta kanban_card` names (a meta naming another card disowns it), and only when the master can show it started the host: it records the host pid and process start time whenever it starts or restarts one (`~/.kanban-code/agtop-hosts.json`), or the host's parents reach the master or a terminal pane of that card. A host started elsewhere (a rush view in another terminal, a script resuming a card's session id) is outside every card. The first run on a machine adopts the hosts its cards already run. `KANBAN_CARD_ID` is only shown to the human when it could not be verified. Requests over the network are never inside a card.

OpenClaw agents on a Linux master count like card sessions under the principal `openclaw:<agent>`: the master finds, in the caller's ancestry, a process whose cgroup is the gateway's systemd unit (`openclaw-gateway.service`, set by systemd, not by the process), then the topmost process below the gateway whose working directory is an agent workspace from `~/.openclaw/openclaw.json` (the agent runtime the gateway started; a child that changes directory does not change it). The gateway itself, resolving SecretRefs, is `openclaw:gateway`. Each principal holds its own leases. Commands an agent starts outside the unit (`systemd-run`, cron) are outside, so they ask.

Human approvals are attention requests of kind `vaultApproval` with the options "Approve for this card (2 days)", "Approve once", "Deny". A secret with "every use asks" never offers the lease. No answer in 10 minutes denies.

### What the human sees

The notification (Mac, Pushover, the phone app) has two lines:

- Title: who wants what, e.g. "Kanban Chat Claude wants AWS lw-dev access", "... wants to use the Slack user token", "... wants to change the AWS lw-dev rules", "... wants to use the Slack user token for 2 days" (a lease). Outside a card it reads "A process outside any card wants ...".
- Body: the agent's `--reason` and nothing else. A missing reason, or one that reads like a command or has under four words, shows "No reason given." instead.

Secrets are named by their label: the `label` field when set (`kv label NAME "..."`, `kv add --label`), else one derived from the name (`aws:lw-dev` is "AWS lw-dev", `aws:lw-prod:read` is "AWS lw-prod read-only", `SLACK_USER_TOKEN` is "Slack user token").

Clicking the Mac notification opens the card and a sheet with every detail; on the phone the request's Details page shows the same. The details are the `vault` field of the attention request (`VaultApprovalDetails` in KanbanCodeRemoteKit): card, secrets with tier, the action, the proposed values of an edit, why the vault asks (tier, rate limit, Jev's verdict), the command, the working directory, the reason, the lease the card approval grants, and the process ancestry. `AttentionCopy` builds the title and body; questions and plan approvals use the same title style ("<card> is asking you a question", "<card> wants you to approve a plan", "<card> needs your permission").

### Reasons

The reason is the only text the human reads before deciding, so it must be one short plain sentence saying what the agent wants to do and why, e.g. `--reason "Deploy the langwatch staging app to check the fix for the login bug"`. kv refuses (exit 2, before asking the master) a reason that is missing where required (`kv request`), shorter than four words, longer than one sentence (200 characters or a newline), or that reads like a command (starts with a command name, has flags or shell operators). `--reason` is optional for `kv run`, `env`, `get`, `aws`, `add`, `tier`, `rules`, `label`; `KV_REASON` in the environment stands in for it, which is how `kv aws` from `credential_process` gets one. When a request reaches the human without a usable reason, the pending message tells the agent how to write one next time.

## kv

`kv` talks to `http://127.0.0.1:<remote control port>` (`KANBAN_VAULT_URL` overrides it). It needs no token. Exit code 77 means denied.

```
kv run NAME [NAME..] [--reason "..."] -- <cmd> [args..]
kv env .env.vault -- <cmd> [args..]
kv get NAME [--reason "..."]
kv request NAME[:scope] [NAME..] --reason "..."
kv aws <profile> [--reason "..."]
kv add NAME [--tier t] [--rules "..."] [--label "..."] [--reason "..."]   value on stdin
kv ls | kv log | kv leases | kv status   (status also says who the master takes you for)
kv tier NAME <tier> [--every-use-asks|--leases] | kv rules NAME "..." | kv label NAME "..."  [--reason "..."]   asks Rogerio
kv import [--apply]
kv exec-provider                             OpenClaw exec SecretRef provider
```

`kv exec-provider` speaks OpenClaw's exec provider protocol (`{"protocolVersion":1,"ids":[...]}` on stdin, `{"values":{...},"errors":{...}}` on stdout); each id is a vault secret name. It never waits on a human: a secret that needs approval comes back as `NEEDS_APPROVAL` and its request stays open for the next `openclaw secrets reload`.

`.env.vault` holds names only: `KEY={{vault:NAME}}`. Lines with plain values pass through.

### AWS

AWS profiles are vault entries named `aws:<profile>` that carry a role (`roleArn`, optional session policies) and the name of the long-lived key secret (tier never, value `{"accessKeyId","secretAccessKey"}`). `kv aws <profile>` makes the master call STS AssumeRole (or GetSessionToken without a role) for one hour and prints the `credential_process` JSON. Use it from `~/.aws/config`:

```
[profile lw-dev-vault]
credential_process = /Users/<you>/.local/bin/kv aws lw-dev
region = eu-central-1
```

`aws:lw-prod:read` adds the ReadOnlyAccess session policy to the prod role.

## Bash hook

Kanban Code installs a `PreToolUse` hook on Bash (`~/.kanban-code/vault-hook.sh`) for Claude Code (`~/.claude/settings.json`) and for Codex (`~/.codex/hooks.json`, run as `vault-hook.sh --codex`). Codex runs a user hook only once its definition is trusted, so the installer also writes `[hooks.state."<hooks.json>:pre_tool_use:<n>:0"] trusted_hash` into `~/.codex/config.toml` with the hash Codex computes; Codex answers carry `permissionDecision: "allow"`, which Codex needs next to `updatedInput` and which does not skip its approvals or sandbox. Under Codex's `workspace-write` sandbox kv cannot reach the master on loopback, so commands run without the vault env; card sessions run Codex without the sandbox. rush sessions run `claude -p`, which loads the same Claude Code hook. In a project with a `.env.vault` (searched from the session's directory up to the repository root), `kv hook` rewrites the command to:

```
__kv_env="$(kv env /path/.env.vault --export --command-b64 <command>)" || exit $?
eval "$__kv_env"; unset __kv_env
<the original command>
```

so the shell loads the secrets first and `cd` and shell syntax behave as written. In this mode secrets that need a human are skipped (the command runs without them and kv says how to ask), Jev's allow is reused for 10 minutes per card and secret, and these releases do not count toward the rate limit. If the master cannot be reached, the command runs without the vault env.

## Pasted secrets

The card chat composer, the queued prompt editor, channel composers and the iPhone composer check a prompt before sending it (`SecretDetector` in KanbanCodeRemoteKit, a port of LangWatch's redaction rules). When it holds a credential they offer to save it: one editable name per secret, taken from `NAME=value` / `NAME: value` / `"NAME": "value"` or the vendor (`OPENAI_API_KEY`, `GITHUB_TOKEN`...), with `_2`, `_3` when the vault already has that name. Yes adds each as a judged secret and sends the prompt with `{{vault:NAME}}` in its place plus a line telling the agent to use `kv run NAME -- <cmd>`; No sends it unchanged. On the Mac, Return or y is Yes, Esc or n is No. Placeholders (`sk-xxxx...`, `<your-key>`, AWS's `...EXAMPLE`) never ask.

## Remote API

See the routes list in `Sources/KanbanCodeCore/Adapters/RemoteControl/RemoteVaultRoutes.swift`. Listings never carry values. Adding a new secret is allowed to any local caller; replacing a value, changing a tier or rules, or deleting asks Rogerio, except from Settings > Vault in the app.
