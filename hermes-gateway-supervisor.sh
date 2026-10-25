#!/usr/bin/env bash
set -euo pipefail
export HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
export PATH="/root/.local/bin:/usr/local/bin:${PATH}"
ENV_FILE="$HERMES_HOME/.env"

# Avoid a restart loop until the owner has completed interactive setup.
while true; do
  if [ -f "$ENV_FILE" ] && grep -Eq '^TELEGRAM_BOT_TOKEN=.+$' "$ENV_FILE"; then
    break
  fi
  sleep 30
done

# Supervisor owns the foreground process and restarts it if it exits.
exec hermes gateway run --external-supervisor
