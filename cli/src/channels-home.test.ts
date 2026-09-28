/**
 * Channels home proxy: which commands run on the home, what the request looks
 * like on the wire, and what happens when the home does not answer.
 */

import { strict as assert } from "node:assert";
import { execFile } from "node:child_process";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { afterEach, beforeEach, describe, test } from "node:test";
import {
  isReadOnlyChannelCommand,
  localCallerCardId,
  routesToChannelsHome,
  runOnChannelsHome,
} from "./channels-home.js";
import type { ChannelsHome } from "./machines.js";
import type { Link } from "./types.js";

const CLI = resolve(import.meta.dirname, "kanban.ts");
const run = promisify(execFile);

let home: string;
let server: Server | undefined;
let received: { headers: IncomingMessage["headers"]; body: any; url?: string }[];
let reply: (body: any) => { status: number; body: string };

function link(id: string, session?: string): Link {
  return {
    id,
    name: id,
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
    ...(session ? { tmuxLink: { sessionName: session } } : {}),
  };
}

async function startHome(): Promise<ChannelsHome> {
  server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(Buffer.from(c)));
    req.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf-8"));
      received.push({ headers: req.headers, body, url: req.url });
      const out = reply(body);
      res.writeHead(out.status, { "Content-Type": "application/json" });
      res.end(out.body);
    });
  });
  await new Promise<void>((done) => server!.listen(0, "127.0.0.1", done));
  const port = (server!.address() as AddressInfo).port;
  return { machineId: "box-id", name: "box", url: `http://127.0.0.1:${port}`, token: "secret" };
}

/** An address nothing listens on. */
async function deadHome(): Promise<ChannelsHome> {
  const probe = createServer();
  await new Promise<void>((done) => probe.listen(0, "127.0.0.1", done));
  const port = (probe.address() as AddressInfo).port;
  await new Promise<void>((done) => probe.close(() => done()));
  return { machineId: "box-id", name: "box", url: `http://127.0.0.1:${port}`, token: "secret" };
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "kanban-channels-home-"));
  received = [];
  reply = () => ({ status: 200, body: JSON.stringify({ stdout: "ok\n", stderr: "", code: 0 }) });
});

afterEach(async () => {
  if (server) await new Promise<void>((done) => server!.close(() => done()));
  server = undefined;
  rmSync(home, { recursive: true, force: true });
});

describe("routing", () => {
  test("channel and dm commands run on the home", () => {
    for (const argv of [
      ["channel", "send", "team", "hi"],
      ["channel", "list"],
      ["channel", "create", "team"],
      ["channel", "history", "team", "-n", "5"],
      ["dm", "@bob", "hi"],
      ["dm", "send", "@bob", "hi"],
      ["dm", "history", "@bob"],
    ]) {
      assert.equal(routesToChannelsHome(argv, {}), true, argv.join(" "));
    }
  });

  test("commands that open the app or host a server stay local", () => {
    for (const argv of [
      ["channel", "open", "team"],
      ["channel", "share", "team"],
      ["dm", "open", "@bob"],
      ["channel", "send", "--help"],
      ["channel"],
      ["list"],
      ["send", "card", "hi"],
    ]) {
      assert.equal(routesToChannelsHome(argv, {}), false, argv.join(" "));
    }
  });

  test("KANBAN_CHANNELS_LOCAL keeps everything local", () => {
    assert.equal(routesToChannelsHome(["channel", "send", "team", "hi"], { KANBAN_CHANNELS_LOCAL: "1" }), false);
  });

  test("read-only commands are the ones allowed to fall back", () => {
    assert.equal(isReadOnlyChannelCommand(["channel", "list"]), true);
    assert.equal(isReadOnlyChannelCommand(["channel", "history", "team"]), true);
    assert.equal(isReadOnlyChannelCommand(["channel", "members", "team"]), true);
    assert.equal(isReadOnlyChannelCommand(["dm", "history", "@bob"]), true);
    assert.equal(isReadOnlyChannelCommand(["channel", "send", "team", "hi"]), false);
    assert.equal(isReadOnlyChannelCommand(["dm", "@bob", "hi"]), false);
  });
});

describe("caller card", () => {
  const links = [link("card_env"), link("card_tmux", "session-t")];

  test("--as-card-id wins", () => {
    assert.equal(
      localCallerCardId(["channel", "send", "x", "hi", "--as-card-id", "card_x"], {
        links: () => links,
        env: { KANBAN_CARD_ID: "card_env" },
        tmuxSession: () => "session-t",
      }),
      "card_x"
    );
    assert.equal(localCallerCardId(["channel", "send", "--as-card-id=card_y"], { links: () => links }), "card_y");
  });

  test("then KANBAN_CARD_ID, then the tmux session", () => {
    assert.equal(
      localCallerCardId(["channel", "list"], {
        links: () => links,
        env: { KANBAN_CARD_ID: "card_env" },
        tmuxSession: () => "session-t",
      }),
      "card_env"
    );
    assert.equal(
      localCallerCardId(["channel", "list"], { links: () => links, env: {}, tmuxSession: () => "session-t" }),
      "card_tmux"
    );
    assert.equal(
      localCallerCardId(["channel", "list"], { links: () => links, env: {}, tmuxSession: () => undefined }),
      undefined
    );
  });

  test("--as-user has no card", () => {
    assert.equal(
      localCallerCardId(["channel", "send", "x", "hi", "--as-user"], {
        links: () => links,
        env: { KANBAN_CARD_ID: "card_env" },
      }),
      undefined
    );
  });
});

describe("runOnChannelsHome", () => {
  test("posts the invocation and writes the answer through", async () => {
    const target = await startHome();
    reply = () => ({ status: 200, body: JSON.stringify({ stdout: "sent\n", stderr: "note\n", code: 3 }) });
    let out = "";
    let err = "";
    const code = await runOnChannelsHome(["channel", "send", "team", "hi"], {
      home: target,
      humanHandle: "rchaves",
      cardId: "card_1",
      cwd: "/work",
      write: (t) => { out += t; },
      writeError: (t) => { err += t; },
    });
    assert.equal(code, 3);
    assert.equal(out, "sent\n");
    assert.equal(err, "note\n");
    assert.equal(received.length, 1);
    const [{ headers, body, url }] = received;
    assert.equal(url, "/v1/cli");
    assert.equal(headers.authorization, "Bearer secret");
    assert.match(String(headers["content-type"]), /application\/json/);
    assert.match(body.id, /^[0-9a-f-]{36}$/);
    assert.deepEqual(body.argv, ["channel", "send", "team", "hi"]);
    assert.equal(body.cwd, "/work");
    assert.deepEqual(body.env, { KANBAN_HUMAN_HANDLE: "rchaves", KANBAN_CARD_ID: "card_1" });
    assert.deepEqual(body.images, []);
    assert.equal("stdin" in body, false);
  });

  test("inlines images and repoints them where the home unpacks them", async () => {
    const target = await startHome();
    const image = join(home, "shot.png");
    writeFileSync(image, "png-bytes");
    await runOnChannelsHome(["channel", "send", "team", "look", "--image", image], {
      home: target,
      humanHandle: "rchaves",
      write: () => {},
      writeError: () => {},
    });
    const { body } = received[0];
    assert.deepEqual(body.argv, [
      "channel", "send", "team", "look", "--image", `~/.kanban-code/images/proxy/${body.id}/shot.png`,
    ]);
    assert.deepEqual(body.images, [{ name: "shot.png", base64: Buffer.from("png-bytes").toString("base64") }]);
    assert.equal(body.env.KANBAN_CARD_ID, undefined);
  });

  test("a read-only command falls back to the local copy when the home is down", async () => {
    let err = "";
    const outcome = await runOnChannelsHome(["channel", "history", "team"], {
      home: await deadHome(),
      humanHandle: "rchaves",
      write: () => {},
      writeError: (t) => { err += t; },
    });
    assert.equal(outcome, "local");
    assert.match(err, /^Showing the local copy of the channels: box did not answer \(.+\)\.\n$/);
  });

  test("a write fails when the home is down", async () => {
    const target = await deadHome();
    let err = "";
    const outcome = await runOnChannelsHome(["channel", "send", "team", "hi"], {
      home: target,
      humanHandle: "rchaves",
      write: () => {},
      writeError: (t) => { err += t; },
    });
    assert.equal(outcome, 1);
    assert.ok(err.startsWith(`Error: Channels live on box (${target.url}), which did not answer: `), err);
  });

  test("an HTTP error counts as not answering", async () => {
    const target = await startHome();
    reply = () => ({ status: 401, body: "unauthorized" });
    let err = "";
    const outcome = await runOnChannelsHome(["dm", "@bob", "hi"], {
      home: target,
      humanHandle: "rchaves",
      write: () => {},
      writeError: (t) => { err += t; },
    });
    assert.equal(outcome, 1);
    assert.match(err, /which did not answer: HTTP 401: unauthorized/);
  });

  test("a home that never answers times out", async () => {
    const target = await startHome();
    server!.removeAllListeners("request");
    server!.on("request", () => {});
    let err = "";
    const outcome = await runOnChannelsHome(["channel", "send", "team", "hi"], {
      home: target,
      humanHandle: "rchaves",
      timeoutMs: 200,
      write: () => {},
      writeError: (t) => { err += t; },
    });
    assert.equal(outcome, 1);
    assert.match(err, /which did not answer: timed out/);
    server!.closeAllConnections();
  });

  test("without channels-home.json the command runs locally", async () => {
    const previous = process.env.KANBAN_CODE_HOME;
    process.env.KANBAN_CODE_HOME = join(home, ".kanban-code");
    try {
      assert.equal(await runOnChannelsHome(["channel", "list"], { humanHandle: "x" }), "local");
    } finally {
      if (previous === undefined) delete process.env.KANBAN_CODE_HOME;
      else process.env.KANBAN_CODE_HOME = previous;
    }
  });
});

describe("CLI", () => {
  function cliEnv(extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env, HOME: home, KANBAN_CODE_HOME: join(home, ".kanban-code") };
    for (const key of ["KANBAN_CARD_ID", "TMUX", "KANBAN_REMOTE_PROXY", "KANBAN_CHANNELS_LOCAL", "KANBAN_HUMAN_HANDLE"]) {
      delete env[key];
    }
    return { ...env, ...extra };
  }

  async function cli(args: string[], env: NodeJS.ProcessEnv) {
    try {
      const { stdout, stderr } = await run("npx", ["tsx", CLI, ...args], { env, encoding: "utf-8" });
      return { stdout, stderr, code: 0 };
    } catch (e: any) {
      return { stdout: String(e.stdout ?? ""), stderr: String(e.stderr ?? ""), code: e.code ?? 1 };
    }
  }

  test("a paired machine runs channel commands on the home as its own caller", async () => {
    const target = await startHome();
    const kanbanHome = join(home, ".kanban-code");
    mkdirSync(kanbanHome, { recursive: true });
    writeFileSync(join(kanbanHome, "channels-home.json"), JSON.stringify(target));
    writeFileSync(join(kanbanHome, "links.json"), JSON.stringify({ links: [link("card_mac")] }));
    reply = () => ({ status: 200, body: JSON.stringify({ stdout: "from home\n", stderr: "", code: 0 }) });
    const result = await cli(
      ["channel", "send", "team", "hi"],
      cliEnv({ KANBAN_CARD_ID: "card_mac", KANBAN_HUMAN_HANDLE: "R Chaves" })
    );
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stdout, "from home\n");
    assert.deepEqual(received[0].body.env, { KANBAN_HUMAN_HANDLE: "r_chaves", KANBAN_CARD_ID: "card_mac" });
  });

  test("KANBAN_HUMAN_HANDLE names the human for --as-user", async () => {
    const result = await cli(
      ["channel", "create", "team", "--as-user", "--json"],
      cliEnv({ KANBAN_HUMAN_HANDLE: "R Chaves" })
    );
    assert.equal(result.code, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).joined.handle, "r_chaves");
  });

  test("kanban send hands a card another master owns to the inbox", async () => {
    const kanbanHome = join(home, ".kanban-code");
    mkdirSync(kanbanHome, { recursive: true });
    writeFileSync(join(kanbanHome, "machine.json"), JSON.stringify({ id: "box-id", name: "box" }));
    writeFileSync(
      join(kanbanHome, "links.json"),
      JSON.stringify({ links: [{ ...link("card_mac", "session-mac"), ownerMachine: "mac-id" }] })
    );
    const inbox = join(kanbanHome, "commands", "inbox");
    const responses = join(kanbanHome, "commands", "responses");
    let request: any;
    const master = setInterval(() => {
      if (!existsSync(inbox)) return;
      for (const file of readdirSync(inbox).filter((f) => f.endsWith(".json"))) {
        request = JSON.parse(readFileSync(join(inbox, file), "utf-8"));
        rmSync(join(inbox, file));
        mkdirSync(responses, { recursive: true });
        writeFileSync(join(responses, file), JSON.stringify({ id: request.id, ok: true }));
      }
    }, 20);
    try {
      const result = await cli(["send", "card_mac", "hello there"], cliEnv());
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.stdout, "Queued for card_mac via mac-id\n");
      assert.equal(request.operation, "enqueuePrompt");
      assert.equal(request.cardId, "card_mac");
      assert.equal(request.parentCardId, "card_mac");
      assert.equal(request.prompt, "hello there");
      assert.deepEqual(readdirSync(responses), []);
    } finally {
      clearInterval(master);
    }
  });
});
