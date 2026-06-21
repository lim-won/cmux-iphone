// agent-iphone status — live bridge status, addresses, paired devices.

import { getConfig } from "../lib/config.js";
import { api, readAnyToken, bridgeUp } from "../lib/bridge-client.js";
import { lanIPv4, tailscaleIPv4 } from "../lib/sys.js";

export async function run() {
  const cfg = getConfig();
  const port = cfg.ports.apiPort;
  const up = await bridgeUp();

  console.log(`Bridge:    ${up ? "running" : "NOT running"}`);
  if (!up) {
    console.log("\nRun 'agent-iphone setup' to install, or 'agent-iphone restart' if it's installed.");
    return 1;
  }

  console.log(`Runner:    ${cfg.runner || "(unset — run 'agent-iphone setup')"}`);
  const lan = lanIPv4();
  const ts = tailscaleIPv4();
  if (lan) console.log(`API (LAN): http://${lan}:${port}`);
  if (ts) console.log(`Tailscale: http://${ts}:${port}`);

  const token = readAnyToken();
  const st = token ? await api("GET", "/status", { token }) : { ok: false };
  if (st.ok && st.json) {
    console.log(`Sessions:  ${(st.json.sessions || []).length}`);
    console.log(`cmux:      ${st.json.cmuxAvailable ? "connected" : "off (hook/phone sessions only)"}`);
    console.log(`Devices:   ${st.json.pairedDevices ?? "?"} paired`);
    console.log(`Supervise: ${st.json.supervise ? "on" : "off"}`);
  } else {
    console.log("Devices:   none paired yet (pair a device — see 'agent-iphone pair')");
  }
  return 0;
}
