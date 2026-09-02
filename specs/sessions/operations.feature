Feature: Session Operations (Fork, Checkpoint, Rename)
  As a developer managing Claude Code sessions
  I want to fork, checkpoint, and rename sessions from the Kanban Code UI
  So that I can branch conversations and manage session history

  Background:
    Given the Kanban Code application is running

  # ── Fork ──
  # (Learned from claude-resume: copy .jsonl with new UUID)

  Scenario: Fork a session
    Given I click on a session card to open it
    When I select "Fork" from the actions menu
    Then a confirmation dialog should appear:
      | Message | "Fork this session? A copy will be created." |
      | Default | Cancel                                        |
    And on confirm:
      | Step | Action                                             |
      | 1    | Read the .jsonl file                               |
      | 2    | Generate a new UUID                                |
      | 3    | Replace sessionId in every JSON line               |
      | 4    | Write to new file: {newUUID}.jsonl in same dir     |
    And a new card should appear on the board
    And a toast should show "Forked! New session: {shortId}..."

  Scenario: Fork preserves conversation content
    Given a session with 50 conversation turns
    When I fork it
    Then the new .jsonl should have the same number of lines
    And all message content should be identical
    And only the sessionId field should differ

  Scenario: Fork from any column
    Given sessions exist in various columns
    Then the "Fork" action should be available on cards in every column
    And the forked session should appear in "All Sessions" by default

  Scenario: Fork and start working on the copy
    Given I forked a session
    When I click "Resume" on the forked session's card
    Then it should move to "In Progress"
    And Claude should be resumed with the new session ID

  # ── Checkpoint ──
  # (Learned from claude-resume: truncate .jsonl, create .bkp)

  Scenario: Open checkpoint view
    Given I click on a session card
    When I select "Checkpoint" from the actions menu
    Then a scrollable list of conversation turns should appear
    And each turn should show:
      | Field      | Example                          |
      | Turn #     | Turn 1, Turn 2, etc.             |
      | Role       | You / Claude                     |
      | Preview    | First 120 chars of message text  |
      | Timestamp  | Relative time                    |

  Scenario: Tool-only messages show descriptive text
    Given a conversation turn is an assistant message with only tool_use blocks
    Then the preview should show "[tool: Read, Edit, Bash]"
    And not be blank

  Scenario: User messages with tool_result blocks
    Given a conversation turn is a user message with only tool_result blocks
    Then the preview should show "[tool result x3]"

  Scenario: Select and confirm checkpoint
    Given I'm viewing the checkpoint turn list
    When I select turn #15
    Then a confirmation dialog should appear:
      | Message | "Truncate after turn 15? A .bkp backup will be saved." |
      | Default | Cancel                                                  |
    And on confirm:
      | Step | Action                                          |
      | 1    | Copy .jsonl to .jsonl.bkp (overwrite existing)  |
      | 2    | Keep all lines up to turn 15's line number      |
      | 3    | Write truncated content back to .jsonl           |
    And the session card should refresh with updated message count

  Scenario: Checkpoint keeps the whole clicked message
    Given an assistant reply written to the transcript as several records, thinking first and the text after
    When I restore to that reply from the chat or the history
    Then the file keeps every record of the reply, through the last one
    And only what came after the reply is removed

  Scenario: Checkpoint overwrites existing backup
    Given a .bkp file already exists for this session
    When I create a new checkpoint
    Then the .bkp should be overwritten with the current .jsonl
    And the checkpoint should proceed normally

  Scenario: Checkpoint works on turns before summarized context
    Given Claude has summarized early context (context compaction)
    When I checkpoint to turn #3 (before the summary)
    Then the truncation should succeed
    Because we operate on the raw .jsonl, not Claude's internal state

  Scenario: Checkpoint from any column
    Given sessions exist in various columns
    Then the "Checkpoint" action should be available on every card
    And checkpointing should not change the card's column

  # ── Rename ──

  Scenario: Rename a session via dialog
    Given a session card shows "Fix authentication bug..."
    When I select "Rename" from the context menu or detail view
    Then a rename dialog appears with the current name pre-filled
    And I can type a new name and confirm
    And pressing Enter saves the name

  Scenario: Rename persists in coordination file
    Given I rename session "abc-123" to "Auth refactor v2"
    Then the coordination file should store the custom name
    And the name should persist across app restarts

  Scenario: Session without a name shows first message
    Given a session has no custom name
    And no summary from the index
    Then the card title should show the first user message (truncated)
    And the first message should be extracted from the .jsonl

  Scenario: Session with horrible auto-generated name
    Given Claude auto-named a session "Untitled Session 47"
    When I rename it to "Payment gateway integration"
    Then the custom name should override the auto-name everywhere
    And search should match both the custom name and the original

  Scenario: Rename via context menu
    Given I right-click on a session card
    When I select "Rename"
    Then a rename dialog appears
