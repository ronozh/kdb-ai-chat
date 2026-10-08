#!/usr/bin/env bash
# Shared secret between Tomcat and the agent: the agent rejects /chat calls without it.
# Writes AGENT_TOKEN into agent/.env and backend/.env (both git-ignored). Run again to rotate.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
token=$(openssl rand -hex 24)
for f in agent/.env backend/.env; do
  touch "$f"
  { grep -v '^AGENT_TOKEN=' "$f" || true; echo "AGENT_TOKEN=$token"; } > "$f.tmp" && mv "$f.tmp" "$f"
done
echo "AGENT_TOKEN written to agent/.env and backend/.env (restart agent and backend)"
