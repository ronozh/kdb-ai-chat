SHELL := /bin/bash
export QLIC ?= $(HOME)/qlic

.PHONY: kdb kdb-user kdb-down kdb-logs kdb-test kdb-expected mcp mcp-check agent backend backend-down frontend test health

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
	docker exec --env-file mcp-server/.env kdbx q /tmp/test_security.q -q

mcp:                 ## KDB-X MCP server (pinned submodule, unmodified) on 127.0.0.1:8000
	@[ -f mcp-server/kdb-x-mcp-server/pyproject.toml ] || git submodule update --init
	cd mcp-server/kdb-x-mcp-server && set -a && . ../.env && set +a && \
	  UV_PROJECT_ENVIRONMENT=$(CURDIR)/mcp-server/.venv uv run mcp-server

mcp-check:           ## MCP Inspector CLI: list tools, run a query
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:8000/mcp --transport http --method tools/list
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:8000/mcp --transport http --method tools/call \
	  --tool-name kdbx_run_sql_query --tool-arg 'query=SELECT * FROM daily_prices LIMIT 5'

kdb-expected:        ## expected answers for the e2e tests (computed in q)
	docker cp kdb/expected.q kdbx:/tmp/expected.q
	docker exec kdbx q /tmp/expected.q -q

agent:               ## agent service on 127.0.0.1:8001 (foreground)
	cd agent && uv run uvicorn kdb_agent:app --host 127.0.0.1 --port 8001

backend:             ## build WAR + run Tomcat 10.1 in Docker on 127.0.0.1:8090
	docker compose -f backend/docker-compose.yml up -d --build

backend-down:
	docker compose -f backend/docker-compose.yml down

frontend:            ## React dev server on 127.0.0.1:5173 (proxies /api to Tomcat)
	cd frontend && [ -d node_modules ] || npm install
	cd frontend && npm run dev

health:              ## health of the whole chain via Tomcat
	@curl -s 127.0.0.1:8090/api/health; echo

test: kdb-test       ## kdb security checks + section 6 e2e tests (LLM; ~18 model requests)
	cd agent && uv run pytest -v tests
