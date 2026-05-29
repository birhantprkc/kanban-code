/// Formats Claude Code transcript (.jsonl) lines into Slack messages, porting
/// the rendering lessons from Kanban Code's chat view (TranscriptReader):
/// compact tool labels, merged consecutive assistant lines, summarized results.

export interface SlackPost {
  role: "assistant" | "user";
  text: string; // Slack mrkdwn
}

const MAX_TEXT = 2800; // keep individual posts readable / within Slack block limits

function truncate(s: string, max = MAX_TEXT): string {
  const t = s.trim();
  return t.length > max ? t.slice(0, max) + "…" : t;
}

/// Header shown above each mirrored prompt. It marks the text as the input the
/// agent received (not the agent's own reply), so a reader can tell the two
/// apart in the channel.
export const RECEIVED_MESSAGE_HEADER = ">>> Received user message";

/// Format an injected prompt for the channel: the header, then the body in
/// italics (Slack mrkdwn uses _underscores_ for italic; * and ** do not work).
export function formatReceivedMessage(text: string): string {
  return `${RECEIVED_MESSAGE_HEADER}\n\n_${text}_`;
}

/// Keep the last 3 path components (mirrors TranscriptReader.shortenPath).
export function shortenPath(path: string): string {
  const parts = path.split("/").filter(Boolean);
  if (parts.length <= 3) return path;
  return ".../" + parts.slice(-3).join("/");
}

/// Compact one-line label for a tool_use block (mirrors extractToolInfo +
/// the special-tool cases of parseToolUse).
export function toolLabel(name: string, input: Record<string, any> = {}): string {
  switch (name) {
    case "Bash": {
      const display = input.description || String(input.command ?? "").slice(0, 200);
      return `Bash(${display})`;
    }
    case "Read":
    case "Write":
    case "Edit":
    case "NotebookEdit":
      return `${name}(${shortenPath(String(input.file_path ?? ""))})`;
    case "Grep": {
      const pathPart = input.path ? ` in ${shortenPath(String(input.path))}` : "";
      return `Grep("${input.pattern ?? ""}"${pathPart})`;
    }
    case "Glob":
      return `Glob(${input.pattern ?? ""})`;
    case "Agent":
      return `Agent(${input.description || String(input.prompt ?? "").slice(0, 80)})`;
    case "Skill":
      return `Skill(${input.skill ?? ""})`;
    case "TaskCreate":
      return `TaskCreate(${input.subject ?? ""})`;
    case "TaskUpdate":
      return `TaskUpdate(${input.status ? `${input.taskId}: ${input.status}` : input.taskId ?? ""})`;
    case "EnterPlanMode":
      return "📋 entered plan mode";
    case "ExitPlanMode":
      return `📋 exit plan mode${input.plan ? `\n${truncate(String(input.plan), 1500)}` : ""}`;
    case "AskUserQuestion": {
      const qs = (input.questions ?? []).map((q: any) => `• ${q.question}`).join("\n");
      return `❓ asking:\n${qs}`;
    }
    default:
      return `${name}(…)`;
  }
}

/// Tools whose label is emoji-prefixed prose (status / plan / questions), not a
/// command. These render as plain text; everything else is a command-style
/// label shown in a fenced code block.
const PROSE_TOOLS = new Set(["EnterPlanMode", "ExitPlanMode", "AskUserQuestion"]);

/// Wrap a command-style tool label in a triple-backtick code block.
function fenceBlock(label: string): string {
  return "```\n" + label + "\n```";
}

/// Render one assistant message's content blocks into Slack mrkdwn.
function renderAssistantContent(content: any): string {
  if (typeof content === "string") return truncate(content);
  if (!Array.isArray(content)) return "";

  const parts: string[] = [];
  for (const block of content) {
    switch (block?.type) {
      case "text":
        if (block.text?.trim()) parts.push(truncate(block.text));
        break;
      case "thinking":
        if (block.thinking?.trim()) parts.push(`💭 _${truncate(block.thinking, 280)}_`);
        break;
      case "tool_use": {
        const label = toolLabel(block.name, block.input ?? {});
        parts.push(PROSE_TOOLS.has(block.name) ? label : fenceBlock(label));
        break;
      }
      default:
        break;
    }
  }
  return parts.join("\n");
}

function role(obj: any): string | undefined {
  return obj?.type ?? obj?.message?.role;
}

/// Convert a batch of transcript lines into Slack posts, merging consecutive
/// assistant lines (Claude writes thinking and the reply on separate lines) into
/// one logical message. User turns and tool_result lines are not emitted here —
/// the bridge posts agent activity; relayed human messages already appear in
/// Slack, and automated prompts are announced separately.
export function formatTranscriptLines(objs: any[]): SlackPost[] {
  const posts: SlackPost[] = [];
  let buffer: string[] = [];

  const flush = () => {
    const text = buffer.join("\n").trim();
    if (text) posts.push({ role: "assistant", text });
    buffer = [];
  };

  for (const obj of objs) {
    if (role(obj) === "assistant") {
      const rendered = renderAssistantContent(obj.message?.content ?? obj.content);
      if (rendered) buffer.push(rendered);
    } else {
      flush();
    }
  }
  flush();
  return posts;
}

/// Format Codex rollout (.jsonl) records into Slack posts. Codex logs a stream
/// of records; we mirror the prompts the agent receives (user_message), the
/// agent's own messages (its "movement"), and the commands it runs, skipping
/// reasoning/system noise so the channel reads like the Claude mirror. Codex
/// gates command hooks behind a trust prompt, so this rollout tail is also how
/// a received prompt is announced (the Claude path uses the UserPromptSubmit
/// hook). Event shapes: event_msg{payload:{type:"user_message",message}} for an
/// injected prompt, {type:"agent_message",message} for assistant text, and
/// {type:"exec_command_begin",command} for shell runs. When Codex is out of
/// credits the turn ends with task_complete{last_agent_message:null} and the
/// preceding token_count carries rate_limits.credits.has_credits=false; we
/// mirror that as an explicit warning so the channel does not sit on a bare
/// "Received user message" with no explanation.
export function formatCodexRolloutLines(objs: any[]): SlackPost[] {
  const posts: SlackPost[] = [];
  let credits: { has_credits?: boolean; balance?: string } | undefined;
  let planType: string | undefined;
  for (const o of objs) {
    if (o?.type !== "event_msg") continue;
    const p = o.payload ?? {};
    if (p.type === "user_message" && typeof p.message === "string" && p.message.trim()) {
      posts.push({ role: "user", text: formatReceivedMessage(truncate(p.message)) });
    } else if (p.type === "agent_message" && typeof p.message === "string" && p.message.trim()) {
      posts.push({ role: "assistant", text: truncate(p.message) });
    } else if (p.type === "exec_command_begin") {
      const cmd = Array.isArray(p.command) ? p.command.join(" ") : String(p.command ?? "");
      if (cmd.trim()) posts.push({ role: "assistant", text: fenceBlock(`$ ${truncate(cmd, 300)}`) });
    } else if (p.type === "token_count" && p.rate_limits?.credits) {
      credits = p.rate_limits.credits;
      planType = p.rate_limits.plan_type;
    } else if (p.type === "task_complete" && p.last_agent_message == null && credits?.has_credits === false) {
      // Prompt was received but the turn produced no output because Codex ran
      // out of credits. Surface it instead of mirroring silence.
      const plan = planType ? ` (plan: ${planType}, balance ${credits.balance ?? "0"})` : "";
      posts.push({
        role: "assistant",
        text: `:warning: Codex is out of credits${plan}. The prompt was received but no output was produced, and this will keep failing until credits are topped up at https://chatgpt.com/codex/settings/usage`,
      });
    }
  }
  return posts;
}
