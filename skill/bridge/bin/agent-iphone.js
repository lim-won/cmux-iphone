#!/usr/bin/env node
// agent-iphone — manage the Agent iPhone bridge (Claude Code / cmux → iPhone).
//
//   agent-iphone <command> [options]
//
// Commands: setup · doctor · status · pair · logs · restart · uninstall
// Every command is safe to re-run.

const COMMANDS = {
  setup:     "Install/repair the bridge: deps, secrets, Claude hooks, runner, health check",
  doctor:    "Read-only diagnostics (paste this into a GitHub issue)",
  status:    "Show live bridge status, addresses, and paired devices",
  pair:      "Show the pairing code; --list / --revoke <id> manage paired devices",
  logs:      "Tail the bridge log",
  restart:   "Restart the bridge",
  uninstall: "Remove hooks + the bridge service (--purge also deletes data)",
};

function usage() {
  console.log("agent-iphone — Agent iPhone bridge manager\n");
  console.log("Usage: agent-iphone <command> [options]\n");
  console.log("Commands:");
  for (const [name, desc] of Object.entries(COMMANDS)) {
    console.log(`  ${name.padEnd(11)} ${desc}`);
  }
  console.log("\nRun 'agent-iphone <command> --help' for command-specific options.");
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);

  if (!cmd || cmd === "--help" || cmd === "-h" || cmd === "help") {
    usage();
    process.exit(cmd ? 0 : 1);
  }
  if (cmd === "--version" || cmd === "-v") {
    const { readFileSync } = await import("node:fs");
    const { fileURLToPath } = await import("node:url");
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf-8"));
    console.log(pkg.version || "0.0.0");
    return;
  }
  if (!COMMANDS[cmd]) {
    console.error(`Unknown command: ${cmd}\n`);
    usage();
    process.exit(1);
  }

  try {
    const mod = await import(new URL(`../commands/${cmd}.js`, import.meta.url));
    const code = await mod.run(args);
    process.exit(typeof code === "number" ? code : 0);
  } catch (err) {
    console.error(`agent-iphone ${cmd} failed: ${err.message}`);
    process.exit(1);
  }
}

main();
