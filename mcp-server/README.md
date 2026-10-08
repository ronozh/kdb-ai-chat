# KDB-X MCP server (one instance per role)

`kdb-x-mcp-server/` is a git submodule of <https://github.com/KxSystems/kdb-x-mcp-server>, pinned to `9c9debc` and not modified.
Each role runs its own instance, configured only through `mcp-server/.env.<role>` (created by `make kdb-users`), loaded as env vars by `run.sh`.

```bash
make mcp                     # start prices :8101, trades :8102, quotes :8103 (logs: mcp-<role>.log)
make mcp-check ROLE=trades   # MCP Inspector CLI: tools/list + schema resource
make mcp-stop
```

The AI search tools disable themselves because the KDB-X AI libs aren't loaded, so only `kdbx_run_sql_query` is exposed.
See `doc/05-mcp-server.md` and `doc/06-roles.md`.
