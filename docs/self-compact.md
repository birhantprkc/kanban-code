# Context threshold self-compaction

The app watches the context size of each Claude session and tells the agent to
compact itself before the window fills up.

## Where the numbers come from

The statusline script writes `~/.kanban-code/context/<sessionId>.json` on each
render. `ContextUsageReader.read(sessionId:)` reads that file. The monitor loop
in `ContentView` polls it every `selfCompact.pollIntervalSeconds` seconds.

## The three actions

`SelfCompactPolicy` builds the rules, from the global settings or from the
card threshold. Each rule has a token threshold and one action:

- `queuePrompt`: the message goes to the front of the card queue and is sent
  when the agent is idle.
- `steer`: the message is pasted into the session and submitted at once.
- `interrupt`: Escape stops the turn first, then the message is sent.

## Guards against a warning that is not true any more

The context file can be one poll old, and the agent can compact between the
read and the send. A warning about a limit the session is under again confuses
the agent, so three guards drop it:

1. Before a steer or an interrupt, the send path reads the context file again.
   `SelfCompactPolicy.shouldSend(rule:currentContextTokens:)` drops the message
   when the context is under the threshold of the rule.
2. `TmuxAdapter.ensurePromptSent` presses Enter again while the text sits in the
   composer. It takes an `abortIf` check, and the self-compact path gives it a
   fresh context read. When the agent compacts during those retries, the retries
   stop and the composer is cleared.
3. When the polled usage falls under the first threshold, the monitor removes
   the queued warnings and also captures the pane. If a warning is still in the
   composer, `SelfCompactPolicy.paneHasUnsentMessage` finds it and the composer
   is cleared.

`TmuxAdapter.clearComposer(sessionName:)` sends Ctrl+U and verifies the pane.
`ensurePromptSent` also calls it when it gives up after its retry window, so
text that was never submitted does not wait in the composer for a stray Enter.

The queued warnings have one more guard at send time:
`BackgroundOrchestrator.shouldDropStaleSelfCompactPrompt` removes a queued
warning whose threshold the context no longer reaches.
