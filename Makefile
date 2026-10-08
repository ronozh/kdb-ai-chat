SHELL := /bin/bash
export QLIC ?= $(HOME)/qlic

.PHONY: kdb kdb-hdb kdb-users kdb-down kdb-admin kdb-test kdb-expected mcp mcp-stop mcp-check secrets agent backend backend-down frontend test test-llm health

ROLES := prices trades quotes

kdb-users:           ## create/rotate the 3 read-only role users (kdb/users.txt + mcp-server/.env.<role>)
	for r in $(ROLES); do kdb/mkuser.sh $$r; done

kdb-hdb:             ## write the HDB + role views to kdb/data (once; delete kdb/data to rebuild)
	mkdir -p kdb/data
	docker compose -f kdb/docker-compose.yml build kdb-prices
	docker compose -f kdb/docker-compose.yml run --rm hdb-builder

kdb:                 ## start the 3 role q processes on 127.0.0.1:5001-5003 (first run: users + HDB)
	@[ -f kdb/users.txt ] || $(MAKE) kdb-users
	@[ -d kdb/data/hdb ] || $(MAKE) kdb-hdb
	docker compose -f kdb/docker-compose.yml up -d --build --remove-orphans kdb-prices kdb-trades kdb-quotes

kdb-down:
	docker compose -f kdb/docker-compose.yml down

kdb-admin:           ## admin q console on the WHOLE HDB (read-only mount, no network port)
	docker compose -f kdb/docker-compose.yml run --rm kdb-admin q /hdb

kdb-test:            ## per role: auth, read-only, and can only see its own table
	kdb/test.sh

kdb-expected:        ## expected answers for the e2e tests (computed in q on the whole HDB)
	docker compose -f kdb/docker-compose.yml run --rm -T kdb-admin q /opt/app/expected.q -q

mcp:                 ## start one KDB-X MCP server per role (pinned submodule, unmodified) on 127.0.0.1:8101-8103
	@[ -f mcp-server/kdb-x-mcp-server/pyproject.toml ] || git submodule update --init
	@for r in $(ROLES); do mcp-server/run.sh $$r > mcp-server/mcp-$$r.log 2>&1 & done; sleep 8; \
	  grep -h "Uvicorn running" mcp-server/mcp-*.log || (tail -5 mcp-server/mcp-*.log; exit 1)

mcp-stop:
	-pkill -f "mcp-server/.venv/bin/mcp-server"

mcp-check:           ## MCP Inspector CLI against one role: make mcp-check ROLE=trades
	$(eval PORT := $(shell grep ^KDBX_MCP_PORT mcp-server/.env.$(or $(ROLE),prices) | cut -d= -f2))
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:$(PORT)/mcp --transport http --method tools/list
	npx -y @modelcontextprotocol/inspector --cli http://127.0.0.1:$(PORT)/mcp --transport http --method resources/read --uri kdbx://tables

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

test: kdb-test       ## no LLM: kdb role/security checks + role isolation via MCP, agent and Tomcat
	cd agent && uv run pytest -v -m "not llm" tests

test-llm:            ## e2e questions through the LLM (~25 model requests; mind the free-tier quota)
	cd agent && uv run pytest -v -m llm tests
