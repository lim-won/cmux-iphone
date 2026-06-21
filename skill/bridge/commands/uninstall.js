// agent-iphone uninstall — remove Agent iPhone's hooks + service. Surgical:
// only Agent iPhone's own pieces. --purge also deletes config/secrets/logs.

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { paths } from "../lib/config.js";

export async function run(args) {
  const purge = args.includes("--purge");

  // 1) Remove Claude hooks via the existing (now-surgical) script.
  const script = fileURLToPath(new URL("../../setup-hooks.sh", import.meta.url));
  spawnSync("bash", [script, "--remove"], { stdio: "inherit" });

  // 2) Remove the LaunchAgent (if installed).
  try {
    execFileSync("launchctl", ["bootout", `gui/${os.userInfo().uid}/${paths.plistLabel}`], { stdio: "ignore" });
  } catch { /* not loaded */ }
  try {
    if (fs.existsSync(paths.launchAgentPlist)) {
      fs.rmSync(paths.launchAgentPlist, { force: true });
      console.log("Removed LaunchAgent.");
    }
  } catch { /* ignore */ }

  // 3) Data.
  if (purge) {
    for (const dir of [paths.dataDir, paths.logDir]) {
      try { fs.rmSync(dir, { recursive: true, force: true }); console.log(`Purged ${dir}`); } catch { /* ignore */ }
    }
  } else {
    console.log(`Kept config/secrets in ${paths.dataDir} (use --purge to delete).`);
  }

  console.log('Uninstall complete. If the bridge ran inside cmux, close the "Agent Bridge" workspace.');
  return 0;
}
