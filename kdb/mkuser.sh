#!/usr/bin/env bash
# Create/rotate the read-only kdb user mcp_ro and write its password to mcp-server/.env.
# kdb re-reads users.txt on every login, so no kdb restart is needed (restart the MCP server).
set -euo pipefail
umask 077
cd "$(dirname "$0")"
user=mcp_ro
pass=$(openssl rand -hex 16)
salt=$(openssl rand -hex 8)
hash=$(printf '%s%s' "$salt" "$pass" | shasum -a 1 | cut -d' ' -f1)
printf '%s:%s:%s\n' "$user" "$salt" "$hash" > users.txt

env=../mcp-server/.env
{ grep -vE '^KDBX_DB_(USERNAME|PASSWORD)=' ../mcp-server/.env.example
  echo "KDBX_DB_USERNAME=$user"
  echo "KDBX_DB_PASSWORD=$pass"
} > "$env"
echo "user $user written to kdb/users.txt; password stored in mcp-server/.env"
