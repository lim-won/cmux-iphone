// P0 regression: setup-hooks.sh --remove (and install dedupe) must strip ONLY
// Agent iPhone's own hook objects, never delete a mixed entry that also holds
// another tool's hooks. Runs the REAL script against a throwaway $HOME, so it's
// deterministic + hermetic (no network, no cmux, no touching the real settings).

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT = path.resolve(fileURLToPath(import.meta.url), "../../../../setup-hooks.sh"); // skill/setup-hooks.sh
const HOOK = "http://127.0.0.1:7861";       // Agent iPhone's loopback hook origin (default port)
const FOREIGN = "http://127.0.0.1:9000";    // some other tool on loopback

function runRemoveOn(settings) {
  const home = mkdtempSync(path.join(os.tmpdir(), "aw-hooktest-"));
  try {
    mkdirSync(path.join(home, ".claude"), { recursive: true });
    const settingsPath = path.join(home, ".claude", "settings.json");
    writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
    execFileSync("bash", [SCRIPT, "--remove"], { env: { ...process.env, HOME: home }, encoding: "utf-8" });
    return JSON.parse(readFileSync(settingsPath, "utf-8"));
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

test("--remove strips ONLY Agent iPhone hooks, preserving a mixed entry's other tool", () => {
  const out = runRemoveOn({
    hooks: {
      Stop: [
        // MIXED entry: one AW hook + one foreign hook in the SAME entry.hooks[]
        { hooks: [
          { type: "command", url: `${HOOK}/hooks/stop` },
          { type: "command", url: `${FOREIGN}/hooks/done` },
        ] },
        // separate foreign-only entry
        { hooks: [{ type: "command", url: `${FOREIGN}/hooks/other` }] },
      ],
      PreToolUse: [
        // AW-only entry → should disappear
        { matcher: "Bash", hooks: [{ type: "command", url: `${HOOK}/hooks/pre-tool-use` }] },
        // foreign command-hook entry → must survive untouched
        { matcher: "Edit", hooks: [{ type: "command", command: "echo other-tool" }] },
      ],
    },
  });

  // Stop: the mixed entry survives with ONLY the foreign hook; AW hook stripped.
  const stopUrls = (out.hooks?.Stop ?? []).flatMap((e) => e.hooks.map((h) => h.url));
  assert.ok(!stopUrls.includes(`${HOOK}/hooks/stop`), "AW stop hook removed");
  assert.ok(stopUrls.includes(`${FOREIGN}/hooks/done`), "foreign hook in the mixed entry preserved");
  assert.ok(stopUrls.includes(`${FOREIGN}/hooks/other`), "separate foreign entry preserved");

  // PreToolUse: AW-only entry gone, foreign command entry kept.
  const pre = out.hooks?.PreToolUse ?? [];
  assert.equal(pre.length, 1, "AW-only entry removed, foreign entry kept");
  assert.equal(pre[0].hooks[0].command, "echo other-tool");
});

test("--remove on settings with no Agent iPhone hooks changes nothing", () => {
  const original = {
    hooks: { Stop: [{ hooks: [{ type: "command", url: `${FOREIGN}/hooks/x` }] }] },
  };
  const out = runRemoveOn(structuredClone(original));
  assert.deepEqual(out, original, "untouched when no AW hooks present");
});
