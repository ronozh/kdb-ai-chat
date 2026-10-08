#!/usr/bin/env bash
# Run the (unmodified) KDB-X MCP server for one role, configured only by env vars from mcp-server/.env.<role>.
set -euo pipefail
role=${1:?usage: run.sh prices|trades|quotes}
here=$(cd "$(dirname "$0")" && pwd)
set -a; . "$here/.env.$role"; set +a
export QLIC=${QLIC:-$HOME/qlic} UV_PROJECT_ENVIRONMENT=$here/.venv
cd "$here/kdb-x-mcp-server"     # the server reads its guidance file relative to the repo root
exec uv run mcp-server
