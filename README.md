# kdb-ai-chat

Natural-language chat over a KDB-X market-data database (daily prices, trades, quotes), with role-based read-only access: each web user sees only their role's table. Spec: `doc/plan/plan.md`. Setup: `doc/plan/setup-licence-and-keys.md`.

**Understand the project** (read in order):
1. [Architecture and infrastructure](doc/01-architecture.md)
2. [kdb: the language, the process, querying, pykx, security](doc/02-kdb.md)
3. [kdb storage and production architecture: HDB files, memory-mapping, RDB, gateway](doc/03-kdb-storage.md)
4. [The agent: Pydantic AI + MCP](doc/04-agent.md)
5. [MCP and the KDB-X MCP server](doc/05-mcp-server.md)
6. [Role-based read-only access](doc/06-roles.md)

## Prerequisites

Docker Desktop, Node 20+, `uv`, and the KDB-X licence in `~/qlic` plus a Gemini key in `agent/.env` (see `doc/plan/setup-licence-and-keys.md`).
Java, Maven and Tomcat run in Docker. Tested on macOS with Docker Desktop. On Linux, Tomcat needs `extra_hosts: ["host.docker.internal:host-gateway"]` and the agent must listen on an address the container can reach.

## Run (in order, one terminal each for the foreground ones)

```bash
git submodule update --init
make secrets    # once: shared token so only Tomcat can call the agent
make kdb        # 3 role q processes, 127.0.0.1:5001-5003 (first run: role users + HDB in kdb/data)
make mcp        # 3 MCP servers, 127.0.0.1:8101-8103 (background; make mcp-stop)
make agent      # agent, 127.0.0.1:8001 (foreground)
make backend    # Tomcat 10.1 in Docker, 127.0.0.1:8090
make frontend   # UI at http://127.0.0.1:5173 (foreground): users alice / bob / carol
make health     # every role's chain via Tomcat
```

| User | Role | Table | kdb | MCP |
|---|---|---|---|---|
| alice | prices | `daily_prices` | 5001 | 8101 |
| bob | trades | `trades` | 5002 | 8102 |
| carol | quotes | `quotes` | 5003 | 8103 |

Tests:
- `make test`: kdb security and isolation per role, plus isolation through MCP, agent and Tomcat. No LLM.
- `make test-llm`: end-to-end questions through Gemini (uses quota).
- `make kdb-expected`: prints the expected answers.
- `make kdb-admin`: a q console on the whole HDB.

## Troubleshooting

- **Model 429 "quota"**: Gemini's free tier allows about 20 requests per day per model, and a question uses 2 or more. Switch `AGENT_MODEL` in `agent/.env` (quotas are per model, e.g. `google:gemini-3.1-flash-lite`), wait a day, or use a paid key (e.g. `anthropic:claude-haiku-4-5` with `ANTHROPIC_API_KEY`).
- **Model 503 "high demand"**: newer free models are often overloaded. The agent retries 429/503 three times; otherwise switch model.
- **MCP server: "valid q license must be in a known location"**: `QLIC` isn't set. `make` sets it to `~/qlic`.
- **Port 8080 busy**: Tomcat is published on 8090 because 8080 is used by other local services.
- **Tomcat 502 with an empty body at the agent**: the Java HttpClient must use HTTP/1.1. Its default h2c upgrade makes uvicorn drop the body.
- **kdb queries**: `docker logs kdb-<role>` shows every remote query with its user (audit log). Client queries are aborted after 30s (`-T 30`). Memory is capped at 2 GB (`-w 2000`); a query that exceeds it kills q, and Docker restarts it.

## Security findings (KDB-X)

- KX SQL (`.s.e`) writes an internal global (`.s.I`), so it fails under both `reval` and `-b`. The plan's fallback (`-b`) does not work, so `-b` is not used.
- Unrestricted `.s.e` accepts `INSERT`, `CREATE TABLE` and `DROP TABLE`, but not `UPDATE`/`DELETE`, and it cannot call q functions.
- Design (`kdb/init.q`):
  - Every connection is authenticated against a salted SHA-1 credentials file, re-read on each login. kdb fails closed: the port opens only at the end of `init.q`, and q exits if the file can't be read. Anonymous and unknown users are rejected.
  - The MCP server's exact SQL call runs `.s.e` directly, but only for a single `SELECT`/`WITH` statement: no `;`, no comments, no DML/DDL keywords outside string literals.
  - Every other remote query runs under `reval`, which blocks writes, `system` and file access outside the working dir. The credentials file is mounted outside the working dir.
  - pykx sends calls as ("fn-as-string";args). These are resolved inside `reval`, like the default handler does.
  - A trailing `;` is stripped. Any other `;` is rejected.
  - Every remote query is logged with its user (`docker logs kdb-<role>`).
  - HTTP and websocket handlers are disabled.
- A heavy SQL self-join once crashed q, so client queries now time out after 30s (`-T 30`).
- The HDB is mounted read-only. Only the one-off `hdb-builder` container writes it.
- Roles: one q process per role loads only that role's table from a hard-linked view, and only that role's kdb user may log in ([doc/06-roles.md](doc/06-roles.md)). Counting partitioned tables writes a cache global (`.Q.PN`) that `reval` blocks, so `init.q` warms it at startup.
- Arm64: KX ships no `l64arm-sql.zip`. The image takes the arch-independent `s.k_` from `l64-sql.zip`.
