// cmux-iphone pair — show the pairing code; manage paired devices.
//
//   cmux-iphone pair                 show the current pairing code
//   cmux-iphone pair --list          list paired devices
//   cmux-iphone pair --revoke <id>   revoke one device's token

import { api, readAnyToken } from "../lib/bridge-client.js";

export async function run(args) {
  if (args.includes("--list")) return list();
  const ri = args.indexOf("--revoke");
  if (ri !== -1) return revoke(args[ri + 1]);
  return showCode();
}

async function showCode() {
  const r = await api("GET", "/pair-code"); // loopback-only on the bridge
  if (!r.ok) {
    console.log("Bridge not reachable. Check 'cmux-iphone status'.");
    return 1;
  }
  const { code, fixed, expiresAt } = r.json || {};
  if (!code) {
    console.log("No active pairing code. A new one is generated on the next pairing\nattempt or when the bridge restarts. Open the app to trigger one.");
    return 0;
  }
  console.log(`Pairing code: ${code}${fixed ? "  (fixed)" : ""}`);
  if (expiresAt) console.log(`Expires:      ${new Date(expiresAt).toLocaleString()}`);
  console.log("\nEnter this code in the Cmux iPhone app on your iPhone.");
  return 0;
}

async function list() {
  const token = readAnyToken();
  if (!token) {
    console.log("No paired devices yet.");
    return 0;
  }
  const r = await api("GET", "/devices", { token });
  if (!r.ok) {
    console.log("Could not list devices (is the bridge running?).");
    return 1;
  }
  const devs = (r.json && r.json.devices) || [];
  if (!devs.length) {
    console.log("No paired devices.");
    return 0;
  }
  console.log("Paired devices:");
  for (const d of devs) {
    const seen = d.lastSeen ? `  (last seen ${new Date(d.lastSeen).toLocaleString()})` : "";
    console.log(`  ${d.id}  ${d.name}${seen}`);
  }
  console.log("\nRevoke one with: cmux-iphone pair --revoke <id>");
  return 0;
}

async function revoke(id) {
  if (!id) {
    console.log("Usage: cmux-iphone pair --revoke <deviceId>   (see 'cmux-iphone pair --list')");
    return 1;
  }
  const token = readAnyToken();
  const r = await api("POST", "/devices/revoke", { token, body: { deviceId: id } });
  if (r.status === 200) { console.log(`Revoked ${id}.`); return 0; }
  if (r.status === 404) { console.log(`No device with id ${id}.`); return 1; }
  console.log(`Revoke failed (status ${r.status || "no response"}).`);
  return 1;
}
