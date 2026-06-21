// cmux-iphone logs — tail the bridge log (LaunchAgent runner).

import { spawn } from "node:child_process";
import path from "node:path";
import { paths } from "../lib/config.js";
import { exists } from "../lib/sys.js";

export async function run(args) {
  const follow = !args.includes("--no-follow");
  const linesArg = args.indexOf("--lines");
  const lines = linesArg !== -1 && args[linesArg + 1] ? args[linesArg + 1] : "80";

  const out = path.join(paths.logDir, "bridge.out.log");
  const err = path.join(paths.logDir, "bridge.err.log");
  const files = [out, err].filter(exists);

  if (!files.length) {
    console.log(`No log files in ${paths.logDir}.`);
    console.log('If the bridge runs inside cmux, view its "Agent Bridge" cmux workspace instead.');
    return 0;
  }

  const a = ["-n", lines];
  if (follow) a.push("-f");
  a.push(...files);
  const t = spawn("tail", a, { stdio: "inherit" });
  return new Promise((resolve) => t.on("exit", (c) => resolve(c || 0)));
}
