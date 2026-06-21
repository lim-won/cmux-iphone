---
name: claude-watch
description: Bridge your Claude Code session to the Agent iPhone app on Apple Watch
author: shobhit
version: 0.1.0
---

# Agent iPhone Bridge

Starts a local bridge server that connects your active Claude Code session
to the Agent iPhone iOS/watchOS app.

## What it does
- Runs a Node.js bridge server on your LAN
- Registers HTTP hooks for real-time event forwarding
- Generates a 6-digit pairing code for the iPhone app
- Enables voice commands from your Apple Watch

## Usage
Run `/claude-watch` to start the bridge.
Enter the pairing code in the Agent iPhone iPhone app.

## Setup
The bridge requires Node.js 18+ (its only dependency is `bonjour-service`).
Run the setup script: `cd skill/bridge && npm ci` (or `npm install` if no lockfile)
