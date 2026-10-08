# 2. kdb: the language, the process, and how to use it

How the data is stored on disk, and how production kdb is set up, is covered in [03-kdb-storage.md](03-kdb-storage.md).

## 1. The big idea

**kdb+** (the new version is **KDB-X**) is a very fast **column-oriented** database, built for time series such as market data. It comes with its own programming language, **q**.

Think of it as Python + pandas + a database server in one small process:

| Python world | kdb world |
|---|---|
| Python, the language | **q**, the language |
| `python` interpreter | `q` interpreter |
| a running Python program | a running **q process** |
| pandas DataFrame | q **table** |
| a variable holding a DataFrame | a **global variable** holding a table (`daily_prices`) |
| a Postgres server on a port | the same q process listening on a port (`\p 5000`) |

Two key ideas:
1. **A kdb database is a running q process.** Its tables are variables in that process.
2. **Those tables can live in memory, or on disk as files** that q maps into memory. Our project uses disk: a *historical database* (HDB) with three tables, `daily_prices`, `trades` and `quotes`. See doc 03.

## 2. q, the language

q comes from **APL** and **k**: it's terse, it works on whole arrays, and it **reads right to left**.

- `avg close` averages the whole column with no loop, like NumPy.
- `2*3+4` is `14` (q evaluates `3+4` first).
- `` `T001 `` is a **symbol**, an interned string like a pandas category.
- Dates look like `2026.06.15`.
- `x:5` means assignment, so `=` is comparison.
- `/` starts a comment.
- SQL-like queries are built into the language: `select avg close by sym from daily_prices`.

## 3. The q process

A **q process** is one running `q` program: a single-threaded interpreter that holds data and can listen on a port. Every kdb component is a q process running a different script; doc 03 has examples. We run **three**, one per role: containers `kdb-prices`, `kdb-trades` and `kdb-quotes` each run `q init.q` and load only their role's table ([06-roles.md](06-roles.md)).

**System commands** are lines that start with `\`. They are REPL commands, not q functions:

| Command | Meaning |
|---|---|
| `\l file.q` | **Load** a script, i.e. run it (like `exec(open(...).read())`) |
| `\l /hdb` | **Load a database directory**: q switches its working directory to `/hdb` and maps the tables found there |
| `\p 5000` | Listen on port 5000 |
| `\a` / `\v` | List tables / all variables |
| `\t expr` | Time an expression |
| `\\` | Quit |

## 4. Two query languages: q and SQL

KX also ships a **SQL** layer (`.s.e`) that translates SQL into q. The MCP server uses SQL because LLMs write SQL well.

| Task | q | SQL (via `.s.e`) |
|---|---|---|
| T001 on one day | `select from daily_prices where date=2026.06.15, sym=`T001` | `SELECT * FROM daily_prices WHERE "date"='2026-06-15' AND "sym"='T001'` |
| Average close per ticker | `select avg close by sym from daily_prices` | `SELECT "sym", avg("close") FROM daily_prices GROUP BY "sym"` |
| Row count | `count daily_prices` | `SELECT count(*) FROM daily_prices` |

KX SQL gotchas, learned in this project:
- **Always double-quote column names.** Unquoted `sym` can fail to parse.
- Not supported: window functions (`LAG`, `OVER`), `abs()`, correlated subqueries in `SELECT`, and `<`/`>` conditions inside `JOIN ... ON`.
- What does work: date arithmetic (`"date"-1`), `MOD(CAST("date" AS INTEGER), 7)` for the weekday (2 = Monday), and `CASE WHEN` (use it in place of `abs`).

## 5. Getting a q prompt

Don't attach to the server's own console. Start a second q process instead. There are two kinds of session:

### a) Admin session: full q on the whole HDB

```bash
make kdb-admin        # new q process in a throwaway container, loads all 3 tables
```

This gives you unrestricted q on the same files, with all three tables. The HDB is mounted **read-only** and the container has no network port, so you can't damage or expose anything. It's the best place to learn q and to read files with `get` (doc 03).

### b) Client session: query a role's server as that role

```bash
docker exec -it --env-file mcp-server/.env.prices kdb-prices q
```

```q
h:hopen `$"::5000:ro_prices:",getenv`KDBX_DB_PASSWORD   / open a connection handle (port 5000 inside the container)
h"tables[]"                                            / → ,`daily_prices  (only this role's table)
h"count daily_prices"                                  / send q code as a string, get the result back
h"select from daily_prices where date=2026.06.15, sym=`T001"
h"count trades"                                        / → error: trades doesn't exist in this process
h"delete from `daily_prices"                            / → 'noupdate  (read-only)
hclose h
```

For bob's or carol's role, use `kdb-trades` / `.env.trades` / `ro_trades`, and so on.

`h` is a **connection handle** (an integer). Calling it with a string runs that string on the server. Every kdb client works this way, including pykx and the MCP server.

## 6. Everyday commands

Prefix these with `h` in a client session:

| Want to… | Command | Notes |
|---|---|---|
| List tables | `tables[]` | Admin: `` `daily_prices`quotes`trades ``; a role: only its table |
| Show the schema | `meta daily_prices` | `c` column, `t` type (`d` date, `s` symbol, `f` float, `j` long), `a` attribute (`p` = parted) |
| List dates (HDB) | `date` | In an HDB, `date` is a variable listing every partition |
| Count rows | `count daily_prices` | |
| One day | `select from daily_prices where date=2026.09.30` | **Always filter on `date` first** in an HDB |
| Aggregate | `select avg close, max volume by sym from daily_prices where date within 2026.01.01 2026.03.31` | `by` = GROUP BY |
| Run SQL | `.s.e "SELECT \"sym\", avg(\"close\") FROM daily_prices GROUP BY \"sym\""` | In a scratch session, run `.s.init[]` first |
| List namespaces | `key ` `` | `.s` = SQL, `.z` = system hooks, `.sec` = our security code |

**"List databases?"** kdb has no `SHOW DATABASES`. One q process serves one database (for an HDB, one directory), so `tables[]` is the whole answer for that process.

Shortcuts:

```bash
make kdb-expected         # test answers computed in q (kdb/expected.q)
make kdb-test             # security + isolation tests, per role
docker logs kdb-prices    # audit log: every remote query with user, time and full text
```

## 7. pykx: q from Python

**pykx** is KX's Python library. In this project it's installed **only in the MCP server's virtualenv** (`mcp-server/.venv`, Python 3.13). It has two modes:
- **IPC client:** connect to a q server and send queries, like `psycopg` for Postgres. The MCP server uses this mode.
- **Embedded q:** run q inside Python, for example to read HDB files directly. This needs the licence (`QLIC`).

```bash
set -a; . mcp-server/.env.prices; set +a
QLIC=~/qlic mcp-server/.venv/bin/python
```

```python
import os, pykx as kx

conn = kx.SyncQConnection(host="127.0.0.1", port=5001,            # kdb-prices
                          username="ro_prices", password=os.environ["KDBX_DB_PASSWORD"])

conn("tables[]")                                                   # pykx SymbolVector
df = conn("select from daily_prices where date=2026.09.30").pd()   # .pd() → pandas DataFrame

# pass Python values as arguments (safer than building strings)
conn("{select avg close by sym from daily_prices where sym in x}",
     kx.SymbolVector(["T001", "T002"])).pd()

conn("delete from `daily_prices")                                  # raises: noupdate (read-only)
```

Results come back as pykx objects that wrap q data. Call `.pd()` for pandas or `.py()` for plain Python. Without `QLIC`, the IPC queries still work, but converting the results can fail.

## 8. How this project secures kdb

All the code is in `kdb/init.q`, which every role's q process runs. q lets you override **callback hooks** that run on every connection or query:

```mermaid
flowchart TD
    C[client connects] --> PW{".z.pw<br/>this role's user +<br/>password ok?"}
    PW -- no --> X[rejected]
    PW -- yes --> Q[client sends a query] --> PG{".z.pg<br/>is it the MCP server's<br/>exact SQL call?"}
    PG -- yes --> RO{"SELECT/WITH only?<br/>no ; or comments<br/>no INSERT/DROP/INTO..."}
    RO -- yes --> SQL[".s.e runs the SQL"]
    RO -- no --> E1[error]
    PG -- no --> RV["reval: run in a sandbox<br/>no writes, no system calls,<br/>no file access outside /db"]
```

| Hook | Our override |
|---|---|
| `.z.pw[user;password]` | Only this role's user (`KDB_ROLE_USER`) may log in, checked against `users.txt` (salted SHA-1). Anonymous users, unknown users and other roles' users are rejected. The file is re-read on each login. |
| `.z.pg[query]` (sync query) | Logs the query. The MCP server's SQL call goes through a read-only SQL check. Everything else runs under `reval`, q's built-in read-only sandbox. |
| `.z.ps` (async query) | Same, always under `reval`. |
| `.z.ph`, `.z.pp`, `.z.ws` | HTTP and websocket access are disabled. |

Why the SQL path is special: KX's `.s.e` writes an internal counter, so it can't run inside `reval`. It runs unrestricted instead, but only after the SQL text passes `.sec.readOnly`: a single `SELECT`/`WITH` statement with no write keywords outside quoted strings.

Layers of defence:
- **Read-only, role-only files:** each container mounts only its role's view, read-only, so the files can't change and other tables' files aren't there ([06-roles.md](06-roles.md)).
- **Fail closed:** the port opens on the last line of `init.q` (`\p 5000`). If the role, the HDB view or the credentials can't be loaded, q exits and nothing is exposed.
- **Startup warm-up:** `init.q` counts each table once. Counting a partitioned table caches per-partition counts in a global (`.Q.PN`), which `reval` would block for clients.
- **Resource limits:** `-T 30` cancels queries after 30s. `-w 2000` caps memory at 2 GB; q aborts and Docker restarts it.

## 9. Files

| File | Purpose |
|---|---|
| `kdb/Dockerfile` | Debian + q binary + SQL module (`s.k_`). The licence is mounted at runtime |
| `kdb/docker-compose.yml` | Three role q processes (`kdb-prices/trades/quotes`) + `hdb-builder` (writes the HDB) + `kdb-admin` (console) |
| `kdb/gen_data.q` | Builds the simulated `daily_prices`, `trades` and `quotes` tables in memory (fixed seed) |
| `kdb/build_hdb.q` | Writes them to `kdb/data/hdb/` as a date-partitioned HDB, plus the per-role views (`make kdb-hdb`) |
| `kdb/init.q` | Role process startup: loads the role's view, enables SQL, installs security, opens the port |
| `kdb/mkuser.sh <role>` | Creates or rotates a role's password and MCP config (`make kdb-users` does all three) |
| `kdb/test_security.q`, `kdb/test.sh` | Auth, read-only and isolation tests, run in each role's container (`make kdb-test`) |
| `kdb/expected.q` | Reference answers for the end-to-end tests |
