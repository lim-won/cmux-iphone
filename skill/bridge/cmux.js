// cmux.js — mirror live cmux workspaces and inject prompts/approvals into them.
//
// Why this exists:
//   The stock bridge, for an external (cmux-owned) session, falls back to a
//   DETACHED `claude -p ... --continue` run — a separate headless process, NOT
//   the interactive agent you are watching. With cmux we instead type straight
//   into the live Claude/Codex terminal, so a prompt sent from the phone lands
//   in the exact session on screen.
//
// How (cmux >= 0.63.2, "mobile" RPC over the control socket):
//   - mobile.workspace.list           — the workspace/terminal tree
//   - mobile.terminal.replay          — a terminal's rendered screen
//   - mobile.terminal.input           — type text/keys into a terminal (UUID)
//   We resolve a session's cwd to a terminal UUID from the tree, then inject via
//   mobile.terminal.input. (The older `cmux top` + `cmux send --surface` path is
//   gone — `top` doesn't exist in current cmux and `send --surface <uuid>` is
//   rejected for mobile terminals.) These are private RPCs — see cmuxReachable().
//
// All cmux calls use execFile (no shell), run async (never block the loop), and
// are best-effort: on failure they throw and the caller falls back.

import { execFile, execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import crypto from "node:crypto";
import { promisify } from "node:util";

// Async exec so cmux calls never block Node's event loop (each can take ~8s).
// execFileSync is kept only for one-time module-load discovery (findCmuxBin).
const execFileP = promisify(execFile);

function findCmuxBin() {
  const envBin = process.env.CMUX_BIN;
  if (envBin) {
    try { fs.accessSync(envBin, fs.constants.X_OK); return envBin; } catch { /* ignore */ }
  }
  const candidates = [
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* continue */ }
  }
  try {
    const which = execFileSync("/usr/bin/which", ["cmux"], { encoding: "utf-8" }).trim();
    if (which) return which;
  } catch { /* fall through */ }
  return null;
}

const CMUX_BIN = findCmuxBin();

// Socket password (cmux socketControlMode=password). Lets the launchd bridge —
// which runs OUTSIDE cmux — authenticate to the cmux control socket.
const CMUX_PASSWORD = (() => {
  try {
    return fs.readFileSync(`${process.env.HOME}/.config/cmux-iphone/cmux-password`, "utf-8").trim() || null;
  } catch { return null; }
})();

function withAuth(args) {
  return CMUX_PASSWORD ? ["--password", CMUX_PASSWORD, ...args] : args;
}

async function cmux(args) {
  if (!CMUX_BIN) throw new Error("cmux binary not found");
  const { stdout } = await execFileP(CMUX_BIN, withAuth(args), { encoding: "utf-8", timeout: 8000 });
  return stdout;
}

export function cmuxAvailable() {
  return CMUX_BIN !== null;
}

// Real reachability: the binary exists AND the control socket answers an RPC.
// (cmuxAvailable() only checks the binary; cmux can be installed but not running,
// or the socket password not configured.) Used by setup/doctor to decide the
// runner and to surface an honest "cmux RPC FAIL".
export async function cmuxReachable() {
  if (!CMUX_BIN) return false;
  const data = await mobileWorkspaces();
  return data != null && Array.isArray(data.workspaces);
}

// Ensure an "Agent Bridge" cmux workspace exists, running the supervisor script
// INSIDE cmux (the only context that can drive the control socket). Idempotent:
// skips if one already exists. Returns { created }; throws if the RPC/CLI fails.
export async function ensureBridgeWorkspace(scriptPath) {
  const data = await mobileWorkspaces();
  if (data && Array.isArray(data.workspaces) && data.workspaces.some((w) => w.title === "Agent Bridge")) {
    return { created: false };
  }
  await cmux(["new-workspace", "--name", "Agent Bridge", "--command", String(scriptPath)]);
  return { created: true };
}

const norm = (p) => (typeof p === "string" ? p.replace(/\/+$/, "") : p);

// Resolve a session's cwd to a live cmux TERMINAL UUID (not a surface ref).
// Uses mobile.workspace.list (which works for mobile terminals, unlike `cmux
// top`) so the result can be fed to screenHash/readTerminalText/sendInput. This
// is what pins a codex approval to a specific terminal + screen hash.
export async function resolveTerminalId(cwd) {
  const data = await mobileWorkspaces();
  if (!data || !Array.isArray(data.workspaces)) return null;
  const target = norm(cwd);
  const terms = [];
  for (const w of data.workspaces) {
    if (w.title === "Agent Bridge") continue;
    for (const t of w.terminals || []) {
      terms.push({ id: t.id, cwd: norm(t.current_directory) });
    }
  }
  if (terms.length === 0) return null;
  if (target) {
    const exact = terms.find((t) => t.cwd === target);
    if (exact) return exact.id;
    const rel = terms.find(
      (t) => t.cwd && (target.startsWith(t.cwd + "/") || t.cwd.startsWith(target + "/"))
    );
    if (rel) return rel.id;
  }
  // Exactly one terminal overall — unambiguous.
  if (terms.length === 1) return terms[0].id;
  return null;
}

// Find the live terminal that is actually SHOWING a codex exec-approval prompt,
// so the answer ("y"/Esc) lands on the RIGHT pane. cwd alone is ambiguous (a
// shell and a codex pane share a cwd), and a command can linger in a shell's
// SCROLLBACK — so we look ONLY at the VISIBLE rows and require the codex
// approval markers ("Yes, proceed" + "No" option), which a plain shell never
// shows. The command only disambiguates among multiple visible approval screens.
// Returns:
//   { id }                  — exactly one terminal is visibly showing this approval
//   { id: null, ambiguous } — zero (no auto-pin) or many (fail closed)
const normScreen = (s) => String(s || "").replace(/\s+/g, " ").trim().toLowerCase();

// Pure selection logic (no cmux/IO) — unit-testable. Given each terminal's
// VISIBLE screen text, pick the one showing this approval command. A terminal
// is a candidate only if its visible screen has the codex approval markers
// ("Yes, proceed" + "No"); a plain shell (even with the command in scrollback)
// is excluded. The command disambiguates multiple visible approval screens.
//   entries: [{ id, text }]   text = VISIBLE rows only (no scrollback)
export function selectCodexApprovalTerminal(entries, command) {
  const cmdNeedle = normScreen(command).slice(0, 40);
  const candidates = [];
  for (const e of entries || []) {
    const n = normScreen(e.text);
    const isApprovalScreen = /yes,?\s+proceed/.test(n) && /\bno\b/.test(n);
    if (!isApprovalScreen) continue;
    candidates.push({ id: e.id, hasCmd: cmdNeedle.length >= 6 && n.includes(cmdNeedle) });
  }
  if (candidates.length === 0) return { id: null, ambiguous: false };
  if (candidates.length === 1) return { id: candidates[0].id, ambiguous: false };
  const byCmd = candidates.filter((c) => c.hasCmd);
  if (byCmd.length === 1) return { id: byCmd[0].id, ambiguous: false };
  return { id: null, ambiguous: true };
}

// Find the live terminal that is actually SHOWING a codex exec-approval prompt,
// so the answer ("y"/Esc) lands on the RIGHT pane. cwd alone is ambiguous (a
// shell and a codex pane share a cwd), and a command can linger in a shell's
// SCROLLBACK — so we read ONLY the VISIBLE rows and delegate to the pure
// selector above. Returns { id } (exactly one) or { id: null, ambiguous }.
export async function findCodexApprovalTerminal(command) {
  const data = await mobileWorkspaces();
  if (!data || !Array.isArray(data.workspaces)) return { id: null, ambiguous: false };

  const ids = [];
  for (const w of data.workspaces) {
    if (w.title === "Agent Bridge") continue;
    for (const t of w.terminals || []) ids.push(t.id);
  }
  if (ids.length === 0) return { id: null, ambiguous: false };

  const entries = [];
  for (const id of ids) {
    const vis = await readVisibleText(id);          // VISIBLE rows only — never scrollback
    if (vis) entries.push({ id, text: vis });
  }
  return selectCodexApprovalTerminal(entries, command);
}

// ---------------------------------------------------------------------------
// Mobile mirror API (cmux rpc) — drives the phone's live cmux view.
// ---------------------------------------------------------------------------

async function rpc(method, params) {
  if (!CMUX_BIN) throw new Error("cmux binary not found");
  const args = ["rpc", method];
  if (params !== undefined) args.push(JSON.stringify(params));
  const { stdout } = await execFileP(CMUX_BIN, withAuth(args), { encoding: "utf-8", timeout: 8000 });
  return stdout && stdout.trim() ? JSON.parse(stdout) : null;
}

// Full workspace → terminal tree for the mobile mirror.
// Returns the raw mobile.workspace.list payload (workspaces[].terminals[]).
export async function mobileWorkspaces() {
  if (!CMUX_BIN) return null;
  try {
    return await rpc("mobile.workspace.list");
  } catch {
    return null;
  }
}

// Plain-text rendering of a terminal/surface (accepts a UUID or surface ref).
// Reconstruct plain text lines from cmux render-grid spans
// ({row, column, text}). Pads gaps with spaces, preserves row order.
function spansToLines(spans) {
  const byRow = new Map();
  let maxRow = -1;
  for (const s of spans || []) {
    if (typeof s.row !== "number") continue;
    if (!byRow.has(s.row)) byRow.set(s.row, []);
    byRow.get(s.row).push(s);
    if (s.row > maxRow) maxRow = s.row;
  }
  const lines = [];
  for (let r = 0; r <= maxRow; r++) {
    const rs = byRow.get(r);
    if (!rs) { lines.push(""); continue; }
    rs.sort((a, b) => (a.column || 0) - (b.column || 0));
    let line = "";
    for (const s of rs) {
      const col = s.column || 0;
      if (col > line.length) line += " ".repeat(col - line.length);
      line += s.text || "";
    }
    lines.push(line.replace(/\s+$/, ""));
  }
  return lines;
}

// VISIBLE rows only (current viewport) — no scrollback. Used to detect a live
// codex approval prompt without matching stale commands in shell history.
export async function readVisibleText(id) {
  if (!CMUX_BIN || !id) return null;
  try {
    const r = await rpc("mobile.terminal.replay", { terminal_id: id });
    const rg = r && r.render_grid;
    if (!rg) return null;
    return spansToLines(rg.row_spans).join("\n");
  } catch {
    return null;
  }
}

// Plain-text screen of one terminal via mobile.terminal.replay, which (unlike
// surface.read_text) honors the terminal_id. Combines scrollback + visible.
export async function readTerminalText(id) {
  if (!CMUX_BIN || !id) return null;
  try {
    const r = await rpc("mobile.terminal.replay", { terminal_id: id });
    const rg = r && r.render_grid;
    if (!rg) return null;
    const lines = spansToLines(rg.scrollback_spans).concat(spansToLines(rg.row_spans));
    const text = lines.join("\n").replace(/^\n+/, "").replace(/\n{3,}/g, "\n\n");
    return text.split("\n").slice(-400).join("\n");
  } catch {
    return null;
  }
}

// Short hash of a terminal's current screen. Used to detect that the screen
// changed between when the phone rendered an approval and when the response is
// sent — so a "yes"/"no" can't land on a different prompt. Returns null if the
// screen can't be read.
export async function screenHash(id) {
  const t = await readTerminalText(id);
  if (t == null) return null;
  return crypto.createHash("sha256").update(t).digest("hex").slice(0, 16);
}

// Send text to a terminal by id, then submit with Enter (so prompts from the
// phone land in the live agent surface exactly as if typed).
export async function sendInput(terminalId, text, submit = true) {
  if (!CMUX_BIN || !terminalId) throw new Error("missing terminal id");
  await rpc("mobile.terminal.input", { terminal_id: terminalId, text: String(text) });
  if (submit) {
    try {
      await cmux(["send-key", "--surface", terminalId, "enter"]);
    } catch {
      await rpc("mobile.terminal.input", { terminal_id: terminalId, text: "\r" });
    }
  }
}

// Named special keys -> raw ANSI sequences, written through mobile.terminal.input
// (the only input path that actually reaches a cmux terminal — `cmux send-key
// --surface <uuid>` reports "Surface is not a terminal" for mobile terminals).
// Used to drive interactive TUI pickers (e.g. codex's "/model" popup) from the
// phone: arrows to move, enter to accept, escape to back out.
const KEY_SEQUENCES = {
  up: "\x1b[A",
  down: "\x1b[B",
  right: "\x1b[C",
  left: "\x1b[D",
  enter: "\r",
  escape: "\x1b",
  tab: "\t",
  backspace: "\x7f",
};

export function isNamedKey(key) {
  return Object.prototype.hasOwnProperty.call(KEY_SEQUENCES, key);
}

export async function sendNamedKey(terminalId, key) {
  if (!CMUX_BIN || !terminalId) throw new Error("missing terminal id");
  const seq = KEY_SEQUENCES[key];
  if (seq === undefined) throw new Error(`unsupported key: ${key}`);
  await rpc("mobile.terminal.input", { terminal_id: terminalId, text: seq });
}

// Stream cmux events (newline-delimited JSON). Calls onEvent(obj) per frame.
// Auto-reconnects (cmux --reconnect); the caller should respawn if the child
// exits (e.g. before the socket is reachable). Returns the child process.
export function streamEvents(onEvent) {
  if (!CMUX_BIN) return null;
  const child = spawn(CMUX_BIN, withAuth(["events", "--reconnect", "--no-heartbeat", "--no-ack"]), {
    stdio: ["ignore", "pipe", "ignore"],
  });
  let buf = "";
  child.stdout.on("data", (d) => {
    buf += d.toString();
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line) continue;
      try { onEvent(JSON.parse(line)); } catch { /* ignore non-JSON */ }
    }
  });
  return child;
}
