#!/bin/bash
set -e
cd "$(dirname "$0")/bridge"
echo "Installing Cmux iPhone bridge dependencies..."
# Reproducible install from the committed lockfile; fall back if it's absent.
if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi
echo "Setup complete."
