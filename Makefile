SHELL := /bin/bash
export QLIC ?= $(HOME)/qlic

.PHONY: clean-ds kdb kdb-hdb kdb-user kdb-down kdb-admin kdb-test kdb-expected mcp mcp-stop mcp-check secrets agent backend backend-down frontend test test-llm health

kdb-user:            ## create/rotate the read-only kdb user mcp_ro (kdb/users.txt + mcp-server/.env)
	kdb/mkuser.sh

kdb-hdb:             ## write the HDB to kdb/data/hdb (once; delete kdb/data to rebuild)
	mkdir -p kdb/data
	docker compose -f kdb/docker-compose.yml build kdbx
	docker compose -f kdb/docker-compose.yml run --rm hdb-builder

# macOS Finder drops .DS_Store files into folders you browse; q's HDB loader fails on them
clean-ds:
	@find kdb/data -name .DS_Store -delete 2>/dev/null || true

kdb: clean-ds        ## start KDB-X on 127.0.0.1:5000 (first run: user + HDB)
	@[ -f kdb/users.txt ] || $(MAKE) kdb-user
	@[ -d kdb/data/hdb ] || $(MAKE) kdb-hdb
	docker compose -f kdb/docker-compose.yml up -d --build --remove-orphans kdbx

kdb-down:
	docker compose -f kdb/docker-compose.yml down

kdb-admin: clean-ds  ## admin q console on the HDB (read-only mount, no network port)
	docker compose -f kdb/docker-compose.yml run --rm kdb-admin q /hdb

kdb-test:            ## kdb auth + read-only checks
	docker cp kdb/test_security.q kdbx:/tmp/test_security.q
	docker exec --env-file mcp-server/.env kdbx q /tmp/test_security.q -q

kdb-expected: clean-ds ## expected answers for the e2e tests (computed in q on the HDB)
	docker compose -f kdb/docker-compose.yml run --rm -T kdb-admin q /opt/app/expected.q -q

mcp:                 ## start the KDB-X MCP server (pinned submodule, unmodified) on 127.0.0.1:8000, in the background
	@[ -f mcp-server/kdb-x-mcp-server/pyproject.toml ] || git submodule update --init
	@mcp-server/run.sh > mcp-server/mcp.log 2>&1 & sleep 8; \
	  grep -h "Uvicorn running" mcp-server/mcp.log || (tail -5 mcp-server/mcp.log; exit 1)

mcp-stop:
	-pkill -f "mcp-server/.venv/bin/mcp-server"

mcp-check:           ## MCP Inspector CLI: tools/list + schema resource
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:8000/mcp --transport http --method tools/list
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:8000/mcp --transport http --method resources/read --uri kdbx://tables

secrets:             ## shared token so the agent only accepts calls from Tomcat (agent/.env + backend/.env)
	scripts/agent-token.sh

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

test: kdb-test       ## no LLM: kdb security checks + SQL guard unit tests + agent/Tomcat guards
	cd agent && uv run pytest -v -m "not llm" tests

test-llm:            ## e2e questions through the LLM (~25 model requests; mind the free-tier quota)
	cd agent && uv run pytest -v -m llm tests
