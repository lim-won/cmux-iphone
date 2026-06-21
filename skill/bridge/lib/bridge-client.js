// lib/bridge-client.js — helpers for the agent-iphone CLI to talk to the LOCAL
// bridge. The CLI runs on the same Mac, so it reads a device token straight
// from devices.json (0600, same user) for authed endpoints.

import fs from "node:fs";
import { paths, getConfig } from "./config.js";

export function apiBase() {
  const port = process.env.PORT || getConfig().ports.apiPort;
  return `http://127.0.0.1:${port}`;
}

/** A valid device token read from the local store (for authed CLI calls), or null. */
export function readAnyToken() {
  try {
    const d = JSON.parse(fs.readFileSync(paths.devicesFile, "utf-8"));
    return Array.isArray(d) && d[0] && d[0].token ? d[0].token : null;
  } catch {
    return null;
  }
}

export async function api(method, route, { token, body, timeoutMs = 4000 } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`${apiBase()}${route}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      signal: ctrl.signal,
    });
    let json = null;
    try { json = await res.json(); } catch { /* non-JSON */ }
    return { status: res.status, json, ok: res.ok };
  } catch (e) {
    return { status: 0, json: null, ok: false, error: e.message };
  } finally {
    clearTimeout(timer);
  }
}

/** Is the bridge up? Uses the public /health probe. */
export async function bridgeUp() {
  const r = await api("GET", "/health", { timeoutMs: 2500 });
  return r.ok && r.json && r.json.ok === true;
}
