#!/usr/bin/env bash
# Create/replace the read-only kdb user and write its password to mcp-server/.env.
# kdb re-reads users.txt on every login, so no restart is needed.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
user=${1:-mcp_ro}
pass=$(openssl rand -hex 16)
salt=$(openssl rand -hex 8)
hash=$(printf '%s%s' "$salt" "$pass" | shasum -a 1 | cut -d' ' -f1)

touch users.txt
{ grep -v "^$user:" users.txt || true; echo "$user:$salt:$hash"; } > users.tmp && mv users.tmp users.txt

env=../mcp-server/.env
[ -f "$env" ] || cp ../mcp-server/.env.example "$env"
{ grep -v '^KDBX_DB_PASSWORD=' "$env" || true; echo "KDBX_DB_PASSWORD=$pass"; } > "$env.tmp" && mv "$env.tmp" "$env"
echo "user $user written to kdb/users.txt; password stored in mcp-server/.env"
