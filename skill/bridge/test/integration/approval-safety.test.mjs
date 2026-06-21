// Integration tests for the bridge's approval-safety invariants.
//
// Runs against the LIVE bridge (127.0.0.1:7860) + live cmux. Spins up throwaway
// cmux workspaces, asserts, and tears them down.
//
// Gating: set CW_INTEGRATION=1 to REQUIRE the prerequisites (running bridge,
// cmux, token); missing prereqs then FAIL — this is the real integration gate
// (`npm run test:integration`). Without that env var the tests SKIP, so a plain
// `npm test` (unit only) never silently passes against a dead/absent daemon.
//
//   CW_INTEGRATION=1 node --test test/integration/

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const execFileP = promisify(execFile);
const API = "http://127.0.0.1:7860";

const PW = readMaybe(path.join(os.homedir(), ".config", "cmux-iphone", "cmux-password"));
const TOKEN = readMaybe(path.join(os.homedir(), "Library", "Application Support", "cmux-iphone", "session-token"));

function readMaybe(p) {
  try { return fs.readFileSync(p, "utf-8").trim() || null; } catch { return null; }
}

function findCmuxBin() {
  for (const p of ["/usr/local/bin/cmux", "/opt/homebrew/bin/cmux", `${os.homedir()}/.local/bin/cmux`]) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}
const CMUX = findCmuxBin();

async function cmux(args) {
  const full = PW ? ["--password", PW, ...args] : args;
  const { stdout } = await execFileP(CMUX, full, { encoding: "utf-8", timeout: 8000 });
  return stdout;
}
async function rpc(method, params) {
  const out = await cmux(["rpc", method, ...(params !== undefined ? [JSON.stringify(params)] : [])]);
  return out && out.trim() ? JSON.parse(out) : null;
}

async function http(method, route, { token, body } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${API}${route}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  let json = null;
  try { json = await res.json(); } catch { /* non-JSON */ }
  return { status: res.status, json };
}

// --- scratch workspace lifecycle -------------------------------------------
const scratch = [];   // workspace refs to clean up
async function newScratch(name, command) {
  const args = ["new-workspace", "--name", name, "--cwd", "/tmp"];
  if (command) args.push("--command", command);
  const out = await cmux(args);
  const ref = (out.match(/workspace:\d+/) || [])[0];
  if (ref) scratch.push(ref);
  await sleep(1300);
  // resolve the terminal id for this workspace
  const data = await rpc("mobile.workspace.list");
  for (const w of data?.workspaces || []) {
    if (w.title === name) return (w.terminals || [])[0]?.id || null;
  }
  return null;
}
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
async function typeInto(id, text) { await rpc("mobile.terminal.input", { terminal_id: id, text }); }

const INTEGRATION = process.env.CW_INTEGRATION === "1";
let prereqOK = false;
let prereqReason = "";

before(async () => {
  if (!CMUX) prereqReason = "cmux binary not found";
  else if (!PW) prereqReason = "cmux password file missing";
  else if (!TOKEN) prereqReason = "bridge session token missing";
  else {
    try {
      const h = await http("GET", "/health");
      if (h.status === 200) prereqOK = true;
      else prereqReason = `/health returned ${h.status}`;
    } catch (e) { prereqReason = `bridge unreachable: ${e.message}`; }
  }
  // In integration mode a missing prerequisite is a FAILURE, not a skip.
  if (!prereqOK && INTEGRATION) {
    throw new Error(`CW_INTEGRATION=1 but prerequisites unmet: ${prereqReason}`);
  }
});

after(async () => {
  for (const ref of scratch) {
    try { await cmux(["close-workspace", "--workspace", ref]); } catch { /* ignore */ }
  }
});

function need(t) {
  if (!prereqOK) { t.skip(`prereqs unmet (${prereqReason}); set CW_INTEGRATION=1 to require them`); return false; }
  return true;
}

// --- 1) health public, status authed ---------------------------------------
test("GET /health is public and leaks no session data", async (t) => {
  if (!need(t)) return;
  const r = await http("GET", "/health");
  assert.equal(r.status, 200, "/health should be 200 without auth");
  assert.equal(r.json.ok, true);
  assert.equal(r.json.sessions, undefined, "/health must not expose sessions/cwd");
});

test("GET /status requires auth", async (t) => {
  if (!need(t)) return;
  const noAuth = await http("GET", "/status");
  assert.equal(noAuth.status, 401, "/status without token should be 401");
  const authed = await http("GET", "/status", { token: TOKEN });
  assert.equal(authed.status, 200, "/status with token should be 200");
});

// --- 2) key route allowlist -------------------------------------------------
test("POST /command key route: named keys allowed, junk rejected", async (t) => {
  if (!need(t)) return;
  const id = await newScratch("test-keyroute");
  assert.ok(id, "scratch terminal created");
  const up = await http("POST", "/command", { token: TOKEN, body: { terminalId: id, key: "up" } });
  assert.equal(up.status, 200, "key:up should be accepted");
  const bad = await http("POST", "/command", { token: TOKEN, body: { terminalId: id, key: "totally-not-a-key" } });
  assert.equal(bad.status, 400, "unknown key should be 400");
});

// --- 3) screen-hash guard on cmux input ------------------------------------
test("POST /command rejects a stale expectedScreenHash (409)", async (t) => {
  if (!need(t)) return;
  const id = await newScratch("test-hashguard");
  assert.ok(id, "scratch terminal created");
  const stale = await http("POST", "/command", {
    token: TOKEN,
    body: { terminalId: id, command: "x", submit: false, expectedScreenHash: "deadbeefdeadbeef" },
  });
  assert.equal(stale.status, 409, "a wrong expectedScreenHash must 409");

  // Fetch the real hash, then a matching send should pass.
  const screen = await http("GET", `/cmux/screen?id=${id}`, { token: TOKEN });
  const real = screen.json?.hash;
  assert.ok(real, "screen hash readable");
  const ok = await http("POST", "/command", {
    token: TOKEN,
    body: { terminalId: id, command: " ", submit: false, expectedScreenHash: real },
  });
  assert.equal(ok.status, 200, "a matching expectedScreenHash should pass");
});

// --- 4) codex approval terminal matching (visible + markers) ---------------
// NOTE: the detailed selection/ambiguity logic is covered deterministically in
// test/unit/codex-approval-select.test.mjs (no live state). This integration
// test only verifies the cmux WIRING — that readVisibleText feeds the selector —
// via the one property that holds regardless of what else is on screen in the
// live environment: a plain shell (no approval markers) is NEVER pinned, even
// when it visibly contains the command. (A real Claude/codex pane elsewhere may
// legitimately contain the marker words, which in production fail-closes safely;
// asserting global uniqueness here would be env-dependent and flaky.)
test("findCodexApprovalTerminal never pins a markerless shell that shows the command", async (t) => {
  if (!need(t)) return;
  const cmuxMod = await import("../../cmux.js");
  const CMD = "rm_rf_build_TESTSENTINEL_zz";

  const shell = await newScratch("test-ap-shell");
  await typeInto(shell, `echo ${CMD}\r`);
  await sleep(1000);

  // Read repeatedly; the shell id must never come back as the pinned terminal.
  for (let i = 0; i < 5; i++) {
    const r = await cmuxMod.findCodexApprovalTerminal(CMD);
    assert.notEqual(r.id, shell, "a markerless shell must never be pinned");
    await sleep(200);
  }
});
