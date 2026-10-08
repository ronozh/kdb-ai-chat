# 7. Analysis: read-only, table-level access control in kdb+

A deeper look at *why* our access control sits in the agent, what kdb+ can and can't do natively, the
vulnerability this surfaced, and the alternatives. Written for a reader new to kdb+. Design: [06-access-control.md](06-access-control.md).

## 1. Concepts primer (for a kdb newcomer)

Before the analysis, the pieces that keep coming up. The one mental model to hold onto:

> **In kdb+, a client doesn't send a "query" to a query engine. It sends a message that the server
> *evaluates as code*. Security is therefore not a database setting — it is whatever the server's
> handler function decides to do with that code.**

### The running database is a q process

**kdb+** (new name **KDB-X**) is a column database; its language is **q**. A live database is just a
running `q` program — a **q process** — listening on a TCP port ([02-kdb.md](02-kdb.md)). Its tables are
variables in that process. There is no separate "server daemon" with its own permission system.

### q evaluates text as code

q can turn text into running code at any time. `value "a:1"` creates a variable `a` set to 1.
`select`, `update`, `delete`, reading a file, launching a shell command — all are ordinary q expressions,
not privileged operations gated by the database. This is powerful and is exactly why access control is hard.

### IPC and handles

A client connects over TCP and **opens a handle** (an integer). Sending a string on that handle asks the
server to **evaluate that string** and return the result:

```q
h:hopen `::5000           / connect
h "count daily_prices"    / server evaluates this q, returns a number
```

There is no fixed "query protocol". A message is just q (or, for us, a small wrapper that runs SQL). So
"what is this client allowed to do?" is decided entirely by the server-side handler that receives the message.

### `.z.*` handlers — the hooks you override

q calls certain functions automatically on events. You redefine them to add security. The ones here:

| Handler | Fires when… | Default behaviour | We use it to… |
|---|---|---|---|
| `.z.pw[user;pwd]` | a client logs in | accept | check the password; return `0b` to reject |
| `.z.pg[x]` | a **sync** message `x` arrives | `value x` (run it) | decide what runs, and how (sandbox or SQL-check) |
| `.z.ps[x]` | an **async** message `x` arrives | `value x` | same, always sandboxed |
| `.z.ph` / `.z.pp` / `.z.ws` | HTTP / websocket request | serve it | refuse (we disable these) |

`.z.pg` is **the single choke point**: every synchronous client query passes through it. If `.z.pg` just
did `value x` (the default), any client could run any q. Our `.z.pg` instead sandboxes or restricts the message.

### `-b` — the process-wide read-only switch

A command-line flag. `q … -b` makes **every** client connection read-only: clients can't amend data.
It's all-or-nothing for the whole process and not tied to any username. We **don't** use it, because it also
blocks the internal write that KX's SQL engine needs (see `.s.e` below), which would break SQL entirely.

### `-u` / `-U` — the password file (and file confinement)

`-U file` loads a `user:password` file (the built-in login). `-u file` does the same **and** confines file
access to the start directory and below. KX recommends real directory services (LDAP/Kerberos) for
production; the built-in file is development-grade. We implement login in `.z.pw` instead, so we can salt and
hash and re-read the file per login.

### `reval` — restricted (read-only) evaluation

`reval x` runs the parse tree `x` **as if `-b` and `-u 1` were active**. Concretely it blocks: writes to
global variables, writes to the filesystem, state-changing system calls (e.g. launching a shell), `exit`,
and opening a file handle ([reference](https://code.kx.com/q/ref/eval/)). It's an **opt-in sandbox you wrap
around one evaluation** — not an account setting. Our `.z.pg` runs ordinary client q as `reval(…)`, which is
what actually makes those queries read-only.

```q
reval parse "a:1"      / 'noupdate  — blocked: can't create/amend a global
reval parse "count daily_prices"   / fine — a read
```

### `.s.e` — the SQL interface

KX ships an ANSI-SQL layer. `.s.e "SELECT …"` **translates the SQL into q at runtime and runs it**. We use it
because LLMs write SQL well. Two consequences matter for security:
1. `.s.e` itself writes to an internal counter as it runs, so it **cannot run inside `reval`** (reval would
   block that write). We therefore run it **outside** the sandbox and restrict the SQL *text* instead.
2. KX SQL has escape functions — `q(…)`, `qt(…)`, `.s.F` — that run **arbitrary q from inside a SELECT**.
   Combined with (1), that is the vulnerability in §3.

### Putting it together: is `mcp_ro` a "read-only account"?

**No — there is no such thing in kdb+.** `mcp_ro` is only a label in the password file. Nothing in kdb ties
that name to "may not write". The account is read-only *only because* our `.z.pg`:
- runs q messages through `reval` (sandboxed), and
- lets the SQL path run `.s.e` only after the SQL text passes our checks.

If a path reaches `.s.e` outside `reval` with q smuggled inside it, **kdb will happily write** — the "read-only
account" never promised otherwise. That is precisely what §3 is about.

## 2. The core limitation

> **kdb+ has no built-in, table-level, role-based access control. It has authentication and a read-only switch for a whole process, and hooks to build the rest yourself.**

What is built in:
- **Authentication:** a password file plus `.z.pw`. KX advises real directories (LDAP/Kerberos) in production, i.e. the built-in password file is for development ([KX: Security made simple](https://kx.com/blog/security-made-simple-how-to-protect-kdb-with-iam/)).
- **Process-wide read-only:** `-b` or `reval`.

What is **not** built in, and must be hand-written in `.z.pg`:
- Per-user or per-role permissions.
- Table-level or column-level or row-level rules.

KX's own whitepaper, [*Permissions with kdb+*](https://code.kx.com/q/wp/permissions/), is the reference for building it. It implements user classes (user / poweruser / superuser), table permissions and function hiding by **inspecting the parse tree** of each query in `.z.pg`. Its own stated caveats matter:

> *"While the approach presented in this paper so far has outlined various methods of restricting users from executing particular queries, it is not immune to circumvention."*

> *"the approach presented here is merely intended as a starting point, and as such it should not be considered secure"*

It documents concrete bypasses (leading-semicolon injection, elevation through stored-procedure arguments, several ways to reach a function). The lesson: **inspecting free-form queries to decide access is hard to get completely right.** A widely-cited third-party guide ([TimeStored](https://www.timestored.com/kdb-guides/kdb-security-user-permissions)) and the KX blog say the same — kdb gives you the hooks, and *"it is very much up to you to write that code."*

### Why free-form SQL makes it harder

Our clients send **SQL**, not q. To apply a table rule you must know which tables a query reads. KX SQL does expose its parse tree (`.s.prx`), but:
- The SQL-to-q translation internals are not a supported, stable API.
- The parse tree does **not** cleanly separate a table reference from, say, a column qualified by a table alias (`q."date"` compiles to the same shape as the function call `q(...)`). We hit this while building the guard.

KX's commercial platform concedes the same point from the other direction: its row-level entitlements **require free-form queries to be turned off**. See §5.

## 3. The vulnerability this surfaced (and the fix)

Building the guard surfaced a real hole in our own first design. It is worth understanding in full, because it is the crux of why "read-only free-form SQL" is dangerous.

### Background: why our SQL runs outside the sandbox

Every other query in our server runs inside `reval` (the read-only sandbox). The SQL path is the **exception**: KX's `.s.e` writes to an internal counter as it runs, so it fails inside `reval`. Our code therefore runs `.s.e` **outside** the sandbox, and instead restricts the SQL text to a single `SELECT`/`WITH` ([02-kdb.md §8](02-kdb.md#8-how-this-project-secures-kdb)). "Outside the sandbox" means: if any q code runs on that path, none of reval's protections (no writes, no file access, no system calls) apply.

### The gap: KX SQL can call q

KX SQL has escape hatches that **evaluate arbitrary q from inside a SELECT** ([SQL reference](https://code.kx.com/modules/sql/reference.html)):
- `q('<q expression>')` — run a q expression anywhere in the statement.
- `qt('<q table expression>')` — run a q expression that returns a table, in `FROM`.
- `.s.F` — register a q function as a SQL function.

So a query that is syntactically a read-only `SELECT` can carry q code in a `qt(...)`/`q(...)` call. Because `.s.e` runs outside `reval`, that q code runs with the process's full rights — **even though `mcp_ro` is a "read-only" account.** "Read-only" was enforced by `reval` and by text rules that only looked for SQL keywords like `INSERT`; neither covers q smuggled inside `qt(...)`.

### Why "the account is read-only, so kdb should block the write" is wrong

This is the natural objection, and the answer is the §1 mental model: kdb has no read-only *account*. A write
is blocked only when it runs **inside `reval`**. Our q path uses `reval`, so q writes are blocked. The SQL
path runs `.s.e` **outside** `reval` (it has to), so on that path *nothing* was watching for a write except a
text check for keywords like `INSERT`. `qt('… update … ')` contains no such keyword at the top level — the
write is q hidden inside the escape — so it sailed through and kdb executed it. kdb wasn't bypassed; it was
never told to stop writes on that path.

### Proof: a read-only account changing a table value

Confirmed on a **throwaway** q process (an in-memory copy, no security layer — *not* the real server). The
SQL below looks like a read (`SELECT … FROM qt(…)`), but its `qt(...)` argument contains q that updates the
table as a side effect:

```q
.s.init[];
daily_prices:([] sym:`T001`T002; close:10 20f);
show select from daily_prices where sym=`T001;    / close=10
/ a "SELECT" whose qt(...) argument runs:  update close:999f from daily_prices where sym=`T001
.s.e "SELECT * FROM qt('([]d:enlist `$string .[`daily_prices;();:;update close:999f from daily_prices where sym=`T001])')";
show select from daily_prices where sym=`T001;    / close=999  <- written by a "read-only" session
.[`daily_prices;();:;update close:10f from daily_prices where sym=`T001];   / restore
```

Observed: `10` → `999` → `10`. The reusable mechanism is "wrap a q write inside `qt('…')`"; the outer SQL is
only there to look like a SELECT. The same q could read a readable file or run a shell command.

Our earlier test suite missed this because it only tried **plain q function names** (`system`, `value`), which
KX SQL rejects — it did not try KX's own `q(...)`/`qt(...)` wrappers.

### A note on the *real* server

On the live server `daily_prices` is loaded from an **OS read-only mount** (`./data/hdb:/db:ro`), so the files
on disk can't change regardless. But the escape could still corrupt the **in-memory** copy other users see
until restart, create globals, read any file the process can read, or run shell commands. The read-only mount
protects stored data, not the process — which is why the escape itself must be blocked.

### The fix (committed)

Defence in depth, blocking the escape **before** `.s.e`:
1. **kdb (authoritative), `kdb/init.q`:** `.sec.fnames` extracts the function names called in the SQL — an identifier immediately before `(`, on the unquoted text so string literals can't hide it — and rejects the query if `q` or `qt` is called. This is syntactic, so it distinguishes the escape `q(...)` from a table alias `q` or a qualified column `q."date"` (neither is followed by `(`), and doesn't false-positive on names like `freq(`.
2. **agent (second layer), `agent/access.py`:** sqlglot already models `q(...)`/`qt(...)` as function calls, so `violation()` blocks them too. This matters because the MCP server has no auth of its own: anything that can reach it bypasses the agent otherwise.
3. **kdb stays read-only** underneath, and the credentials file password was rotated.
4. **Regression tests** (benign probes) in `kdb/test_security.q` and `agent/tests/test_access.py`.

The broader lesson, and KX's own: **a text/parse check over free-form SQL is a hardening layer, not a guarantee.** The guarantees are process-level read-only (`reval`) and process-level table scope (loading only some tables). That is exactly why the strongest option (§4) is physical separation.

### Try it yourself

**A. See the escape BLOCKED on the real (fixed) server.** Open a client session:

```bash
docker exec -it --env-file mcp-server/.env kdbx q
```

Paste (this sends the SQL exactly as the MCP server would):

```q
h:hopen `$"::5000:mcp_ro:",getenv`KDBX_DB_PASSWORD
sqlCall:"{r:.s.e x;`rowCount`data!(count r;.j.j y sublist r)}"
h(sqlCall;"SELECT * FROM qt('([]x:enlist `zzprobe set 1)')";10)   / tries to create a global via qt()
h"zzprobe"                                                        / was it written?
```

Expected: the call raises `'q-escape functions (q/qt) are not allowed`, and `h"zzprobe"` raises `'zzprobe`
(no global created). A normal read like `h(sqlCall;"SELECT \"close\" FROM daily_prices WHERE \"sym\"='T001' LIMIT 1";10)` still works.

**B. See the write SUCCEED on a throwaway (unfixed, in-memory copy — never the real server).** Save this as
`write-demo.q`:

```q
.s.init[];
daily_prices:([] sym:`T001`T002; close:10 20f);
show select from daily_prices where sym=`T001;    / close=10
.s.e "SELECT * FROM qt('([]d:enlist `$string .[`daily_prices;();:;update close:999f from daily_prices where sym=`T001])')";
show select from daily_prices where sym=`T001;    / close=999  <- written from a "read-only" session
.[`daily_prices;();:;update close:10f from daily_prices where sym=`T001];   / restore
show select from daily_prices where sym=`T001;    / close=10
```

Run it in a throwaway container (it never touches the real server or the HDB files):

```bash
docker run --rm -v ~/qlic:/opt/kx/lic:ro -v "$PWD/write-demo.q:/t.q:ro" kdb-ai-chat/kdbx q /t.q -q
```

This is the whole point in one screen: the same `qt('…')` wrapper that A blocks is, without the block, a
working write from a "read-only" session.

## 4. Options for our use case (≤5 fixed groups, read-only, strong table access, operational simplicity)

| # | Option | How it works | Isolation strength | Ops simplicity | Dynamic groups |
|---|---|---|---|---|---|
| A | **Agent SQL allowlist** (current) | One read-only kdb, one MCP server; the agent parses each query and blocks tables outside the group | Medium — the agent is the enforcement point; kdb guarantees only read-only | High — one of everything; groups are config | Easy (edit `groups.yaml`) |
| B | **One kdb process per group** | Each group's q process loads only its tables; a group can't query a table it never loaded | Strong — enforced by what's loaded, nothing to parse | Medium — N processes + N MCP servers; combining tables per group needs linking | Medium (new process) |
| C | **One HDB per data domain** | Standard kdb layout; each domain is a separate database and process | Strong | Medium — no cross-domain SQL joins | Medium |
| D | **Gateway with entitlements** | A q gateway authenticates the end user and exposes **fixed query APIs** (not free SQL), applying per-user table/row rules | Strong, and row/column capable | Low — most to build; this is the classic production pattern | Easy (entitlements are data) |
| E | **Semantic layer** | Clients choose metrics/dimensions, not SQL; the layer generates the query and checks entitlements | Strong, and most accurate for the LLM | Low — most to build | Easy |
| F | **KX commercial (kdb Insights)** | Built-in database and row-level entitlements | Strong, vendor-supported | N/A — licensed product | Easy |

### Why A is the right fit now

Given your constraints — few fixed groups, table-level (not row/column) rules, safety first, and operational simplicity — **A (what we built) is the pragmatic choice**, provided two things hold:
1. **kdb is genuinely read-only.** It is: one read-only login, `reval` for q, the SELECT-only + q-escape checks for SQL, and a read-only data mount. This is the hard guarantee that survives even if the agent check is wrong.
2. **Network isolation in production.** Only the agent may reach the MCP server; only the MCP server may reach kdb. Without this, the agent check can be skipped (the MCP server has no auth). This is **not** enforced in the demo.

Option **B** is stronger and we built it first; it's the right choice if a group's data is **regulated** and must be physically unreachable by others. Its cost is the per-group processes and the non-standard hard-link trick to give a group several tables from one copy of the data.

Options **D/E** are where you go when access becomes **dynamic or finer than whole tables** (per-user, per-row, per-column). They move from "check the SQL" to "don't accept free SQL at all" — which, as §2–§3 show, is the only way to make entitlements airtight over an LLM. KX's platform (F) reaches the same conclusion by requiring qsql to be disabled.

**Recommendation:** keep A, keep kdb read-only as the real guarantee, and add network isolation for production. Reach for B for any single group whose data is regulated. Plan for D/E only if you later need row/column rules or many dynamic groups.

## 5. Evidence: what KX's own products do

KX's commercial [kdb Insights Enterprise](https://code.kx.com/insights/enterprise/entitlements/data-entitlements.html) is the clearest statement that this is a real gap core kdb+ doesn't fill:
- Entitlements are **database-level** by default, with optional **row-level** policies (q functions that filter rows). Column-level isn't offered.
- They are **restrictive by default**: once row policies are on, users see no rows until a policy grants them.
- Critically, on the bypass problem: *"The `qsql` API bypasses row-level database entitlements and enables access to data in any database regardless of any row-level entitlements that have been configured."* You must **disable qsql** to enforce row-level rules ([row-level entitlements](https://code.kx.com/insights/enterprise/entitlements/row-level-entitlements.html)).

That is the same lesson as §3, from the vendor: **you cannot both allow arbitrary query code and enforce fine-grained data rules.** One has to give. Our design gives up arbitrary *q* (read-only, SELECT-only, no q-escape) and keeps SQL; a fully entitlement-driven system gives up free-form queries entirely.

## 6. References

- KX, *Permissions with kdb+* (whitepaper): <https://code.kx.com/q/wp/permissions/>
- KX, *Security made simple: how to protect kdb+ with IAM*: <https://kx.com/blog/security-made-simple-how-to-protect-kdb-with-iam/>
- kdb+ `reval` reference: <https://code.kx.com/q/ref/eval/>
- kdb+ command-line options (`-b`, `-u`, `-U`): <https://code.kx.com/q/basics/cmdline/>
- KDB-X SQL reference (incl. `q()`, `qt()`, `.s.F`, `.s.e`): <https://code.kx.com/modules/sql/reference.html>
- kdb Insights data entitlements: <https://code.kx.com/insights/enterprise/entitlements/data-entitlements.html>
- kdb Insights row-level entitlements: <https://code.kx.com/insights/enterprise/entitlements/row-level-entitlements.html>
- TimeStored, kdb security & user permissions: <https://www.timestored.com/kdb-guides/kdb-security-user-permissions>
- AquaQ TorQ (open-source kdb+ framework with a permissions module): <https://github.com/AquaQAnalytics/TorQ>
