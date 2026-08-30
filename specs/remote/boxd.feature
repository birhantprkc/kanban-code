Feature: Boxd Remote Mode
  As a developer with a boxd account
  I want each card to run on its own cloud machine
  So that my Mac stays free while every conversation is kept locally

  Background:
    Given the Kanban Code application is running
    And the boxd CLI is installed and logged in
    And Settings > Remote has the mode "Boxd integration"

  # ── Settings ──

  Scenario: Remote mode picker
    When I open Settings > Remote
    Then a mode picker shows two entries, boxd first:
      | Mode                         | Description                                                                 |
      | Boxd integration             | Create cloud sandboxes for each coding assistant and run tmux and coding sessions fully remotely, but sync back jsonl to keep all conversations. Requires a boxd account. |
      | Mutagen + Claude Remote Exec | Sync files with a remote machine, run the tmux and coding assistant locally but executing commands remotely. Best for delegating cpu and ram resources locally but resilient to network latency disconnects. Works with any linux remote machine. |
    And the boxd form shows:
      | Field                  | Default                                  |
      | Snapshot               | kanban-code-base                         |
      | Source machine         | good-wolf                                |
      | Project folder         | ~/${repo_name}                           |
      | Initialization command | clone the repository or pull it          |
      | Files to copy          | **/.env                                  |
      | Pause after inactivity | 60 minutes                               |
    And "Create snapshot now" saves a snapshot of the source machine

  Scenario: Assistant launch command template
    When I open Settings > Assistants
    Then each assistant has a "Launch command" field with the default "${cli_command}"
    And a checkbox "Different command when running on a remote machine"
    And checking it shows a second field used only when the card runs remotely
    And "${cli_command}" is replaced by the command Kanban Code builds before the environment prefix is added

  # ── Launch ──

  Scenario: Launching a card on a new machine
    Given a project whose origin is "git@github.com:acme/app.git"
    When I start a card with "Run on boxd" checked and "New machine from snapshot" selected
    Then a machine named "kc-app-<card id prefix>" is created from the snapshot
    And the kanban CLI is installed on the machine and its hooks are registered
    And the initialization command runs with ${repo_dir}, ${repo_url}, ${repo_name} and ${branch} substituted
    And the files matching "Files to copy" are copied into the checkout
    And the tmux session and the assistant run on the machine
    And the card remembers the machine

  Scenario: Worktree launch on a machine
    Given I start a card on boxd with "Create worktree" checked
    Then the worktree is created locally under .claude/worktrees and its branch is pushed
    And the machine checks out the same branch under its own .claude/worktrees
    And the assistant starts in the remote worktree

  Scenario: The transcript is mirrored to the Mac
    Given a card runs on a machine
    When the assistant writes to its transcript on the machine
    Then every line is copied to ~/.claude/projects/<encoded local path>/<session id>.jsonl
    And every machine path inside the lines is rewritten to the local path
    And hook events from the machine are appended to the local hook-events.jsonl with local paths
    And the card shows activity as if the session ran locally

  Scenario: kanban CLI inside the machine
    Given a card runs on a machine
    When the assistant runs "kanban dm" or "kanban list" on the machine
    Then the command is forwarded to the Mac and runs against the full board
    And the caller is identified by the card id of the session

  # ── Pause and resume ──

  Scenario: Machine paused when the session stops
    Given a card runs on a machine
    When the session ends or the terminal is killed
    Then the machine is paused right away
    And the card keeps its machine

  Scenario: Machine paused after inactivity
    Given a card runs on a machine
    When no transcript bytes and no hook events arrive for the configured timeout
    Then the machine is paused
    And the card shows "Machine <name> was paused due to inactivity for over 1h" with a Continue button

  Scenario: Resume attaches to the existing tmux session
    Given a card with a paused machine whose tmux session is still there
    When I resume the card with "Run on boxd" checked and the same machine selected
    Then the machine is resumed and the app attaches to the existing tmux session
    And no new assistant process is started

  Scenario: Resume after the tmux session is gone
    Given a card with a machine whose tmux session no longer exists
    When I resume the card on that machine
    Then the local transcript is pushed to the machine when it is newer
    And the assistant starts with --resume on the machine

  Scenario: Resume on another machine
    Given a card with a machine
    When I resume the card with another machine or "New machine" selected
    Then the checkout is prepared on the new machine
    And the transcript is pushed there and resumed
    And the previous machine is kept

  Scenario: Resume locally
    Given a card with a machine
    When I resume the card with "Run on boxd" unchecked
    Then the machine is paused and kept
    And the assistant resumes locally from the mirrored transcript

  Scenario: Remove machine from the resume dialog
    Given a card with a machine
    When I click "Remove machine" in the resume dialog
    Then a confirmation asks before the machine is destroyed

  # ── Machine lifecycle ──

  Scenario: Archive destroys the machine
    Given a card with a machine
    When I archive the card
    Then a dialog asks "Are you sure? This destroys the boxd machine"
    And confirming destroys the machine and archives the card

  Scenario: Card menu machine actions
    Given a card with a machine
    Then the card menu offers "Pause Machine" while it runs
    And "Destroy Machine" when the session is not running
    And "Destroy Machine" asks for a confirmation

  Scenario: Subagents share the parent's machine
    Given a card runs on a machine
    When it spawns a subagent
    Then the subagent runs on the same machine
    And archiving the subagent does not destroy the machine

  Scenario: Quit and sleep pause every machine
    When the app quits or the Mac goes to sleep
    Then every running machine is paused before the process ends
    And machines paused for sleep are resumed after wake

  Scenario: The card shows what the launch is doing
    Given a launch on boxd takes more than 30 seconds
    When the machine is created, the repository is checked out and files are copied
    Then the card shows the current step under the "Starting session" spinner
    And the launch is not marked stale while a step is in progress
    And the terminal attaches only after the tmux session exists on the machine

  Scenario: A failed preparation keeps the machine for a retry
    Given a launch on boxd fails after the machine was created
    Then the card remembers the machine
    And the machine is paused
    And a retry resumes the same machine

  Scenario: Orphan machines are cleaned up
    Given a machine named kc-<repo>-<card> that no card references
    When the app starts or ten minutes pass
    Then a paused machine is destroyed
    And a running machine is paused first and destroyed on the next sweep
    And a machine of an archived card is destroyed
    And a running machine of a card without a session is paused
    And the source machine of the snapshot is never touched

  Scenario: Quit does not wait forever for a pause
    When the app quits with connected machines
    Then a panel says the machines are being paused
    And the app quits after ten seconds even when a pause has not answered

  Scenario: One Claude login for every machine
    Given a Claude token from `claude setup-token` in the Remote settings
    When a session starts on a machine
    Then CLAUDE_CODE_OAUTH_TOKEN is set in the session
    And a token refresh on one machine does not log the others out
