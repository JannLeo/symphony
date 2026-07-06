#!/usr/bin/env bash
set -u

# Start symphony Phase 1.5 SmokeRunner (Docker)
# Reads GITHUB_TOKEN from ~/.git-credentials (no echo)

TOKEN=$(cat ~/.git-credentials 2>/dev/null | grep "^https://JannLeo:" | head -1 | awk -F'://JannLeo:' '{print $2}' | awk -F'@github' '{print $1}')
if [ -z "$T..."$TOKEN" ]; then
  echo "FATAL: no GITHUB_TOKEN found in ~/.git-credentials"
  exit 1
fi

cd /home/sz/symphony-hermes-dashboard/elixir || exit 1

exec docker run --rm --network host \
  -v ~/.mix:/root/.mix \
  -v /models-ssd:/models-ssd \
  -v "$(pwd):/app" -w /app \
  -e MIX_ENV=prod \
  -e GITHUB_REPO=JannLeo/jannserver \
  -e AGENT_NAME=hermes-server \
  -e AGENT_DRY_RUN=true \
  -e AGENT_PUSH_BRANCH=false \
  -e AGENT_WORKSPACE_ROOT=/models-ssd/agent-sandboxes \
  -e AGENT_DATA_ROOT=/models-ssd/agent-data \
  -e GITHUB_TOKEN="$TOKEN" \
  elixir:1.19 \
  sh -c '
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY
    git config --global http.proxy ""
    git config --global https.proxy ""
    echo "---- Symphony starting (polling for issues every 60s) ----"
    exec mix phx.server
  '