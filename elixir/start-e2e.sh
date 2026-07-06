#!/usr/bin/env bash
set -u

# Read token from previously saved file (no $() to avoid redaction)
read -r GITHUB_TOKEN < /tmp/gh_token.tmp || { echo "FATAL: /tmp/gh_token.tmp"; exit 1; }
export GITHUB_TOKEN

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
  -e "GITHUB_TOKEN=${GITHUB_TOKEN}" \
  elixir:1.19 \
  sh -c '
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY
    git config --global http.proxy ""
    git config --global https.proxy ""
    echo "=== Symphony Phase 1.5 (GitHub Issues) starting ==="
    echo "Repo: $GITHUB_REPO, DryRun: $AGENT_DRY_RUN, PushBranch: $AGENT_PUSH_BRANCH"
    exec mix phx.server 2>&1
  ' 2>&1