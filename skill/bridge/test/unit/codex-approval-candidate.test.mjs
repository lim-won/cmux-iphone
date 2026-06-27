// Pure unit tests for Codex approval candidate detection from session JSONL.

import { test } from "node:test";
import assert from "node:assert/strict";
import { buildCodexExecApprovalCandidate } from "../../lib/codex-approval.js";

test("builds a candidate for escalated exec_command calls", () => {
  const candidate = buildCodexExecApprovalCandidate("exec_command", {
    cmd: "npm install",
    workdir: "/tmp/project",
    sandbox_permissions: "require_escalated",
    justification: "Install dependencies?",
    prefix_rule: ["npm", "install"],
  }, "", 1234);

  assert.deepEqual(candidate, {
    command: "npm install",
    justification: "Install dependencies?",
    workdir: "/tmp/project",
    prefixRule: ["npm", "install"],
    createdAt: 1234,
  });
});

test("uses fallback cwd and default justification when optional fields are absent", () => {
  const candidate = buildCodexExecApprovalCandidate("functions.exec_command", {
    cmd: "curl https://example.com",
    sandbox_permissions: "require_escalated",
  }, "/tmp/fallback", 5678);

  assert.equal(candidate.workdir, "/tmp/fallback");
  assert.equal(candidate.justification, "Would you like to run this command?");
  assert.deepEqual(candidate.prefixRule, []);
});

test("ignores non-escalated or unrelated tool calls", () => {
  assert.equal(buildCodexExecApprovalCandidate("exec_command", { cmd: "pwd" }), null);
  assert.equal(buildCodexExecApprovalCandidate("apply_patch", {
    sandbox_permissions: "require_escalated",
  }), null);
});
