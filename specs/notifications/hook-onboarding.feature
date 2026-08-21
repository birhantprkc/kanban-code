Feature: Hook Onboarding
  As a developer setting up Kanban Code
  I want automatic Claude Code hook detection and setup
  So that I don't have to manually edit settings.json

  Background:
    Given the Kanban Code application is running

  # ── Hook Detection ──

  Scenario: Detecting existing hooks
    Given ~/.claude/settings.json exists
    When Kanban Code starts
    Then it should check for required hooks:
      | Hook Event        | Purpose                          |
      | UserPromptSubmit  | Track when user sends messages   |
      | Stop              | Detect when Claude stops working |
      | Notification      | Detect permission/question/idle  |
      | SessionStart      | Track new session starts         |
      | SessionEnd        | Track session endings            |
      | SubagentStart     | Track subagents a session starts  |
      | SubagentStop      | Track subagents that finish       |

  Scenario: All hooks present
    Given all required hooks are already configured
    Then Kanban Code should show a green checkmark in settings
    And no onboarding prompt should appear

  Scenario: Some hooks missing
    Given only Stop and Notification hooks are configured
    When I open Kanban Code
    Then an onboarding banner should appear:
      "Claude Code hooks need updating for full Kanban Code integration"
    And a "Set up hooks" button should be available

  Scenario: No hooks configured
    Given ~/.claude/settings.json has no hooks section
    When I open Kanban Code for the first time
    Then a first-run onboarding screen should appear
    And it should explain what hooks do
    And offer to set them up automatically

  # ── Automatic Setup ──

  Scenario: Automatic hook installation
    When I click "Set up hooks"
    Then Kanban Code should:
      | Step | Action                                               |
      | 1    | Read existing ~/.claude/settings.json                |
      | 2    | Preserve any existing hooks (don't overwrite)        |
      | 3    | Add missing Kanban Code hooks alongside existing ones     |
      | 4    | Install the hook handler script                     |
      | 5    | Write updated settings.json                          |
    And a confirmation should show what was changed

  Scenario: Preserving existing pushover hooks
    Given ~/.claude/hooks/pushover-notify.sh is configured for Stop
    When Kanban Code adds its hooks
    Then the pushover hook should be preserved
    And Kanban Code's hook should be added as an additional entry
    And both should fire on Stop events

  Scenario: Hook handler script location
    When Kanban Code installs its hook handler
    Then the script should be placed at ~/.kanban-code/hook.sh
    And it should be executable (chmod +x)
    And it should be referenced by absolute path in settings.json

  Scenario: Hook handler receives JSON stdin
    Given the hook handler is called by Claude Code
    Then it should receive JSON on stdin with:
      | Field            | Type   | Description              |
      | session_id       | string | Claude session UUID      |
      | hook_event_name  | string | Event type               |
      | transcript_path  | string | Path to .jsonl file      |
      | notification_type| string | For Notification events  |
    And it should update the Kanban Code state accordingly

  # ── Edge Cases ──

  Scenario: settings.json doesn't exist
    Given ~/.claude/settings.json does not exist
    When I click "Set up hooks"
    Then Kanban Code should create the file with proper JSON structure
    And only hook-related settings should be added

  Scenario: settings.json has invalid JSON
    Given ~/.claude/settings.json contains malformed JSON
    When Kanban Code tries to read it
    Then it should show an error: "settings.json is malformed"
    And offer to open it in the user's editor
    And NOT attempt to auto-fix it

  Scenario: User declines hook setup
    Given the onboarding prompt appears
    When I click "Skip" or "Not now"
    Then Kanban Code should work with limited functionality
    And activity detection should fall back to .jsonl polling
    And a persistent but dismissible hint should remind about hooks
