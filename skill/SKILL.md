---
name: cmux-iphone
description: Bridge your Claude Code session to the Cmux iPhone app on iPhone and Apple Watch
author: lim-won
version: 0.1.0
---

# Cmux iPhone Bridge

Starts a local bridge server that connects your active Claude Code session
to the Cmux iPhone iOS/watchOS app.

## What it does
- Runs a Node.js bridge server on your LAN
- Registers HTTP hooks for real-time event forwarding
- Generates a 6-digit pairing code for the iPhone app
- Enables voice commands from your Apple Watch

## Usage
Run `/cmux-iphone` to start the bridge.
Enter the pairing code in the Cmux iPhone app.

## Setup
The bridge requires Node.js 18+ (its only dependency is `bonjour-service`).
Run the setup script: `cd skill/bridge && npm ci` (or `npm install` if no lockfile)
