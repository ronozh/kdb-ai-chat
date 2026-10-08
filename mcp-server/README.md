# KDB-X MCP server

`kdb-x-mcp-server/` is a git submodule of <https://github.com/KxSystems/kdb-x-mcp-server>, pinned to `9c9debc` and not modified.
It is configured only through `mcp-server/.env` (created by `make kdb-user`), loaded as env vars by `run.sh`.

```bash
make mcp         # 127.0.0.1:8000/mcp, streamable-http, as kdb user mcp_ro (background; log: mcp.log)
make mcp-check   # MCP Inspector CLI: tools/list + schema resource
make mcp-stop
```

The AI search tools disable themselves because the KDB-X AI libs aren't loaded, so only `kdbx_run_sql_query` is exposed.
Table access per user group is enforced in the agent before calls reach this server. See `doc/05-mcp-server.md` and `doc/06-access-control.md`.
