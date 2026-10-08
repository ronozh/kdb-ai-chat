#!/usr/bin/env bash
# Run kdb/test_security.q inside each role's container (make kdb-test).
# Each run also tries another role's real credentials, which must be rejected.
set -euo pipefail
cd "$(dirname "$0")/.."
roles=(prices trades quotes); others=(trades quotes prices)
for i in 0 1 2; do
  r=${roles[$i]}; o=${others[$i]}
  echo "== role $r"
  docker cp kdb/test_security.q "kdb-$r:/tmp/test_security.q"
  docker exec --env-file "mcp-server/.env.$r" -e ROLE="$r" \
    -e OTHER_USER="ro_$o" -e OTHER_PW="$(grep ^KDBX_DB_PASSWORD "mcp-server/.env.$o" | cut -d= -f2)" \
    "kdb-$r" q /tmp/test_security.q -q
done
