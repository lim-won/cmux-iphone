// lib/config.js — single source of truth for ports, paths, and secrets.
//
// Both the bridge (server.js) and the agent-iphone CLI read from here. Values
// come from config.json (if present) merged over built-in defaults; env vars
// still override at runtime (PORT, CLAUDE_WATCH_HOOK_PORT, CMUX_BIN, …).
//
// NOTE: the data dir is still "claude-watch" for backward compatibility with
// existing installs (secrets/tokens already live there). The rename to
// "agent-iphone" is a deliberate later migration, not a silent move.

import os from "node:os";
import path from "node:path";
import fs from "node:fs";

const HOME = os.homedir();
const DATA_DIR = path.join(HOME, "Library", "Application Support", "claude-watch");
const LOG_DIR = path.join(HOME, "Library", "Logs", "claude-watch");
const CONFIG_FILE = path.join(DATA_DIR, "config.json");

export const paths = {
  dataDir: DATA_DIR,
  logDir: LOG_DIR,
  configFile: CONFIG_FILE,
  sessionTokenFile: path.join(DATA_DIR, "session-token"), // legacy single token (migrated)
  devicesFile: path.join(DATA_DIR, "devices.json"),       // per-device tokens
  hookSecretFile: path.join(DATA_DIR, "hook-secret"),
  cmuxPasswordFile: path.join(HOME, ".config", "claude-watch", "cmux-password"),
  plistLabel: "com.agentiphone.bridge",
  launchAgentPlist: path.join(HOME, "Library", "LaunchAgents", "com.agentiphone.bridge.plist"),
};

const DEFAULTS = {
  version: 1,
  ports: { apiPort: 7860, apiPortRangeEnd: 7869, hookPort: 7861 },
  cmux: { enabled: null, bin: null }, // enabled:null = auto-detect at runtime
  pairing: { mode: "rotating", fixedCode: null, ttlMs: 24 * 60 * 60 * 1000 },
  runner: null, // "cmux" | "launchd" — chosen at setup
};

function loadRaw() {
  try {
    const j = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf-8"));
    return j && typeof j === "object" ? j : {};
  } catch {
    return {};
  }
}

/** Merged config (defaults <- config.json). Env overrides are applied by callers. */
export function getConfig() {
  const raw = loadRaw();
  return {
    ...DEFAULTS,
    ...raw,
    ports: { ...DEFAULTS.ports, ...(raw.ports || {}) },
    cmux: { ...DEFAULTS.cmux, ...(raw.cmux || {}) },
    pairing: { ...DEFAULTS.pairing, ...(raw.pairing || {}) },
  };
}

/** Shallow-merge a patch into config.json (creates it 0600 if absent). Never clobbers. */
export function saveConfig(patch) {
  const cur = loadRaw();
  const next = { ...cur, ...patch };
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(next, null, 2), { mode: 0o600 });
  return next;
}
