SHELL := /bin/bash
export QLIC ?= $(HOME)/qlic
KDB_PW = $$(grep ^KDBX_DB_PASSWORD mcp-server/.env | cut -d= -f2)

.PHONY: kdb kdb-user kdb-down kdb-logs kdb-test

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
