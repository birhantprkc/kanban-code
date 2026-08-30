# Boxd remote mode

Kanban Code can run a card on its own boxd cloud machine. The tmux session, the coding assistant and the repository checkout live on the machine. The Mac keeps the board, the channels, the DMs and a mirror of every transcript.

This document describes the file layout on the machine and the bridge protocol between the Mac app and the machine. Settings and user flows are in `specs/remote/boxd.feature`.

## Transport

The app does not use SSH. Every interaction goes through the boxd CLI:

- `boxd machine exec <vm> -- <command>` runs a command. Stdout streams live, stdin is forwarded, the exit code is forwarded.
- `boxd machine cp - <vm>:<path>` uploads a file from stdin.
- `boxd machine new|get|pause|resume|wake|start|remove` control the machine.

The bridge is one long-lived exec per machine:

```
boxd machine exec <vm> -- /usr/local/bin/node /home/boxd/.kanban-code/cli/dist/kanban.js remote-agent
```

Both directions carry one JSON object per line.

## File layout on the machine

| Path | Content |
|---|---|
| `~/.kanban-code/cli/` | The kanban CLI copied from the app bundle (`dist/`, `node_modules/`, `package.json`). `VERSION` holds the app version that uploaded it. |
| `~/.local/bin/kanban` | Shim that runs `node ~/.kanban-code/cli/dist/kanban.js`. |
| `~/.kanban-code/hook.sh`, `statusline.sh` | Installed by `kanban hooks install` into `~/.claude/settings.json`. |
| `~/.kanban-code/hook-events.jsonl` | Hook events written on the machine. Streamed to the Mac. |
| `~/.kanban-code/context/<sessionId>.json` | Statusline context usage. Streamed to the Mac. |
| `~/.kanban-code/commands/proxy/<id>.json` | A `kanban` command that must run on the Mac (see proxy mode). |
| `~/.kanban-code/commands/proxy-responses/<id>.json` | The result of that command. |
| `~/.kanban-code/tmp/` | Prompt buffers and launch scripts written by the Mac. |
| `~/.kanban-code/images/<cardId>/` | Prompt images uploaded by the Mac. |
| `~/<repo_name>/` | The repository checkout (folder template in settings). Worktrees are under `<repo>/.claude/worktrees/<name>`. |

Card tmux sessions on the machine are created with the environment `KANBAN_REMOTE_PROXY=1`, `KANBAN_CARD_ID=<cardId>` and `KANBAN_CODE_HOME=/home/boxd/.kanban-code`.

## Path mapping

The Mac keeps one mapping table per machine, longest prefix first:

| Machine | Mac |
|---|---|
| `/home/boxd/<repo_name>` | The project path of the card |
| `/home/boxd/.kanban-code` | `~/.kanban-code` |
| `/home/boxd` | The user's home directory |

Every `.jsonl` line under `~/.claude/projects/` and `~/.codex/sessions/` is rewritten when it crosses the bridge: each string value in the JSON is walked and mapped prefixes are replaced. The mirror on the Mac is written to `~/.claude/projects/<encoded local cwd>/<sessionId>.jsonl`, so a local `claude --resume` works at any moment. Before a remote resume the Mac rewrites the local transcript to machine paths and uploads it.

## Messages from the machine to the Mac

| Type | Fields | Meaning |
|---|---|---|
| `hello` | `agentVersion`, `home`, `kanbanHome`, `vm` | First line after start. `home` is the user's home directory on the machine. |
| `file` | `path`, `cwd?`, `offset`, `data`, `eof` | `data` is base64 of the bytes appended at `offset`. For `.jsonl` files the chunk ends on a line boundary. `cwd` is the transcript's own working directory, read from the file or derived from its directory name. |
| `removed` | `path` | The file was deleted. |
| `proxy` | `id`, `argv`, `cwd`, `stdin`, `env`, `images` | A `kanban` command to run on the Mac. `images` is a list of `{name, base64}`. |
| `exec-result` | `id`, `stdout`, `stderr`, `code` | Result of an `exec`. |
| `activity` | `kind` | `hook` or `transcript`. The Mac stamps the time of receipt. |
| `pong` | | Reply to `ping`. |

## Messages from the Mac to the machine

| Type | Fields | Meaning |
|---|---|---|
| `watch` | `roots`, `offsets` | `roots` is a list of `{path, globs}`. `offsets` maps a path to the byte count the Mac already has. Files below the offset are not resent. |
| `put` | `path`, `data`, `mode?` | Write base64 `data` to `path`, creating parent directories. |
| `exec` | `id`, `argv`, `stdin?`, `cwd?` | Run a command. `argv[0]` is the program. |
| `proxy-result` | `id`, `stdout`, `stderr`, `code` | Result of a `proxy` request. |
| `ping` | | Keepalive. |

Watched roots: `~/.claude/projects` (`**/*.jsonl` and the sidecar directories `**/tool-results/*`, `**/subagents/*`), `~/.codex/sessions` (`**/*.jsonl`), `~/.kanban-code/hook-events.jsonl`, `~/.kanban-code/context/*.json`, `~/.kanban-code/commands/proxy/*.json`.

## Proxy mode of the kanban CLI

When `KANBAN_REMOTE_PROXY` is set, the CLI does not run the command on the machine. It writes `{id, argv, cwd, stdin, env: {KANBAN_CARD_ID}, images}` to `commands/proxy/<id>.json`, waits for `commands/proxy-responses/<id>.json`, prints the stdout and stderr it contains and exits with the returned code.

Commands that always run on the machine: `remote-agent`, `hooks install`.

Commands refused in proxy mode: `channel share`, `slack *`, `daemon`, `launch`, `reconcile`, `open`, and any command with a `--project <path>` option.

On the Mac the app runs the bundled CLI with the same arguments and `KANBAN_CARD_ID` set. The CLI uses `KANBAN_CARD_ID` as the caller identity before it looks at the tmux session.

## Machine lifecycle

| Event | Action |
|---|---|
| Session stopped, terminal killed, card archived | `boxd machine pause` |
| No activity for the configured timeout | `boxd machine pause`, the card shows the reason |
| App quit, system sleep | `boxd machine pause` for every running machine |
| Resume | `boxd machine get`, then `resume`, `wake` or `start` by status. If the tmux session still exists the app attaches to it. Otherwise it uploads the transcript and starts `claude --resume`. |
| Archive or delete with a machine | The app asks before it runs `boxd machine remove`. |

Machines are created with `--auto-suspend-timeout` equal to the inactivity timeout. If the Mac disappears without pausing the machine, boxd suspends it when the bridge traffic stops.

The app quits only after `pauseAll` returns or after 10 seconds, whichever comes first. A panel says "Pausing boxd machines" meanwhile. A pause that takes longer keeps running on its own.

### Sweep

At startup and every 10 minutes the app lists the machines and cleans up the ones it created (`kc-<repo>-<card>`):

| Machine | Action |
|---|---|
| No card references it, or only archived cards do, and it is not running | `boxd machine remove` |
| No card references it and it is running | `boxd machine pause`; the next sweep removes it |
| A card references it, the card has no tmux session, the machine is running and has no bridge | `boxd machine pause` |

The source machine of the snapshot and machines with an open bridge are never touched. A running orphan is paused before it is removed so a machine another process is using (for example the end to end test) gets a grace period.

### Launch progress

A launch or resume on boxd reports every step (`Creating machine`, `Running the initialization command`, `Checking out <branch> on the machine`, ...) as an action. The card shows the current step under the "Starting session" spinner, and the step repeats every 10 seconds, which keeps the 30 second stale-launch timers of the reconciler and of the card from giving up during a long checkout.

The embedded terminal opens when the launch starts. For a remote session it waits for a marker file, `~/.kanban-code/remote-ready/<session>`, which the launch writes once the tmux session exists on the machine, and only then runs `boxd machine exec --tty <vm> -- tmux attach-session`. The marker contains the machine name. A launch flags its session as remote before it knows the machine, so a terminal that starts during the first seconds of a launch still takes the remote path and reads the machine from the marker. While a remote launch reports steps, the card shows the spinner and the step on top of the terminal.

The service graph of the app (store, boxd supervisor, session registry, tmux router) is built once in `AppComposition` and shared by every `ContentView` value SwiftUI creates. The supervisor sends its actions to that one store.

### Claude login

Every machine made from the snapshot carries the Claude login of the source machine. A token refresh on one machine logs the others out ("Login expired" in the pane). The Remote settings take a long-lived token from `claude setup-token`; it is exported as `CLAUDE_CODE_OAUTH_TOKEN` in every session on a machine.
