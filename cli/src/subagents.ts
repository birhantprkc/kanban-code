import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { cardForTmuxSession, currentTmuxSessionName } from "./broadcast.js";
import { readLinks, readSettings } from "./data.js";
import { commandInboxDir, commandResponsesDir } from "./paths.js";
import type { CodingAssistant, Link } from "./types.js";

export type SubagentOperation = "spawn" | "fork" | "archive" | "resume";

export interface SubagentCommandRequest {
  id: string;
  operation: SubagentOperation;
  createdAt: string;
  parentCardId: string;
  cardId?: string;
  prompt?: string;
  assistant?: CodingAssistant;
  model?: string;
}

export interface SubagentCommandResponse {
  id: string;
  ok: boolean;
  cardId?: string;
  error?: string;
}

export const depthLimitError = (maximumDepth: number): string =>
  `You already reached the user-defined maximum subagent depth of ${maximumDepth}. ` +
  "You cannot spawn another subagent. Do the work yourself.";

export const missingForkSessionError = (cardId: string): string =>
  `Card ${cardId} has no session to fork. ` +
  "Use `kanban subagent spawn` to start a new child instead.";

export const maximumSupportedSubagentDepth = 5;

export function resolveSubagentPrompt(args: string[], stdin: string): string {
  if (args.length > 0 && !(args.length === 1 && args[0] === "-")) {
    return args.join(" ");
  }
  return stdin;
}

export function normalizeMaximumDepth(value: number | undefined): number {
  return Math.min(maximumSupportedSubagentDepth, Math.max(0, value ?? 1));
}

export function subagentDepth(cardId: string, links: Link[]): number {
  const byId = new Map(links.map((link) => [link.id, link]));
  let current = byId.get(cardId);
  let depth = 0;
  const visited = new Set<string>();
  while (current?.parentCardId && !visited.has(current.id)) {
    visited.add(current.id);
    depth += 1;
    current = byId.get(current.parentCardId);
  }
  return depth;
}

export function descendantIds(cardId: string, links: Link[]): Set<string> {
  const childrenByParent = new Map<string, Link[]>();
  for (const link of links) {
    if (!link.parentCardId) continue;
    const children = childrenByParent.get(link.parentCardId) ?? [];
    children.push(link);
    childrenByParent.set(link.parentCardId, children);
  }
  const result = new Set<string>();
  const visited = new Set<string>([cardId]);
  const pending = [cardId];
  while (pending.length > 0) {
    const parentId = pending.pop()!;
    for (const child of childrenByParent.get(parentId) ?? []) {
      if (!visited.has(child.id)) {
        visited.add(child.id);
        result.add(child.id);
        pending.push(child.id);
      }
    }
  }
  return result;
}

export function currentCardOrThrow(links: Link[] = readLinks()): Link {
  const tmuxSession = currentTmuxSessionName();
  if (!tmuxSession) {
    throw new Error(
      "Could not detect the current tmux session. Run this command from an agent inside a Kanban Code card."
    );
  }
  const card = cardForTmuxSession(links, tmuxSession);
  if (!card || card.tmuxLink?.sessionName !== tmuxSession) {
    throw new Error(
      `Tmux session "${tmuxSession}" is not the primary assistant session of a Kanban Code card.`
    );
  }
  return card;
}

export function validateCanSpawn(parent: Link, links: Link[] = readLinks()): number {
  const maximumDepth = normalizeMaximumDepth(readSettings().subagents?.maximumDepth);
  if (maximumDepth === 0 || subagentDepth(parent.id, links) >= maximumDepth) {
    throw new Error(depthLimitError(maximumDepth));
  }
  return maximumDepth;
}

export function buildSubagentPrompt(parent: Link, childPrompt: string): string {
  return [
    `You are a Kanban Code subagent owned by card ${parent.id} (${parent.name ?? "untitled parent"}).`,
    "Work independently on the goal below.",
    "Use `kanban parent dm <message>` to report progress or ask the parent a question.",
    "When the goal is fully reached, use `kanban parent dm-and-self-archive <message>` to report the result and archive yourself.",
    "The parent can resume you later if follow-up work is needed.",
    "",
    "Goal:",
    childPrompt,
  ].join("\n");
}

export function assertOwnedSubagent(caller: Link, target: Link, links: Link[]): void {
  if (!descendantIds(caller.id, links).has(target.id)) {
    throw new Error(`Card ${target.id} is not a subagent owned by ${caller.id}.`);
  }
}

export function makeSubagentRequest(
  operation: SubagentOperation,
  parentCardId: string,
  fields: Omit<Partial<SubagentCommandRequest>, "id" | "operation" | "createdAt" | "parentCardId"> = {}
): SubagentCommandRequest {
  return {
    id: randomUUID().toLowerCase(),
    operation,
    createdAt: new Date().toISOString(),
    parentCardId,
    ...fields,
  };
}

export interface SubmitSubagentRequestOptions {
  timeoutMs?: number;
  notify?: (requestId: string) => void;
}

export async function submitSubagentRequest(
  request: SubagentCommandRequest,
  options: SubmitSubagentRequestOptions = {}
): Promise<SubagentCommandResponse> {
  const inbox = commandInboxDir();
  const responses = commandResponsesDir();
  mkdirSync(inbox, { recursive: true });
  mkdirSync(responses, { recursive: true });
  const requestPath = join(inbox, `${request.id}.json`);
  const tempPath = `${requestPath}.tmp`;
  const responsePath = join(responses, `${request.id}.json`);
  writeFileSync(tempPath, JSON.stringify(request, null, 2));
  renameSync(tempPath, requestPath);

  const notify = options.notify ?? ((requestId: string) => {
    execFileSync("open", ["-g", `kanbancode://command/${requestId}`], { stdio: "ignore" });
  });
  try {
    notify(request.id);
  } catch (error) {
    rmSync(requestPath, { force: true });
    throw new Error(`Could not contact Kanban Code: ${String(error)}`);
  }

  const timeoutMs = options.timeoutMs ?? 120_000;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(responsePath)) {
      let response: SubagentCommandResponse;
      try {
        response = JSON.parse(readFileSync(responsePath, "utf-8")) as SubagentCommandResponse;
      } catch (error) {
        rmSync(responsePath, { force: true });
        rmSync(requestPath, { force: true });
        throw new Error(`Kanban Code returned an invalid subagent response: ${String(error)}`);
      }
      rmSync(responsePath, { force: true });
      rmSync(requestPath, { force: true });
      if (response.id !== request.id) {
        throw new Error(
          `Kanban Code returned a mismatched subagent response: expected ${request.id}, received ${response.id}.`
        );
      }
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  rmSync(requestPath, { force: true });
  rmSync(tempPath, { force: true });
  throw new Error(
    `Kanban Code did not process the subagent command within ${Math.ceil(timeoutMs / 1_000)} seconds.`
  );
}
