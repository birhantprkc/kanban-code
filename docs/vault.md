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

"Inside a card session" is checked by the master, not claimed by the client. kv calls the local master over loopback; the master finds the calling process from the TCP connection (`lsof` on macOS, `/proc/net/tcp` on Linux), walks its parents, and matches them against the pane shells of the cards' tmux sessions and the assistant processes agtop hosts for cards. `KANBAN_CARD_ID` is only shown to the human when it could not be verified. Requests over the network are never inside a card.

Human approvals are attention requests of kind `vaultApproval` with the options "Approve for this card (2 days)", "Approve once", "Deny". A secret with "every use asks" never offers the lease. No answer in 10 minutes denies.

## kv

`kv` talks to `http://127.0.0.1:<remote control port>` (`KANBAN_VAULT_URL` overrides it). It needs no token. Exit code 77 means denied.

```
kv run NAME [NAME..] [--reason "..."] -- <cmd> [args..]
kv env .env.vault -- <cmd> [args..]
kv get NAME
kv request NAME[:scope] [NAME..] --reason "..."
kv aws <profile>
kv add NAME [--tier t] [--rules "..."]      value on stdin
kv ls | kv log | kv leases | kv status
kv tier NAME <tier> | kv rules NAME "..."   asks Rogerio
kv import [--apply]
```

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

Kanban Code installs a Claude Code `PreToolUse` hook on Bash (`~/.kanban-code/vault-hook.sh`). In a project with a `.env.vault` (searched from the session's directory up to the repository root), `kv hook` rewrites the command to:

```
__kv_env="$(kv env /path/.env.vault --export --command-b64 <command>)" || exit $?
eval "$__kv_env"; unset __kv_env
<the original command>
```

so the shell loads the secrets first and `cd` and shell syntax behave as written. In this mode secrets that need a human are skipped (the command runs without them and kv says how to ask), Jev's allow is reused for 10 minutes per card and secret, and these releases do not count toward the rate limit. If the master cannot be reached, the command runs without the vault env.

## Remote API

See the routes list in `Sources/KanbanCodeCore/Adapters/RemoteControl/RemoteVaultRoutes.swift`. Listings never carry values. Adding a new secret is allowed to any local caller; replacing a value, changing a tier or rules, or deleting asks Rogerio, except from Settings > Vault in the app.
