// agent-iphone restart — restart the bridge (runner-aware).

import { execFileSync } from "node:child_process";
import os from "node:os";
import { getConfig, paths } from "../lib/config.js";

export async function run() {
  const cfg = getConfig();
  if (cfg.runner === "launchd") {
    try {
      execFileSync("launchctl", ["kickstart", "-k", `gui/${os.userInfo().uid}/${paths.plistLabel}`], { stdio: "inherit" });
      console.log("Restarted (launchctl kickstart).");
      return 0;
    } catch (e) {
      console.log(`launchctl kickstart failed: ${e.message}`);
      console.log("Is the LaunchAgent installed? Try 'agent-iphone setup'.");
      return 1;
    }
  }
  console.log("Runner is cmux (or unset): the in-cmux supervisor relaunches the bridge");
  console.log('automatically when it exits. To force a restart, close + reopen the');
  console.log('"Agent Bridge" cmux workspace, or run \'agent-iphone setup\'.');
  return 0;
}
