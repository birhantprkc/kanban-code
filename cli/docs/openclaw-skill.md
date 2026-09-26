---
name: kanban-remote
description: Start and follow coding tasks on the user's Mac through Kanban Code with the `kanban remote` CLI. Use when the user asks for code to be written, fixed, reviewed or run in one of their projects, when they ask what their coding agents on the Mac are doing, or when a running coding task needs a follow-up instruction.
---

# kanban remote

Coding work runs on the user's Mac, inside Kanban Code, not on this machine. Each task is a card on the Kanban Code board with its own Claude Code (or Codex) session. This machine reaches the Mac over Tailscale with the `kanban remote` CLI.

## When to use

- The user asks for a change, a fix, a review or an investigation in one of their code projects.
- The user asks what is running on the Mac, or how a task went.
- A task you started needs another instruction, a correction or a stop.

## Setup, once

The user pairs this machine on the Mac with `kanban remote pair --name openclaw --scope agent` and gives you the token. Then:

```bash
kanban remote login http://<mac>.<tailnet>.ts.net:7780 --token kc_...
kanban remote whoami
```

The login is saved in `~/.kanban-code/remote-client.json`. `KANBAN_REMOTE_URL` and `KANBAN_REMOTE_TOKEN` override it.

## Start a task

```bash
kanban remote projects                       # names accepted by --project
kanban remote task --project langwatch --worktree --name "Fix flaky login test" \
  "The test 'login redirects after sign-in' in langwatch/app fails about 1 run in 5 on CI. Find the cause, fix it, run the test 20 times to confirm, and open a PR."
```

- Use `--worktree` for every task that changes code, so it runs on its own branch and does not touch the user's checkout. `--worktree <name>` picks the branch name.
- Long prompts: pipe them in with `-`: `cat prompt.md | kanban remote task --project langwatch --worktree -`.
- The command prints the card id. Keep it for the next steps.

Tasks run on the Mac with the permissions the Kanban Code app gives its sessions, often with permission prompts skipped. Describe each task precisely: the project, the goal, what done looks like (tests passing, a PR opened), and anything that must not be touched. Do not start a task you would not let the user's own agent run unattended.

## Follow a task

```bash
kanban remote transcript <card> --follow     # prints new messages until the turn ends
kanban remote wait <card> --timeout 30m      # or block silently, exit 0 when idle, 124 on timeout
kanban remote transcript <card> --limit 5    # the last messages, for the result
kanban remote show <card>                    # branch, worktree, PRs
```

`<card>` is the id, a unique prefix of it, or the exact card title.

## Steer a task

```bash
kanban remote send <card> "Also update the changelog."   # delivered when the current turn ends
kanban remote send <card> --now "Stop, that is the wrong file. Only edit app/login.ts."
kanban remote interrupt <card>                           # stop the current turn
kanban remote resume <card>                              # restart a stopped session
```

`send` on a stopped card fails with 409: run `resume` first.

## Check status

```bash
kanban remote cards                          # every card: column, busy/idle/stopped, project, title
kanban remote cards --column waiting         # cards waiting for input
kanban remote cards --project langwatch --json
```

Add `--json` to any command for machine-readable output.

## Errors

- `Cannot reach the Kanban Code Mac`: the Mac is asleep, Kanban Code is closed or Settings > Remote Control is off, or this machine is off the tailnet. Check `tailscale status`, then tell the user.
- `401`: the token was revoked. Ask the user to pair again.
- `403`: the `agent` scope does not allow that call (terminals need `full`).
