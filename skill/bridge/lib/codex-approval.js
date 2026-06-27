// Helpers for detecting Codex approval-worthy tool calls from session JSONL.

const CODEX_EXEC_TOOL_NAMES = new Set(["exec_command", "functions.exec_command"]);

function stringOrEmpty(value) {
  return typeof value === "string" ? value : "";
}

export function buildCodexExecApprovalCandidate(toolName, args, fallbackWorkdir = "", now = Date.now()) {
  if (!CODEX_EXEC_TOOL_NAMES.has(toolName)) return null;
  if (!args || typeof args !== "object") return null;
  if (args.sandbox_permissions !== "require_escalated") return null;

  return {
    command: stringOrEmpty(args.cmd),
    justification: stringOrEmpty(args.justification) || "Would you like to run this command?",
    workdir: stringOrEmpty(args.workdir) || stringOrEmpty(fallbackWorkdir),
    prefixRule: Array.isArray(args.prefix_rule) ? args.prefix_rule : [],
    createdAt: now,
  };
}
