import { describe, test } from "node:test";
import { strict as assert } from "node:assert";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  assertOwnedSubagent,
  buildSubagentPrompt,
  depthLimitError,
  descendantIds,
  makeSubagentRequest,
  missingForkSessionError,
  normalizeMaximumDepth,
  resolveSubagentPrompt,
  subagentDepth,
  submitSubagentRequest,
} from "./subagents.js";
import { formatCardSummary } from "./format.js";
import type { CardSummary, Link } from "./types.js";

function card(id: string, parentCardId?: string): Link {
  return {
    id,
    parentCardId,
    column: "in_progress",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    manualOverrides: {
      worktreePath: false,
      tmuxSession: false,
      name: false,
      column: false,
      prLink: false,
      issueLink: false,
    },
    manuallyArchived: false,
    source: "manual",
    isRemote: false,
  };
}

describe("subagent hierarchy", () => {
  test("computes depth, descendants, and ownership recursively", () => {
    const root = card("root");
    const child = card("child", root.id);
    const grandchild = card("grandchild", child.id);
    const links = [root, child, grandchild];
    assert.equal(subagentDepth(root.id, links), 0);
    assert.equal(subagentDepth(grandchild.id, links), 2);
    assert.deepEqual(descendantIds(root.id, links), new Set([child.id, grandchild.id]));
    assert.doesNotThrow(() => assertOwnedSubagent(root, grandchild, links));
    assert.throws(() => assertOwnedSubagent(child, root, links), /not a subagent owned/);
  });

  test("bootstrap prompt teaches reporting and self-archive", () => {
    const prompt = buildSubagentPrompt({ ...card("root"), name: "Parent" }, "Investigate the bug");
    assert.match(prompt, /kanban parent dm <message>/);
    assert.match(prompt, /kanban parent dm-and-self-archive <message>/);
    assert.match(prompt, /Investigate the bug/);
  });

  test("bootstrap prompt explains the per-card compaction threshold", () => {
    const prompt = buildSubagentPrompt(
      { ...card("root"), name: "Parent" },
      "Investigate the bug",
      250_000
    );
    assert.match(prompt, /250k context threshold/);
    assert.match(prompt, /kanban self-compact/);
    assert.match(prompt, /post-compact continuation message/);
    assert.match(prompt, /450k tokens/);
  });

  test("depth error is explicit", () => {
    assert.equal(
      depthLimitError(1),
      "You already reached the user-defined maximum subagent depth of 1. You cannot spawn another subagent. Do the work yourself."
    );
  });

  test("missing fork transcript recommends a new spawn", () => {
    assert.equal(
      missingForkSessionError("root"),
      "Card root has no session to fork. Use `kanban subagent spawn` to start a new child instead."
    );
  });

  test("configured depth is bounded", () => {
    assert.equal(normalizeMaximumDepth(undefined), 1);
    assert.equal(normalizeMaximumDepth(-2), 0);
    assert.equal(normalizeMaximumDepth(99), 5);
  });

  test("multiline stdin preserves shell metacharacters and trailing whitespace", () => {
    const prompt = "line with `backticks` and $HOME\n'quotes' \n\n";
    assert.equal(resolveSubagentPrompt(["-"], prompt), prompt);
    assert.equal(resolveSubagentPrompt([], prompt), prompt);
    assert.equal(resolveSubagentPrompt(["positional", "$value"], "ignored"), "positional $value");
  });
});

describe("subagent command transport", () => {
  test("round-trips a response through the app inbox protocol", async () => {
    const home = mkdtempSync(join(tmpdir(), "kanban-subagent-command-"));
    const old = process.env.KANBAN_CODE_HOME;
    process.env.KANBAN_CODE_HOME = home;
    try {
      const request = makeSubagentRequest("spawn", "root", {
        prompt: "hello",
        contextThresholdTokens: 250_000,
      });
      const response = await submitSubagentRequest(request, {
        timeoutMs: 2_000,
        notify: (id) => {
          const persisted = JSON.parse(
            readFileSync(join(home, "commands", "inbox", `${id}.json`), "utf8")
          );
          assert.equal(persisted.contextThresholdTokens, 250_000);
          const responses = join(home, "commands", "responses");
          mkdirSync(responses, { recursive: true });
          writeFileSync(join(responses, `${id}.json`), JSON.stringify({ id, ok: true, cardId: "child" }));
        },
      });
      assert.equal(response.cardId, "child");
      assert.equal(request.contextThresholdTokens, 250_000);
    } finally {
      if (old === undefined) delete process.env.KANBAN_CODE_HOME;
      else process.env.KANBAN_CODE_HOME = old;
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("removes an unclaimed request after timeout", async () => {
    const home = mkdtempSync(join(tmpdir(), "kanban-subagent-timeout-"));
    const old = process.env.KANBAN_CODE_HOME;
    process.env.KANBAN_CODE_HOME = home;
    try {
      const request = makeSubagentRequest("spawn", "root", { prompt: "hello" });
      await assert.rejects(
        submitSubagentRequest(request, { timeoutMs: 20, notify: () => {} }),
        /within 1 seconds/
      );
      assert.equal(
        existsSync(join(home, "commands", "inbox", `${request.id}.json`)),
        false
      );
    } finally {
      if (old === undefined) delete process.env.KANBAN_CODE_HOME;
      else process.env.KANBAN_CODE_HOME = old;
      rmSync(home, { recursive: true, force: true });
    }
  });
});

describe("subagent list presentation", () => {
  test("shows hierarchy, assistant, model, token usage, and context", () => {
    const summary: CardSummary = {
      id: "child",
      name: "Investigate parser",
      column: "in_progress",
      assistant: "claude",
      modelOverride: "sonnet",
      selfCompactContextThresholdTokens: 250_000,
      subagentDepth: 1,
      tmuxAlive: true,
      prs: [],
      queuedPrompts: 0,
      isRemote: false,
      tokens: {
        input: 420_000,
        output: 10_000,
        cost: 1.25,
        context: { used: 430_000, max: 1_000_000, percentage: "43%" },
      },
    };

    const rendered = formatCardSummary(summary);
    assert.match(rendered, /depth:1/);
    assert.match(rendered, /claude/);
    assert.match(rendered, /model:sonnet/);
    assert.match(rendered, /compact:250k/);
    assert.match(rendered, /430k tok \$1\.25/);
    assert.match(rendered, /430k\/1\.0M ctx \(43%\)/);
  });
});
