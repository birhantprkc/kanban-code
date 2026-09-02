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
| `~/<repo_name>/` | The repository checkout (folder template in settings). Worktrees are under `<repo>/.claude/worktrees/<name>`, created on the machine only with `git worktree add -b <name>`; the branch reaches origin when the assistant pushes it. |

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
| `file` | `path`, `cwd?`, `offset`, `data`, `eof` (a file that is not `.jsonl` always comes whole, at offset 0) | `data` is base64 of the bytes appended at `offset`. For `.jsonl` files the chunk ends on a line boundary. `cwd` is the transcript's own working directory, read from the file or derived from its directory name. |
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
| Session stopped by itself | `boxd machine pause`, the machine keeps its tmux in standby |
| Terminal tab closed, card archived | `boxd machine stop`: the work is over, so the machine keeps its disk only. Resume starts it again, cold. |
| No activity for the idle window | `boxd machine pause`, the card shows the reason |
| A card comes into focus, or a click or a key reaches its terminal | The machine is resumed and the bridge connects again |
| App quit, system sleep | The machines keep running; killing the sessions from the quit sheet puts their machines in standby |
| Resume | `boxd machine get`, then `resume`, `wake` or `start` by status. If the tmux session still exists the app attaches to it. Otherwise it uploads the transcript and starts `claude --resume`. |
| Archive or delete with a machine | The app asks before it runs `boxd machine remove`. |

### Which machine runs, and for how long

Only a person takes a machine out of standby. The card that comes into focus gets its machine back, and a click or a key in the terminal of a paused card does the same, so "Machine paused. Click here to bring it back." is one click away from the session. The terminal answers the click at once with "Resuming machine <name>…", and with a line to try again if the machine does not come back; the toolbar pill shows the machine as connecting meanwhile. A second click while the first resume runs does nothing.

A machine brought back this way is on approval: when its card leaves focus with no work done on it, it goes back to standby at once, so a quick look costs the seconds it took. The first hook event or transcript line on the machine ends that, and the machine then keeps the normal idle window. A machine that was already running before the look, or one with work on it, is never touched by this. Nothing else resumes a machine: cards nobody has open stay in standby.

Every machine gets the same idle window, the one in the settings (30 minutes by default), whether its card is open or not: an agent can be waiting on a watcher, a subagent or a review, with nothing on the screen to show for it. A machine with work on it is never paused: the check asks the board first and any card that is actively working keeps its machine.

Machines are created with `--auto-suspend-timeout` equal to the inactivity timeout. If the Mac disappears without pausing the machine, boxd suspends it when the bridge traffic stops.

`boxd machine connect` wakes a paused machine in half a second. The attach loop of the embedded terminal reconnects after a drop, so a plain retry would undo every pause. Before the app pauses a machine it writes `~/.kanban-code/remote-ready/<session>.paused` for every session on it; the loop reads that file at the top of every try, prints "Machine paused. Click here to bring it back." and waits on it, and the file goes away when the bridge connects again. The check comes before the connect, not after it: a connect that succeeds takes the machine out of standby and leaves the loop, so a check that runs only after a failed try never sees the marker. The loop reads the machine name from the ready marker on every try, so a resume that moved the session to another machine is followed. The markers are also written at app start for a machine that is not running, so the terminal waits instead of waking it. When a paste or a wheel tick reaches a machine the app has as paused, the app asks boxd first and reconnects at once if the machine runs.

A machine the app paused can be running again through another path, for example `boxd machine resume` in a shell. Once a minute the supervisor lists the machines it holds paused; one that boxd reports as running gets its bridge reconnected, its cards leave the paused state, and the agent answers the proxied `kanban` commands that waited meanwhile (the CLI waits up to 120 seconds for an answer).

A reconnection of this kind keeps the activity clock of the machine: the machine gets 5 minutes, not a new inactivity timeout. A machine that woke without a person behind it goes back to standby at the next tick, and a machine somebody resumed keeps its full timeout as soon as work arrives.

Quit and Mac sleep leave the machines running: the work continues there while the Mac is off, and the bridges reconnect after wake. The quit sheet lists the sessions on machines with a cloud icon; "Kill managed sessions on quit" kills them and puts their machines in standby, bounded to 10 seconds ("Stopping boxd machines" panel meanwhile). A card whose session runs on a machine does not keep the Mac awake: the active-session helper that Amphetamine watches only runs for sessions on the Mac itself.

The launch dialog of a card offers the choice of its last run: a card whose last session ran on the Mac opens with "Run on boxd" off, even though it keeps its machine, and a card whose last session ran on a machine opens with the box on and that machine chosen. A card that never ran follows its machine, and a card with no machine follows the project default.

A card that resumes locally after it ran on a machine gets its worktree created on the Mac at that moment, tracking `origin/<branch>` when the branch was pushed and starting a new branch otherwise. While a machine is paused the card is never shown as working, whatever the last hook event said.

### Embedded terminal

The terminal attaches through `boxd machine connect <machine>`, the interactive shell of the CLI, which is what a terminal app uses too: it puts the local pty in raw mode, sizes the remote pty, follows resizes, and the session lives as long as the shell. `boxd machine exec --tty` does none of that (canonical mode, remote pty 0x0) and hangs up a full-screen program such as tmux after a few seconds, so it is not used for the terminal.

The wheel is not forwarded to the machine as mouse events. As for a local session, the app turns wheel ticks into tmux copy-mode commands (`copy-mode`, `send-keys -X cursor-up`), and for a session on a machine those commands go through the bridge of the machine. A tick to a local server costs a process spawn; a tick to a machine costs a round trip, so the ticks of the last 60 ms are summed into one command. Esc and any other key leave copy-mode through the same route. The terminal never reports mouse events to the assistant, even when it asks for mouse tracking: a drag selects text in the terminal itself, as in a local session.

Images cannot be pasted through the clipboard: the assistant on the machine reads the machine's clipboard, which has nothing. An image pasted into the terminal with Cmd+V goes over the bridge to `~/.kanban-code/images/pasted/` on the machine, and the path is pasted into the session through the tmux server of the machine (`load-buffer`, `paste-buffer -p`). The bridge runs that after the upload, so the assistant finds the file when it checks the pasted path and shows it as an attached image. Typed through the terminal instead, the path raced the upload: `put` returns before the machine has written the file. A chat message with images uploads them the same way and the prompt points at them by path, which is also how a queued prompt with images already worked at launch.

`connect` takes no command, so `/usr/bin/expect` drives it: `spawn` connect, `expect` the prompt (20 seconds, then the command is sent anyway), `send " exec tmux -u -T hyperlinks attach-session -t <session>\r"`, then `interact`. `exec` replaces the shell, so a detach closes the connection and the script prints "Session ended.". A WINCH trap copies the local size to the pty of connect. The machine name reaches the Tcl program through `KANBAN_MACHINE`. Everything else (the bridge, tmux commands, file copies) stays on plain `boxd machine exec`, which runs for hours. The assistant runs with `LANG=C.UTF-8`.

### Sweep

At startup and every 10 minutes the app lists the machines and cleans up the ones it created (`kanban-<repo>-<card>`):

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

#A shell tab of a card on a machine (Cmd+T) opens on the machine, in the remote checkout. The app marks the name as remote before the tab opens, creates the session through the bridge, and writes the ready marker, which is what the terminal waits for. A shell that cannot be created takes only its own tab: the session of the card keeps running.

## Files that are rewritten

Only `.jsonl` files grow by appending, so only they are streamed by offset. The machine rewrites the other watched files in place, such as `context/<sessionId>.json` from the statusline, and their new content has nothing to do with the bytes the Mac holds. The agent sends those whole, at offset 0, and only when the content changes; the Mac replaces its copy. Sent as a tail, a shorter rewrite left the end of the last one behind, the file stopped being valid JSON, and the card lost its model name and its context measure.

The machine records the installed CLI in `~/.kanban-code/cli/VERSION` as the app version plus a digest of the bundle. Two builds of one version have different digests, so a fix in the CLI reaches the machines that already have it.

## Logins

Claude Code keeps its OAuth tokens in the Keychain on macOS (`Claude Code-credentials`) and in `~/.claude/.credentials.json` on Linux, with the same JSON inside. Codex keeps `~/.codex/auth.json` on both. Both rotate the refresh token on every refresh, so a machine made from the snapshot drifts from the Mac within hours and one side shows "Login expired".

The supervisor keeps the copies equal. When a bridge connects, and then once a minute, it reads the login files of the machine with one `exec` and compares each with the Mac's copy. The newest copy wins: `claudeAiOauth.expiresAt` for Claude, `last_refresh` for Codex. A newer local copy is written to the machine (`put`, mode 600) together with the `oauthAccount` block of `~/.claude.json`; a newer remote copy is written to the Keychain (`security add-generic-password -U`) or to `~/.codex/auth.json`, and reaches the other machines on their next tick. Running assistants read the shared copy before they refresh, so an account switch on the Mac reaches every session, local and remote. A token rotation stays quiet. An account switch on the Mac (the `accountUuid` of `~/.claude.json` changed) and a login taken from a machine show a notice with the time.

Two machines that refresh the same token in the same minute leave one of them with a rejected refresh until the next tick. A long-lived token from `claude setup-token`, set in Settings, Assistants, is exported as `CLAUDE_CODE_OAUTH_TOKEN` in every remote session and takes precedence over the synced login.
