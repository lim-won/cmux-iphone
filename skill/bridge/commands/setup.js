// cmux-iphone setup — idempotent bootstrap. Safe to re-run: it never rotates
// existing secrets, backs up Claude settings before merging hooks, and reports
// "already configured" for steps that are already done.

import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getConfig, saveConfig, paths } from "../lib/config.js";
import { which, lanIPv4, tailscaleIPv4 } from "../lib/sys.js";
import { api, bridgeUp } from "../lib/bridge-client.js";
import * as cmux from "../cmux.js";

const sh = (p) => fileURLToPath(new URL(p, import.meta.url));

export async function run(args = []) {
  const cfg = getConfig();
  const apiPort = String(process.env.PORT || cfg.ports.apiPort);
  const forceCmux = args.includes("--cmux");
  const forceLaunchd = args.includes("--launchd");

  // 1) Preflight
  if (process.platform !== "darwin") {
    console.error("cmux-iphone targets macOS.");
    return 1;
  }
  const major = parseInt(process.versions.node, 10);
  if (major < 18) {
    console.error(`Node 18+ required (have v${process.versions.node}).`);
    return 1;
  }
  console.log(`✓ macOS ${os.release()} · Node v${process.versions.node}`);
  if (which("claude")) console.log("✓ Claude Code detected");
  if (which("codex")) console.log("✓ Codex detected");

  // 2) Pick a runner. cmux mirror needs the bridge INSIDE cmux (a launchd
  //    process can't reach the control socket). Distinguish "installed" from
  //    "RPC reachable" — picking a cmux runner we can't actually drive would
  //    leave the bridge dead. Flags override: --cmux / --launchd.
  let runner;
  const cmuxPresent = cmux.cmuxAvailable();
  const cmuxOk = cmuxPresent && (await cmux.cmuxReachable());
  if (forceLaunchd) {
    runner = "launchd";
    console.log("• runner: LaunchAgent (--launchd) — hook/phone/Codex only");
  } else if (forceCmux || cmuxPresent) {
    if (!cmuxOk) {
      console.error("\n✗ cmux is installed but its control socket isn't reachable.");
      console.error("  Start cmux, configure its socket password, then re-run — OR run this");
      console.error("  command from INSIDE a cmux terminal. To skip cmux and use hook/phone");
      console.error("  sessions only: cmux-iphone setup --launchd");
      return 1; // do NOT proceed with a cmux runner we can't drive
    }
    runner = "cmux";
    console.log("✓ cmux reachable — live mirror ON (runner: in-cmux)");
  } else {
    runner = "launchd";
    console.log("• cmux not found — hook/phone/Codex only (runner: LaunchAgent)");
  }

  // 3) Persist config (merge, never clobber)
  saveConfig({ runner, cmux: { ...cfg.cmux, enabled: runner === "cmux" } });
  console.log(`✓ config written → ${paths.configFile}`);

  // 4) Dependencies (reproducible)
  const dep = spawnSync("bash", [sh("../../setup.sh")], { stdio: "inherit" });
  if (dep.status !== 0) { console.error("Dependency install failed."); return 1; }

  // 5) Claude hooks (the script backs up settings.json + generates the secret)
  const hooks = spawnSync("bash", [sh("../../setup-hooks.sh"), apiPort], { stdio: "inherit" });
  if (hooks.status !== 0) { console.error("Hook install failed."); return 1; }

  // 6) Runner — actually start it (don't just print instructions).
  if (runner === "launchd") {
    const la = spawnSync("bash", [sh("../install-launchd.sh"), apiPort], { stdio: "inherit" });
    if (la.status !== 0) { console.error("LaunchAgent install failed."); return 1; }
  } else {
    try {
      const r = await cmux.ensureBridgeWorkspace(sh("../run-in-cmux.sh"));
      console.log(r.created
        ? '✓ created "Agent Bridge" cmux workspace (runs the bridge inside cmux)'
        : '✓ "Agent Bridge" cmux workspace already present');
    } catch (err) {
      console.error(`✗ could not create the cmux workspace: ${err.message}`);
      return 1;
    }
  }

  // 7) Health check — setup MUST NOT report success if the bridge isn't up.
  let up = false;
  for (let i = 0; i < 12; i++) {
    if (await bridgeUp()) { up = true; break; }
    await new Promise((r) => setTimeout(r, 700));
  }
  if (!up) {
    console.error("\n✗ bridge did not come up. Check `cmux-iphone logs` / `cmux-iphone doctor`.");
    return 1;
  }
  console.log("✓ health check passed");
  if (runner === "cmux" && !(await cmux.cmuxReachable())) {
    console.error("✗ bridge is up but cmux RPC is unreachable — see `cmux-iphone doctor`.");
    return 1;
  }

  // 8) Pair info
  console.log("\nPair your iPhone:");
  const lan = lanIPv4();
  const ts = tailscaleIPv4();
  if (lan) console.log(`  LAN:       http://${lan}:${apiPort}`);
  if (ts) console.log(`  Tailscale: http://${ts}:${apiPort}`);
  if (up) {
    const pc = await api("GET", "/pair-code");
    if (pc.ok && pc.json && pc.json.code) console.log(`  Code:      ${pc.json.code}`);
  }
  console.log("\nThen run 'cmux-iphone doctor' if anything looks off.");
  return 0;
}
