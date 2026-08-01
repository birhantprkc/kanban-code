Feature: First-class subagents
  As an agent working in a Kanban Code session
  I want to delegate work to child sessions managed by Kanban Code
  So that every delegated session has normal lifecycle, context management, and visibility

  Background:
    Given the Kanban Code application and daemon are running
    And the `kanban` CLI is installed
    And the configured maximum subagent depth is 1

  # Parent-child model

  Scenario: A subagent is a normal card with a parent
    Given card "parent-1" is a normal Claude card
    When it spawns card "child-1" as a subagent
    Then "child-1" should persist `parentCardId` as "parent-1"
    And "child-1" should have a normal session link and tmux link
    And "child-1" should support terminal, chat, history, search, queued prompts, notifications, and auto-compact
    And "child-1" should not participate in Backlog, In Progress, Waiting, In Review, Done, or All Sessions lanes
    And "child-1" should be rendered under "parent-1"

  Scenario: Hierarchy helpers support future nesting
    Given cards form a parent-child hierarchy
    Then each card should expose its depth and root card id
    And descendants should be ordered deterministically
    And changing the configured maximum depth should not require a schema migration

  Scenario: Depth limit rejects grandchildren by default
    Given "child-1" is at depth 1
    When "child-1" runs `kanban subagent spawn "delegate again"`
    Then the command should fail without creating a card or tmux session
    And stderr should say "You already reached the user-defined maximum subagent depth of 1. You cannot spawn another subagent. Do the work yourself."

  Scenario: Existing cards remain root cards
    Given a coordination file written before subagents existed
    When Kanban Code loads it
    Then cards without `parentCardId` should decode as root cards
    And no existing workflow placement should change

  # CLI discovery and prompt input

  Scenario: Subagent commands are prominent in CLI help
    When an agent runs `kanban --help`
    Then `subagent` and `parent` should appear before low-level `send`
    And `subagent` should be described as creating and managing delegated agent sessions
    And the help should point to `kanban subagent --help`

  Scenario: Multiline prompts are safe to pass
    When an agent runs `kanban subagent spawn` or `kanban subagent fork`
    Then the prompt may be supplied as a positional argument
    And `-` should read the prompt from stdin
    And help should recommend `<<'EOF' ... EOF` piped through stdin for multiline prompts
    And shell metacharacters, quotes, backticks, dollar signs, and newlines should be preserved verbatim

  Scenario: Subagent commands require a Kanban-owned tmux card
    Given the CLI is not running inside a tmux pane linked to a Kanban card
    When `kanban subagent spawn "investigate"` is run
    Then it should fail before mutating state
    And it should explain that the command must run inside a Kanban Code card tmux session

  # Spawn

  Scenario: Spawn inherits the parent assistant
    Given the current card uses Codex
    When it runs `kanban subagent spawn "investigate the parser"`
    Then a child card should be created with assistant Codex
    And it should inherit the parent's project path and worktree path
    And a new Codex session and tmux session should start
    And the requested prompt should be delivered exactly once after the assistant is ready

  Scenario Outline: Spawn selects an explicit assistant
    Given the current card uses Claude
    When it runs `kanban subagent spawn "investigate" --assistant <assistant>`
    Then the child should use <assistant>
    And it should start through the same tested launch pipeline as a normal card

    Examples:
      | assistant |
      | claude    |
      | codex     |
      | gemini    |

  Scenario: Spawn applies a model override
    Given the current card uses Claude
    When it runs `kanban subagent spawn "investigate" --model sonnet`
    Then the child card should persist model override "sonnet"
    And Claude should launch with `--model sonnet`
    And future resumes should retain the same model override

  Scenario: Spawn without a model override uses normal defaults
    When an agent spawns a child without `--model`
    Then the child should use the selected assistant's configured service or default model
    And no extra model flag should be injected

  Scenario Outline: Spawn or fork sets a child-specific context threshold
    Given the current card uses Claude
    When it runs `kanban subagent <operation> "investigate" --context-threshold 250k`
    Then the child card should persist a self-compact context threshold of 250000 tokens
    And the child should queue one self-compact nudge when its context reaches 250000 tokens
    And the nudge should tell the child to pass a post-compact continuation message to `kanban self-compact`
    And the child should receive a direct `/compact` when its context reaches 450000 tokens
    And the child-specific policy should replace the global self-compact rules for that card
    And the child-specific policy should remain active when the global self-compact guard is disabled

    Examples:
      | operation |
      | spawn     |
      | fork      |

  Scenario: Context threshold input is explicit and validated
    When an agent passes `--context-threshold 300k`
    Then the CLI should preserve the value as 300000 tokens without rounding
    And `kanban subagent --help` should document the accepted `Nk` and integer token forms
    But zero, negative, malformed, and overflowing thresholds should fail before creating a card

  Scenario: Spawn without a context threshold uses global self-compact rules
    When an agent spawns a child without `--context-threshold`
    Then the child should not persist a card-specific threshold
    And the daemon should apply the global self-compact settings unchanged

  Scenario: Child receives delegation instructions
    When a subagent is spawned with prompt "investigate the parser"
    Then its initial user prompt should identify the parent card and the child card
    And it should include the delegated prompt verbatim
    And it should explain `kanban parent dm <message>`
    And it should explain `kanban parent dm-and-self-archive <message>`
    And it should say the parent may resume it if follow-up work is needed

  # Fork

  Scenario: Same-assistant fork preserves the full parent transcript
    Given the current Claude card has a resumable session
    When it runs `kanban subagent fork "try another approach"`
    Then the session should be forked using the existing session-store fork operation
    And the child should keep the full transcript
    And the child should resume independently in the same worktree by default
    And the delegation instructions and requested prompt should be queued after the inherited transcript

  Scenario: Cross-assistant fork migrates the copied session
    Given the current Claude card has more than 500 conversation turns
    When it runs `kanban subagent fork "try it in Codex" --assistant codex`
    Then Kanban Code should fork the source session before modifying anything
    And the fork should be migrated through the existing assistant migration pipeline
    And up to the latest 500 conversation turns should be imported within a safe context-size budget
    And the original parent session should remain unchanged
    And the resulting child should launch as Codex with the delegation prompt queued once

  Scenario: Fork requires a resumable parent transcript
    Given the current card has no session file
    When it runs `kanban subagent fork "try another approach"`
    Then it should fail without creating a child card
    And it should recommend `kanban subagent spawn` instead

  # Listing and lifecycle

  Scenario: List separates active and archived descendants
    Given the parent owns two active children and one archived child
    When it runs `kanban subagent list`
    Then active descendants should be listed first under "Active"
    And archived descendants should be listed under "Archived"
    And each row should include card id, depth, assistant, status, model when set, and title
    And `ls` should behave identically to `list`

  Scenario: Parent archives a child
    Given "child-1" is an active child owned by the current parent
    When the parent runs `kanban subagent archive child-1`
    Then the child's tmux client should be stopped safely
    And the child should be marked archived outside the workflow lanes
    And its transcript and relationship should remain available for resume

  Scenario: Parent resumes an archived child
    Given "child-1" is archived and owned by the current parent
    When the parent runs `kanban subagent resume child-1`
    Then the child should be unarchived
    And its persisted assistant, model, project, worktree, and session should be resumed
    And the child should reappear beneath its parent

  Scenario: Guarded aliases reject unrelated cards
    Given "other-child" is not in the current card's descendant tree
    When the current card runs any guarded `kanban subagent transcript|capture|dm|send` command for "other-child"
    Then the command should fail without sending or reading anything
    And it should explain that the target is not an owned subagent

  Scenario: Guarded aliases delegate to established operations
    Given "child-1" is owned by the current parent
    Then `kanban subagent transcript child-1` should use the top-level transcript implementation
    And `kanban subagent capture child-1` should use the top-level capture implementation
    And `kanban subagent dm child-1 <message>` should use the top-level direct-message implementation
    And `kanban subagent send child-1 <keys>` should use the low-level send implementation
    And the subagent help should document when each operation is appropriate

  # Child-to-parent communication

  Scenario: Child reports to its direct parent
    Given the current card is "child-1" with parent "parent-1"
    When it runs `kanban parent dm "The parser bug is in tokenizer.swift"`
    Then the message should be delivered to "parent-1" through the established direct-message path
    And the sender identity should identify "child-1"

  Scenario: Child reports completion and self-archives
    Given the current card is "child-1" with parent "parent-1"
    When it runs `kanban parent dm-and-self-archive "Implemented and tests pass"`
    Then the complete message should be delivered to "parent-1" first
    And only after confirmed delivery should "child-1" archive itself
    And the child transcript should remain resumable

  Scenario: Root cards cannot use parent commands
    Given the current card has no parent
    When it runs `kanban parent dm "hello"`
    Then it should fail without sending anything
    And it should explain that the current card is not a subagent

  # Codex startup readiness

  Scenario: Codex startup questions do not consume the delegated prompt
    Given a Codex child launch shows a worktree confirmation, upgrade prompt, trust prompt, or other known startup question
    When Kanban Code waits for the child to become ready
    Then it should answer the known prompt deterministically
    And it should continue waiting for the real Codex composer
    And the delegated prompt should be sent only after readiness
    And `--no-alt-screen` should remain enabled for embedded terminal compatibility

  Scenario: Unknown startup prompt fails visibly
    Given a child assistant shows an unknown blocking startup question
    When readiness times out
    Then the child card and terminal should remain available for manual recovery
    And the parent CLI command should return a useful timeout error naming the child card
    And the initial prompt should remain queued rather than be lost

  # Board and fullscreen UI

  Scenario: Root card with active children becomes an accordion
    Given a visible root card has active subagents
    Then it should show an expand or collapse caret in kanban and list views
    And expanding it should render child cards immediately below the parent
    And collapsing it should hide child cards without changing their lifecycle
    And the expansion state should remain stable across ordinary board updates

  Scenario: Fullscreen sidebar nests child cards
    Given a fullscreen sidebar root card has active subagents
    When its accordion is expanded
    Then each child should use the normal card row presentation
    And child rows should be indented by hierarchy depth
    And clicking a child should open its normal terminal, chat, history, and prompt views
    And active indicators should behave the same as for root cards

  Scenario: Archived children do not clutter the nested board
    Given a parent has active and archived subagents
    Then only active children should appear in the inline accordion
    And archived children should remain available in the subagent management view

  Scenario: See all subagents from a card menu
    Given a card has current or archived descendants
    When I choose "See All Subagents" from its context menu or detail menu
    Then a modal should show all descendants in a table
    And each row should show depth, title, assistant, model, lifecycle, activity, and card id
    And I should be able to open any row
    And I should be able to archive an active child
    And I should be able to resume an archived child

  Scenario: Card menu exposes compact settings
    Given a card supports context-threshold self-compaction
    When I open its card menu and choose "Compact Settings"
    Then I should see whether the card uses global settings or a card-specific context threshold
    And I should be able to choose a compact threshold in 50k token increments
    And choosing "Use Global Settings" should clear the card-specific override
    And the selected threshold should persist across app restarts and session resumes
    And changing the setting should re-evaluate future crossings without immediately replaying stale nudges

  Scenario: Compact settings explain unsupported assistants
    Given a card's assistant does not expose context usage to the daemon
    When I open its compact settings
    Then the menu should explain that threshold self-compaction is unavailable for that assistant
    And an existing persisted threshold should remain available if the card later migrates to a supported assistant

  Scenario: A child card can show its own hierarchy when depth is enabled
    Given the maximum depth setting is greater than 1
    And a child has its own active child
    Then nested accordions should recurse using the same component
    And the management table should include all descendants

  # Settings and safety

  Scenario: Configure maximum subagent depth
    When I open Settings
    Then I should see a "Maximum subagent depth" control
    And its default value should be 1
    And it should accept non-negative bounded integers
    And setting it to 0 should disable spawning and forking subagents

  Scenario: Deleting a parent requires explicit descendant handling
    Given a parent has subagents
    When I delete the parent
    Then the confirmation should state how many descendants are affected
    And deleting should not leave children pointing to a missing parent

  Scenario: Reconciliation preserves subagent placement
    Given a child session changes between active, waiting, ended, review, or done states
    When background reconciliation runs
    Then the child should remain outside workflow lanes under its parent
    And its underlying status should still be recorded for display and automation
