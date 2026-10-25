# AI coding tools in ubuntu-services

The root `Dockerfile` adds Hermes Agent and Herdr to the existing `ubuntu-services` image. The Compose file persists Hermes data and provides a dedicated coding workspace.

## First build and setup

1. If you connect directly to the container's SSH server using a password, set a strong `SSH_ROOT_PASSWORD` in the shell environment or in a local Compose `.env` file before building. Do not commit that value. If unset, root password login is locked; you can still enter via QNAP SSH and `docker exec`.
2. Rebuild the existing image using the usual workflow for this stack.
3. Open an interactive shell in the running container and run:

   ```sh
   /usr/local/bin/ai-setup.sh
   ```

4. Follow the Hermes setup wizard to authenticate with a model provider, then configure Telegram. Use BotFather to create the bot and only allow your own Telegram user ID.
5. The setup script installs Herdr's Hermes integration. Use `herdr` from an SSH terminal to manage coding-agent sessions.

## Persistent paths

- `/root/.hermes`: provider credentials, Telegram configuration, agent memory, skills, and sessions. Compose mounts this at `/share/CACHEDEV3_DATA/Public/container/configs/hermes`.
- `/workspace`: repositories and working copies for coding tasks. Compose mounts this at `/share/CACHEDEV3_DATA/Public/container/ai-workspace`.

Do not place credentials or private keys in the workspace or commit them to Git. The gateway starts under Supervisor after the Telegram token is saved. Logs are written to `/var/log/app_logs/hermes-gateway.log` and `/var/log/app_logs/hermes-gateway-error.log`.

## Cost note

Hermes and Herdr are open-source software, but model inference may be paid. Choose a provider with a free tier or an eligible subscription during setup; free-tier limits and model availability can change. The installer skips optional browser/computer-use downloads to keep the existing service image smaller.
