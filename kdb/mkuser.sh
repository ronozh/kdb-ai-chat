#!/usr/bin/env bash
# Create/rotate the read-only kdb user for one role and write the role's MCP server config.
#   kdb/mkuser.sh prices|trades|quotes
# Writes: kdb/users.txt (salted hash) and mcp-server/.env.<role> (ports, user, password).
# kdb re-reads users.txt on every login, so no restart is needed (restart that role's MCP server).
set -euo pipefail
umask 077
cd "$(dirname "$0")"
role=${1:?usage: mkuser.sh prices|trades|quotes}
case $role in
  prices) kdb_port=5001; mcp_port=8101 ;;
  trades) kdb_port=5002; mcp_port=8102 ;;
  quotes) kdb_port=5003; mcp_port=8103 ;;
  *) echo "unknown role: $role" >&2; exit 1 ;;
esac
user=ro_$role
pass=$(openssl rand -hex 16)
salt=$(openssl rand -hex 8)
hash=$(printf '%s%s' "$salt" "$pass" | shasum -a 1 | cut -d' ' -f1)

touch users.txt
{ grep -v "^$user:" users.txt || true; echo "$user:$salt:$hash"; } > users.tmp && mv users.tmp users.txt

env=../mcp-server/.env.$role
{ grep -vE '^KDBX_(DB_PORT|MCP_PORT|DB_USERNAME|DB_PASSWORD)=' ../mcp-server/.env.example
  echo "KDBX_DB_PORT=$kdb_port"
  echo "KDBX_MCP_PORT=$mcp_port"
  echo "KDBX_DB_USERNAME=$user"
  echo "KDBX_DB_PASSWORD=$pass"
} > "$env"
echo "role $role: kdb user $user (port $kdb_port), MCP config $env (port $mcp_port)"
