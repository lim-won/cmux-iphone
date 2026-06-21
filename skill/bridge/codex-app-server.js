// codex-app-server.js — JSON-RPC client for `codex app-server` (stdio transport).
//
// The B-path foundation: drive/observe codex conversations with STRUCTURED
// approvals (item/commandExecution/requestApproval etc.) and structured events,
// instead of TUI log-scraping + blind y/Esc key injection.
//
// Status: VERIFIED against codex-cli 0.141.0 over the stdio transport
//   (initialize -> thread/start{approvalPolicy:"untrusted"} -> turn/start ->
//    item/commandExecution/requestApproval received -> answered by request id).
// NOT yet wired into server.js — wiring depends on the deployment topology:
//   - stdio (this module): the bridge spawns + OWNS the codex app-server, so the
//     codex conversation is phone-driven (not a cmux pane).
//   - shared socket / cmux `codex --remote` co-attach: blocked — codex's control
//     socket is tied to ChatGPT's remote-control relay, not a clean local API
//     (and needs the managed standalone install). Revisit if that opens up.
//
// Wire framing on the stdio transport is newline-delimited JSON (one object per
// line). Requests carry an `id`; server->client requests (approvals) also carry
// an `id` that we answer with `{ id, result: { decision } }`.

import { spawn } from "node:child_process";

const APPROVAL_RE = /requestApproval|requestUserInput|elicitation/i;
const CALL_TIMEOUT_MS = 30_000;

/**
 * @param {object} opts
 * @param {string} [opts.codexBin]   path to the codex binary (default "codex")
 * @param {(a: {requestId:number, method:string, params:object}) => void} [opts.onApproval]
 *        called for every server->client approval/elicitation request; answer
 *        via answerApproval(requestId, decision)
 * @param {(method:string, params:object) => void} [opts.onNotification]
 *        called for every server->client notification (item/*, turn/*, etc.)
 * @param {(line:string) => void} [opts.onLog]
 * @param {(code:number|null) => void} [opts.onExit]
 */
export function createCodexAppServer(opts = {}) {
  const codexBin = opts.codexBin || process.env.CODEX_BIN || "codex";
  const { onApproval, onNotification, onLog, onExit } = opts;
  const log = (...a) => { if (onLog) onLog(a.map(String).join(" ")); };

  let child = null;
  let buf = "";
  let nextId = 1;
  let ready = false;
  const pending = new Map(); // id -> { resolve, reject, timer }

  function send(obj) {
    if (child && child.stdin.writable) child.stdin.write(JSON.stringify(obj) + "\n");
  }

  function call(method, params) {
    return new Promise((resolve, reject) => {
      const id = nextId++;
      const timer = setTimeout(() => {
        if (pending.has(id)) { pending.delete(id); reject(new Error(`${method} timed out`)); }
      }, CALL_TIMEOUT_MS);
      pending.set(id, { resolve, reject, timer });
      send({ id, method, params });
    });
  }

  function handle(msg) {
    // Server -> client REQUEST (has id + method): approvals / elicitations.
    if (msg.method && msg.id !== undefined) {
      if (APPROVAL_RE.test(msg.method)) {
        if (onApproval) onApproval({ requestId: msg.id, method: msg.method, params: msg.params || {} });
        else send({ id: msg.id, result: { decision: "decline" } }); // safe default if unhandled
      } else {
        send({ id: msg.id, result: {} }); // ack any other server request
      }
      return;
    }
    // Notification (method, no id).
    if (msg.method) {
      if (onNotification) onNotification(msg.method, msg.params || {});
      return;
    }
    // Response to one of our calls.
    if (msg.id !== undefined) {
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(typeof msg.error === "string" ? msg.error : JSON.stringify(msg.error)));
      else p.resolve(msg.result);
    }
  }

  /** Spawn the app-server and complete the initialize handshake. */
  async function start() {
    child = spawn(codexBin, ["app-server"], { stdio: ["pipe", "pipe", "pipe"] });
    child.stdout.on("data", (d) => {
      buf += d.toString();
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line) { try { handle(JSON.parse(line)); } catch { /* ignore non-JSON */ } }
      }
    });
    child.stderr.on("data", (d) => { const s = d.toString().trim(); if (s) log("stderr:", s.slice(0, 200)); });
    child.on("exit", (code) => {
      ready = false;
      for (const [, p] of pending) { clearTimeout(p.timer); p.reject(new Error("app-server exited")); }
      pending.clear();
      log(`app-server exited (${code})`);
      if (onExit) onExit(code);
    });
    await call("initialize", { clientInfo: { name: "agent-iphone-bridge", version: "2" } });
    ready = true;
    log("app-server ready");
    return true;
  }

  return {
    start,
    isReady: () => ready,
    /** Start a new thread. approvalPolicy: untrusted|on-request|on-failure|never */
    startThread: (o = {}) => call("thread/start", { approvalPolicy: o.approvalPolicy || "on-request", cwd: o.cwd }),
    /** Resume an existing (persisted) thread by id. */
    resumeThread: (threadId) => call("thread/resume", { threadId }),
    /** Send a user turn (text) to a thread. */
    startTurn: (threadId, text, o = {}) =>
      call("turn/start", { threadId, approvalPolicy: o.approvalPolicy, input: [{ type: "text", text: String(text) }] }),
    /** List persisted threads (resumable). */
    listThreads: (o = {}) => call("thread/list", o),
    /** Answer a server approval request by its request id.
     *  decision: accept | acceptForSession | decline | cancel  (legacy:
     *  approved | approved_for_session | denied | abort). */
    answerApproval: (requestId, decision) => send({ id: requestId, result: { decision } }),
    /** Low-level escape hatch for other RPC methods. */
    rpc: (method, params) => call(method, params),
    close: () => { try { if (child) child.kill(); } catch { /* ignore */ } },
  };
}
