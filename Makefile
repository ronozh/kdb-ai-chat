SHELL := /bin/bash
export QLIC ?= $(HOME)/qlic
KDB_PW = $$(grep ^KDBX_DB_PASSWORD mcp-server/.env | cut -d= -f2)

.PHONY: kdb kdb-user kdb-down kdb-logs kdb-test mcp mcp-check

kdb-user:            ## create mcp_ro credentials (kdb/users.txt + mcp-server/.env)
	kdb/mkuser.sh

kdb:                 ## build and start KDB-X on 127.0.0.1:5000
	@[ -f kdb/users.txt ] || kdb/mkuser.sh
	docker compose -f kdb/docker-compose.yml up -d --build

kdb-down:
	docker compose -f kdb/docker-compose.yml down

kdb-logs:
	docker logs -f kdbx

kdb-test:            ## auth + read-only checks
	docker cp kdb/test_security.q kdbx:/tmp/test_security.q
	docker exec -e PW=$(KDB_PW) kdbx q /tmp/test_security.q -q

mcp:                 ## KDB-X MCP server (pinned submodule, unmodified) on 127.0.0.1:8000
	@[ -f mcp-server/kdb-x-mcp-server/pyproject.toml ] || git submodule update --init
	cd mcp-server/kdb-x-mcp-server && set -a && . ../.env && set +a && \
	  UV_PROJECT_ENVIRONMENT=$(CURDIR)/mcp-server/.venv uv run mcp-server

mcp-check:           ## MCP Inspector CLI: list tools, run a query
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:8000/mcp --transport http --method tools/list
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:8000/mcp --transport http --method tools/call \
	  --tool-name kdbx_run_sql_query --tool-arg 'query=SELECT * FROM daily_prices LIMIT 5'
