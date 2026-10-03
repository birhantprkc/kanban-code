Feature: Vault projects, environments and card identity
  As a developer whose agents need credentials
  I want a secret to belong to a project and an environment
  So that a project loads its own secrets as a group and its dev secrets cost no judge call

  # A secret's name is its id: KEY is shared, project/environment/KEY is a
  # project's own. See docs/vault.md.

  Scenario: A name splits into project, environment and key
    Given the secret "shop/api/prod/DATABASE_URL"
    Then its project is "shop/api", its environment "prod" and its key "DATABASE_URL"
    And approvals, the audit log and "kv ls" show it as "Database URL · shop/api · prod"

  Scenario: An old name keeps resolving after a rename
    Given the secret "OPENAI_API_KEY__SHOP" renamed to "shop/dev/OPENAI_API_KEY"
    When a client asks for "OPENAI_API_KEY__SHOP"
    Then it gets the value under the name it asked for
    And the audit line names "shop/dev/OPENAI_API_KEY"
    And the other replica gets the rename as a tombstone and an alias

  Scenario: A rename onto the same value merges
    Given "K__ONE" and "K" hold the same value
    When "K__ONE" is renamed to "K"
    Then one secret "K" remains with the stricter tier, both sources and the alias "K__ONE"

  Scenario: A rename onto another value is refused
    Given "K__TWO" and "K" hold different values
    When "K__TWO" is renamed to "K"
    Then nothing changes and the outcome is "conflict"

  Scenario: The project of a folder
    Given the repository "shop" with the subfolder "api"
    Then the project of "shop/api" is "shop/api" and then "shop"
    And a linked worktree of "shop" is the project "shop"
    And a ".vault-project" file in the repository root replaces the folder name

  Scenario: kv env loads the project's group
    Given the secrets "shop/dev/DATABASE_URL" and "shop/prod/DATABASE_URL"
    When I run "kv env -- cmd" in the "shop" folder
    Then cmd gets DATABASE_URL from "shop/dev/DATABASE_URL"
    When I run "kv env --env prod -- cmd"
    Then cmd gets DATABASE_URL from "shop/prod/DATABASE_URL"

  Scenario: A manifest line without a value takes the project's secret, else the shared one
    Given the manifest ".env.vault" with the lines "OPENAI_API_KEY" and "SLACK_TOKEN"
    And the secrets "shop/dev/OPENAI_API_KEY", "OPENAI_API_KEY" and "SLACK_TOKEN"
    When I run "kv env -- cmd" in the "shop" folder
    Then OPENAI_API_KEY comes from "shop/dev/OPENAI_API_KEY"
    And SLACK_TOKEN comes from the shared "SLACK_TOKEN"

  Scenario: A manifest line naming a secret wins over the group
    Given the manifest line "DATABASE_URL={{vault:shop/prod/DATABASE_URL}}"
    When I run "kv env -- cmd" in the "shop" folder
    Then DATABASE_URL comes from "shop/prod/DATABASE_URL"
    And the dev DATABASE_URL is not asked for

  Scenario: A card gets its project's development secret without Jev
    Given the judged secret "shop/dev/API_KEY" without rules
    And a card whose process runs in the "shop" folder or one of its worktrees
    When the card asks for it
    Then it is allowed by policy with no Jev call
    And the audit line says "the project's own development secret"

  Scenario Outline: Other secrets keep their path
    Given a card whose process runs in the "shop" folder
    When it asks for <secret>
    Then the release goes <path>

    Examples:
      | secret                                    | path          |
      | a prod secret of shop                     | to Jev        |
      | a dev secret of shop that has rules       | to Jev        |
      | a shared secret                           | to Jev        |
      | a dev secret of another project           | to Jev        |
      | a dev secret of shop with tier ask        | to the human  |
      | a dev secret of shop where every use asks | to the human  |
      | a dev secret of shop with tier never      | to a refusal  |

  Scenario: The folder the request claims does not count
    Given a card whose process runs in another project's folder
    When its request says the working directory is the "shop" folder
    Then "shop/dev/API_KEY" still goes to Jev

  Scenario: Jev is asked once per rules text
    Given a request for 6 judged secrets without rules and 3 with the rules "deploys only"
    When the vault judges it
    Then Jev gets 2 questions, each listing its secret names
    And each of the 9 secrets has its own audit line

  Scenario: A detached process is placed by its session token
    Given a card session started by the master, with KANBAN_CARD_TOKEN in its environment
    And a process of that session that was detached and now has launchd as its parent
    When it calls kv
    Then the master finds no card in its ancestry and takes the card of the token
    And the audit line says "by session token"

  Scenario: A wrong or missing token changes nothing
    Given a process outside every card session
    When it calls kv with no token, or with one the master has no hash for
    Then the release asks the human as before

  Scenario: A token ends with its session
    Given a card whose session ended more than 15 minutes ago
    When a process calls kv with that card's token
    Then the token is refused and removed
    And a new session of the card gets a new token

  Scenario: The token never reaches the pane or another card
    When the master starts a tmux card session
    Then KANBAN_CARD_ID and KANBAN_CARD_TOKEN are set with "tmux new-session -e"
    And the command typed into the pane does not contain them
    And an app or tmux server started from that card's shell drops both before starting other sessions
