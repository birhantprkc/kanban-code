import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parsePicker, stripAnsi } from "./slack/picker.js";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const fixture = (name: string) => readFileSync(join(HERE, "slack/__fixtures__", name), "utf-8");

describe("stripAnsi", () => {
  test("removes CSI color sequences but keeps content", () => {
    assert.equal(stripAnsi("\x1b[38;5;246m  1.\x1b[39m hi"), "  1. hi");
    assert.equal(stripAnsi("plain"), "plain");
  });
});

describe("parsePicker", () => {
  test("returns null when no picker footer is present", () => {
    assert.equal(parsePicker("just some agent output\n  no picker here\n"), null);
  });

  test("parses a real captured pane from the live dependabot-scout picker", () => {
    const pane = fixture("picker-dependabot.txt");
    const picker = parsePicker(pane);
    assert.ok(picker, "should detect the picker");
    assert.equal(picker!.question, "Plan for the redundant Dependabot PRs once my security PR is up?");
    assert.equal(picker!.options.length, 3, "drops 'Type something.' and 'Chat about this'");
    assert.deepEqual(
      picker!.options.map((o) => ({ n: o.number, t: o.title })),
      [
        { n: 1, t: "Close #4416 only" },
        { n: 2, t: "Close #4416 and #4427" },
        { n: 3, t: "Close none, just comment" },
      ]
    );
    assert.match(picker!.options[0].description!, /supersedes/);
    assert.match(picker!.hash, /^[0-9a-f]{8}$/);
  });

  test("hash is stable across re-runs and changes when content changes", () => {
    const pane = fixture("picker-dependabot.txt");
    const a = parsePicker(pane)!;
    const b = parsePicker(pane)!;
    assert.equal(a.hash, b.hash);
    const pane2 = pane.replace("Close none, just comment", "Close none and watch");
    const c = parsePicker(pane2)!;
    assert.notEqual(a.hash, c.hash);
  });

  test("when two pickers are in the snapshot, the bottom-most (active) one wins", () => {
    const earlier = [
      "Older question?",
      "❯ 1. Old option A",
      "     desc A",
      "  2. Old option B",
      "     desc B",
      "  3. Type something.",
      "  4. Chat about this",
      "",
      "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
      "",
      "  (some unrelated output in between)",
      "",
      "Newer question?",
      "❯ 1. New option A",
      "     desc new A",
      "  2. New option B",
      "     desc new B",
      "  3. Type something.",
      "  4. Chat about this",
      "",
      "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
      "",
    ].join("\n");
    const picker = parsePicker(earlier)!;
    assert.equal(picker.question, "Newer question?");
    assert.deepEqual(picker.options.map((o) => o.title), ["New option A", "New option B"]);
  });

  test("does not match a stray numbered list that lacks the footer", () => {
    const benign = [
      "Here is a list of PRs:",
      "  1. fix(foo): bar",
      "  2. feat(baz): qux",
      "  3. chore(deps): bump",
      "",
      "(end of list)",
    ].join("\n");
    assert.equal(parsePicker(benign), null);
  });

  test("parses the footer-less 'Review your answers' submit picker", () => {
    const pane = fixture("picker-review-answers.txt");
    const picker = parsePicker(pane);
    assert.ok(picker, "should detect the submit picker even without 'Enter to select' footer");
    assert.equal(picker!.question, "Ready to submit your answers?");
    assert.deepEqual(
      picker!.options.map((o) => ({ n: o.number, t: o.title })),
      [
        { n: 1, t: "Submit answers" },
        { n: 2, t: "Cancel" },
      ]
    );
  });

  test("strips ANSI before matching so a colored ❯ caret still counts", () => {
    const pane = [
      "Pick one?",
      "\x1b[38;5;153m❯\x1b[39m \x1b[38;5;246m1.\x1b[39m Option one",
      "  \x1b[38;5;246m2.\x1b[39m Option two",
      "",
      "\x1b[38;5;246mEnter to select · Tab/Arrow keys to navigate · Esc to cancel\x1b[39m",
    ].join("\n");
    const p = parsePicker(pane)!;
    assert.equal(p.question, "Pick one?");
    assert.deepEqual(p.options.map((o) => o.title), ["Option one", "Option two"]);
  });
});
