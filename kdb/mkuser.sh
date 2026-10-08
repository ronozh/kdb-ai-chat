#!/usr/bin/env bash
# Create/replace the read-only kdb user and write its password to mcp-server/.env.
set -euo pipefail
cd "$(dirname "$0")"
user=${1:-mcp_ro}
pass=$(openssl rand -hex 16)
salt=$(openssl rand -hex 8)
hash=$(printf '%s%s' "$salt" "$pass" | shasum -a 1 | cut -d' ' -f1)
touch users.txt && chmod 600 users.txt
grep -v "^$user:" users.txt > users.tmp || true
echo "$user:$salt:$hash" >> users.tmp && mv users.tmp users.txt
env=../mcp-server/.env
[ -f "$env" ] || cp ../mcp-server/.env.example "$env"
chmod 600 "$env"
sed -i '' "s/^KDBX_DB_PASSWORD=.*/KDBX_DB_PASSWORD=$pass/" "$env"
echo "user $user written to kdb/users.txt; password stored in mcp-server/.env"
