// agent-iphone doctor — read-only diagnostics. The PASS/WARN/FAIL block is meant
// to be pasted into a GitHub issue. It never prints secret values.

import os from "node:os";
import { getConfig, paths } from "../lib/config.js";
import { fileMode, exists, which } from "../lib/sys.js";
import { bridgeUp, api, readAnyToken } from "../lib/bridge-client.js";
import * as cmux from "../cmux.js";

export async function run() {
  const cfg = getConfig();
  const rows = [];
  const add = (status, label, detail) => rows.push([status, label, detail]);

  add(process.platform === "darwin" ? "PASS" : "WARN", "macOS", `${os.platform()} ${os.release()}`);
  const major = parseInt(process.versions.node, 10);
  add(major >= 18 ? "PASS" : "FAIL", "Node", `v${process.versions.node} (>= 18 required)`);

  exists(paths.configFile)
    ? add("PASS", "config.json", "present")
    : add("WARN", "config.json", "absent (built-in defaults in use)");

  const hs = fileMode(paths.hookSecretFile);
  if (hs === null) add("WARN", "hook-secret", "absent (run setup)");
  else add(hs === "600" ? "PASS" : "WARN", "hook-secret", `perms ${hs}${hs === "600" ? "" : " (expected 600)"}`);

  const claude = which("claude");
  add(claude ? "PASS" : "WARN", "Claude Code", claude || "not found");
  const codex = which("codex");
  add(codex ? "PASS" : "WARN", "Codex", codex || "not found (optional)");

  // Separate "installed" from "RPC reachable" — a binary can exist while the
  // control socket is down / unconfigured, which breaks the live mirror.
  if (!cmux.cmuxAvailable()) {
    add("WARN", "cmux", "not found (hook/phone sessions only)");
  } else {
    const tree = await cmux.mobileWorkspaces();
    if (tree && Array.isArray(tree.workspaces)) {
      add("PASS", "cmux RPC", `mobile.workspace.list OK (${tree.workspaces.length} workspaces)`);
    } else {
      add("FAIL", "cmux RPC", "binary present but socket unreachable (cmux running? password set?)");
    }
  }

  const up = await bridgeUp();
  add(up ? "PASS" : "FAIL", "Bridge", up ? `/health OK on :${cfg.ports.apiPort}` : "not running");

  if (up) {
    const token = readAnyToken();
    const st = token ? await api("GET", "/status", { token }) : { ok: false };
    if (st.ok && st.json) {
      add("PASS", "Devices", `${st.json.pairedDevices ?? 0} paired`);
    } else {
      add("WARN", "Devices", "none paired (or token unreadable)");
    }
  }

  const hasTs = !!which("tailscale") || exists("/Applications/Tailscale.app");
  add(hasTs ? "PASS" : "WARN", "Tailscale", hasTs ? "installed" : "not installed (remote access LAN-only)");

  // Render
  const counts = { PASS: 0, WARN: 0, FAIL: 0 };
  const line = "─".repeat(52);
  console.log("agent-iphone doctor");
  console.log(line);
  for (const [s, l, d] of rows) {
    counts[s] = (counts[s] || 0) + 1;
    console.log(`[${s}] ${l.padEnd(16)} ${d}`);
  }
  console.log(line);
  console.log(`Result: ${counts.PASS} PASS · ${counts.WARN} WARN · ${counts.FAIL} FAIL`);
  return counts.FAIL > 0 ? 1 : 0;
}
