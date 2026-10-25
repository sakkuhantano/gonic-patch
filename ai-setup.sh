#!/usr/bin/env bash
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
export PATH="/root/.local/bin:/usr/local/bin:${PATH}"
mkdir -p "$HERMES_HOME" /workspace
chmod 700 "$HERMES_HOME"

echo
echo "=== Hermes Agent setup ==="
echo "Interactive setup: choose a provider/model and complete authentication."
hermes setup

echo
echo "=== Telegram setup ==="
echo "Create a private bot using @BotFather and keep its token secret."
hermes gateway setup

echo
echo "=== Herdr integration ==="
herdr integration install hermes

echo
echo "Setup completed. Supervisor starts the Telegram gateway once TELEGRAM_BOT_TOKEN is saved."
echo "Run 'herdr' over SSH to open the terminal/session manager."
echo "Run 'hermes model' to change the provider/model later."
