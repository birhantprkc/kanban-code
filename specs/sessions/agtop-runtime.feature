Feature: agtop session runtime
  As a developer running Claude Code cards
  I want a card's Claude session to run on an agtop host instead of tmux
  So that it keeps running in the background and shows as agtop in the card

  # The session name of an agtop card is `agtop-<id>`, where the id is the
  # first 8 hex characters of the Claude session id. Every layer routes by
  # that name alone: the app, the kanban CLI and the card terminal.

  Background:
    Given agtop is installed
    And Settings > Assistants > Claude Code > "Run sessions in" is "agtop"

  Scenario: Launching a card on agtop
    When I launch a card with a prompt
    Then Kanban Code runs "agtop session start" with a new session id, the prompt and its images
    And the hosted Claude gets KANBAN_CARD_ID set to the card
    And the card's session name is "agtop-<id>"
    And the card links the transcript at ~/.claude/projects/<cwd>/<session id>.jsonl without polling for it

  Scenario: Launching with a worktree
    When I launch a card with a worktree named "fix-login"
    Then Kanban Code creates the worktree at <repo>/.claude/worktrees/fix-login
    And agtop starts in that worktree

  Scenario: Resuming a card on agtop
    Given a card whose Claude session ended
    When I resume it
    Then tmux sessions of that Claude session are stopped
    And Kanban Code runs "agtop session start --resume" for it
    And a live host is reused as it is

  Scenario: The card terminal shows one agtop session
    Given a card running on agtop
    When I open the card
    Then the terminal runs "agtop open <id> --solo"
    And it shows that session alone, with no agent list and no header
    And the scroll wheel goes to agtop, not to tmux copy-mode
    And quitting agtop opens it again, the host keeps running

  Scenario: Messages reach an agtop session
    Given a card running on agtop
    When a queued prompt, a DM or a channel message is sent to it
    Then it is delivered with "agtop session send", which agtop queues while a turn runs
    And an interrupting send uses "--now"
    And images are sent as files with "--image"

  Scenario: An idle agtop session stays live
    Given a card running on agtop
    When agtop stops Claude after its idle timeout and the SessionEnd hook fires
    Then the card keeps its terminal, because the host is still alive
    And the next message starts Claude again with --resume

  Scenario: Self-compact from inside an agtop session
    Given a card running on agtop
    When the session runs "kanban self-compact 'carry on'"
    Then the CLI interrupts the turn, sends "/compact" and then "carry on" through agtop

  Scenario Outline: Cards that stay on tmux
    Given <case>
    When the card launches or resumes
    Then it runs on tmux

    Examples:
      | case                                          |
      | a Codex or Gemini card                        |
      | a card that runs on a remote machine          |
      | a launch with a command edited in the dialog  |
      | agtop is not installed (an error says so)     |

  Scenario: A command template wraps agtop's Claude
    Given the Claude launch command is "langwatch ${cli_command}"
    When a card launches on agtop
    Then agtop runs a script that execs "langwatch claude" with agtop's arguments

  Scenario: Extra terminals stay on tmux
    Given a card running on agtop
    When I open a new terminal tab on it
    Then that tab is a tmux shell
