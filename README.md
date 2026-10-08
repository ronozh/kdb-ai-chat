# kdb-ai-chat

Natural-language chat over a KDB-X price database. Spec: `doc/plan.md`. Setup: `doc/setup-licence-and-keys.md`.

## Run

```bash
make kdb        # KDB-X in Docker on 127.0.0.1:5000 (creates mcp_ro credentials on first run)
make kdb-test   # auth + read-only checks
make mcp        # MCP server on 127.0.0.1:8000 (foreground)
make mcp-check  # MCP Inspector CLI check
```

## Security findings (KDB-X)

- KX SQL (`.s.e`) writes an internal global (`.s.I`), so it fails under both `reval` and `-b`. The plan's fallback (`-b`) does not work, so `-b` is not used.
- Unrestricted `.s.e` accepts `INSERT`, `CREATE TABLE` and `DROP TABLE`, but not `UPDATE`/`DELETE`, and it cannot call q functions.
- Design (`kdb/init.q`):
  - Every connection is authenticated against a salted SHA-1 credentials file. Anonymous and unknown users are rejected.
  - The MCP server's exact SQL call runs `.s.e` directly, but only for a single `SELECT`/`WITH` statement: no `;`, no comments, no DML/DDL keywords outside string literals.
  - Every other remote query runs under `reval`, which blocks writes, `system` and file access outside the working dir. The credentials file is mounted outside the working dir.
  - pykx sends calls as ("fn-as-string";args). These are resolved inside `reval`, like the default handler does.
  - A trailing `;` is stripped. Any other `;` is rejected.
  - Every remote query is logged (`docker logs kdbx`).
  - HTTP and websocket handlers are disabled.
- Arm64: KX ships no `l64arm-sql.zip`. The image takes the arch-independent `s.k_` from `l64-sql.zip`.
