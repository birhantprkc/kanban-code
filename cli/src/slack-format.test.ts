import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { shortenPath, toolLabel, formatTranscriptLines } from "./slack/format.js";

describe("shortenPath", () => {
  test("keeps short paths, trims long ones to last 3", () => {
    assert.equal(shortenPath("src/a.ts"), "src/a.ts");
    assert.equal(shortenPath("/a/b/c/d/e.ts"), ".../c/d/e.ts");
  });
});

describe("toolLabel", () => {
  test("Bash prefers description, falls back to command", () => {
    assert.equal(toolLabel("Bash", { description: "run tests", command: "npm test" }), "Bash(run tests)");
    assert.equal(toolLabel("Bash", { command: "npm test" }), "Bash(npm test)");
  });
  test("file tools shorten the path", () => {
    assert.equal(toolLabel("Read", { file_path: "/x/y/z/w/file.ts" }), "Read(.../z/w/file.ts)");
    assert.equal(toolLabel("Edit", { file_path: "a/b.ts" }), "Edit(a/b.ts)");
  });
  test("Grep shows pattern and optional path", () => {
    assert.equal(toolLabel("Grep", { pattern: "foo", path: "/a/b/c/d" }), 'Grep("foo" in .../b/c/d)');
    assert.equal(toolLabel("Grep", { pattern: "foo" }), 'Grep("foo")');
  });
  test("Skill, TaskUpdate, plan + question tools", () => {
    assert.equal(toolLabel("Skill", { skill: "drive-pr" }), "Skill(drive-pr)");
    assert.equal(toolLabel("TaskUpdate", { taskId: "3", status: "completed" }), "TaskUpdate(3: completed)");
    assert.equal(toolLabel("EnterPlanMode", {}), "📋 entered plan mode");
    assert.match(toolLabel("AskUserQuestion", { questions: [{ question: "Ship it?" }] }), /❓ asking:\n• Ship it\?/);
  });
});

describe("formatTranscriptLines", () => {
  const asst = (content: any) => ({ type: "assistant", message: { role: "assistant", content } });
  const usr = (content: any) => ({ type: "user", message: { role: "user", content } });

  test("emits one post per content block with the right kind", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "thinking", thinking: "let me check the deps" }]),
      asst([
        { type: "text", text: "Reviewing the bump." },
        { type: "tool_use", name: "Bash", input: { description: "run tests" } },
      ]),
    ]);
    // 3 blocks total, so 3 posts (text/tool/thinking each routed independently
    // by the bridge: text -> channel root, tool/thinking -> in-thread).
    assert.equal(posts.length, 3);
    assert.deepEqual(
      posts.map((p) => p.kind),
      ["thinking", "text", "tool"]
    );
    assert.match(posts[0].text, /💭 _let me check the deps_/);
    assert.equal(posts[1].text, "Reviewing the bump.");
    assert.match(posts[2].text, /```\nBash\(run tests\)\n```/);
    assert.ok(posts.every((p) => p.role === "assistant"));
  });

  test("coalesces consecutive tool posts into one (debounce against Slack rate limits)", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "text", text: "Checking the PR." }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "view PR" } }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "view diff" } }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "view checks" } }]),
    ]);
    // The 3 Bash calls fold into 1 tool post (single Slack API call instead
    // of 3); the text post stays separate so it can anchor the new thread.
    assert.equal(posts.length, 2);
    assert.equal(posts[0].kind, "text");
    assert.equal(posts[0].text, "Checking the PR.");
    assert.equal(posts[1].kind, "tool");
    assert.match(posts[1].text, /Bash\(view PR\)/);
    assert.match(posts[1].text, /Bash\(view diff\)/);
    assert.match(posts[1].text, /Bash\(view checks\)/);
  });

  test("a text post in the middle breaks the tool coalescing run", () => {
    // Real-world shape: tools, then the agent says something, then more tools.
    // The new text must anchor a new thread, so the second tool run can't fold
    // into the first.
    const posts = formatTranscriptLines([
      asst([{ type: "tool_use", name: "Bash", input: { description: "a" } }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "b" } }]),
      asst([{ type: "text", text: "Found two." }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "c" } }]),
    ]);
    assert.equal(posts.length, 3);
    assert.deepEqual(
      posts.map((p) => p.kind),
      ["tool", "text", "tool"]
    );
    assert.match(posts[0].text, /Bash\(a\)/);
    assert.match(posts[0].text, /Bash\(b\)/);
    assert.equal(posts[1].text, "Found two.");
    assert.match(posts[2].text, /Bash\(c\)/);
  });

  test("emoji/prose tool labels are not fenced and still coalesce as tool", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "tool_use", name: "AskUserQuestion", input: { questions: [{ question: "Ship it?" }] } }]),
    ]);
    assert.equal(posts.length, 1);
    assert.equal(posts[0].kind, "tool");
    assert.doesNotMatch(posts[0].text, /```/);
    assert.match(posts[0].text, /❓ asking:/);
  });

  test("user turns (incl. tool_result lines) are not emitted", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "text", text: "first" }]),
      usr([{ type: "tool_result", tool_use_id: "t1", content: "huge output..." }]),
      usr("a human steering message"),
      asst([{ type: "text", text: "second" }]),
    ]);
    // 2 text posts, both as root-bound; the human message + tool_result are
    // dropped (the human already sees their own Slack message; tool results
    // are the noise we're trying to hide).
    assert.equal(posts.length, 2);
    assert.deepEqual(
      posts.map((p) => ({ kind: p.kind, text: p.text })),
      [
        { kind: "text", text: "first" },
        { kind: "text", text: "second" },
      ]
    );
  });

  test("empty assistant content produces no post", () => {
    const posts = formatTranscriptLines([asst([{ type: "text", text: "   " }])]);
    assert.equal(posts.length, 0);
  });

  test("tool and thinking posts carry a short statusLabel for the slack pill", () => {
    const posts = formatTranscriptLines([
      asst([{ type: "thinking", thinking: "let me check" }]),
      asst([{ type: "tool_use", name: "Bash", input: { description: "view PR" } }]),
      asst([{ type: "tool_use", name: "Read", input: { file_path: "/a/b/c/d.ts" } }]),
      asst([{ type: "text", text: "Done." }]),
    ]);
    // 3 in-thread posts (thinking + 2 tools fold into 1) + 1 root text.
    assert.equal(posts.length, 3);
    assert.equal(posts[0].kind, "thinking");
    assert.equal(posts[0].statusLabel, "💭 thinking…");
    assert.equal(posts[1].kind, "tool");
    // After coalescing, the latest tool's label wins so the pill tracks
    // current activity, not the first one in the batch.
    assert.equal(posts[1].statusLabel, "🛠️ Read(.../b/c/d.ts)…");
    assert.equal(posts[2].kind, "text");
    assert.equal(posts[2].statusLabel, undefined);
  });

  test("a very long Bash description in the status label is truncated", () => {
    const desc = "x".repeat(200);
    const posts = formatTranscriptLines([
      asst([{ type: "tool_use", name: "Bash", input: { description: desc } }]),
    ]);
    // Status width is capped — we do not want the pill to overflow Slack's UI.
    assert.equal(posts.length, 1);
    assert.ok((posts[0].statusLabel ?? "").length <= "🛠️ ".length + 80 + 2,
      `statusLabel too long: ${posts[0].statusLabel}`);
    assert.match(posts[0].statusLabel ?? "", /^🛠️ Bash\(.*…$/);
  });
});
