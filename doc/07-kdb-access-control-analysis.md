# 7. Analysis: read-only, table-level access control in kdb+

A deeper look at *why* our access control sits in the agent, what kdb+ can and can't do natively, the
vulnerability this surfaced, and the alternatives. Written for a reader new to kdb+. Design: [06-access-control.md](06-access-control.md).

## 1. Terms and background

- **kdb+ / KDB-X** — a column-oriented database. Its language is **q**. A running database is a **q process** ([02-kdb.md](02-kdb.md)).
- **q** — the language. Crucially, q can evaluate text as code at runtime (`value "a:1"` creates variable `a`), and `select`/`update`/`delete` are ordinary q verbs.
- **IPC / handle** — a client connects over TCP and sends a message. The server runs it and returns the result. There is no fixed "query protocol"; a message is q to be evaluated.
- **`.z.*` handlers** — callbacks q runs on events. The security-relevant ones:
  - `.z.pw[user;password]` — on login; return `0b` to reject.
  - `.z.pg[x]` / `.z.ps[x]` — on a synchronous / asynchronous message; `x` is what the client sent. The default is `value x` (run it). **This is the single choke point for every query.**
- **`reval`** — "restricted evaluation": run something as if the command-line flags `-u 1` and `-b` were set. It blocks writes to globals, writes to the filesystem, state-changing system calls, `exit`, and `hopen` of a file. It is kdb's building block for a read-only sandbox ([reference](https://code.kx.com/q/ref/eval/)).
- **`-b`, `-u`, `-U`** — command-line flags: `-b` makes clients read-only; `-u`/`-U` set a password file; `-u` also confines file access to the start directory.
- **SQL in KDB-X (`.s.e`)** — KX ships an ANSI-SQL layer that **translates SQL into q at runtime** and runs it. We use it because LLMs write SQL well.

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

### Benign proof

On a throwaway test I confirmed, using only harmless probes on my own machine, that a `SELECT` from the `mcp_ro` account could **create a global variable** — a write — through `qt(...)`. In shorthand, the `qt(...)` argument was a tiny q table expression that, as a side effect, set a dummy global `zzprobe`. Before the fix the variable appeared; the account was supposedly read-only, so that should have been impossible. The same mechanism could read files the process can read or run shell commands — I did not exercise those beyond confirming the class of problem, and I'm not publishing payloads.

Our earlier test suite missed this because it only tried **plain q function names** (`system`, `value`), which KX SQL rejects — it did not try KX's own `q(...)`/`qt(...)` wrappers.

### The fix (committed)

Defence in depth, blocking the escape **before** `.s.e`:
1. **kdb (authoritative), `kdb/init.q`:** `.sec.fnames` extracts the function names called in the SQL — an identifier immediately before `(`, on the unquoted text so string literals can't hide it — and rejects the query if `q` or `qt` is called. This is syntactic, so it distinguishes the escape `q(...)` from a table alias `q` or a qualified column `q."date"` (neither is followed by `(`), and doesn't false-positive on names like `freq(`.
2. **agent (second layer), `agent/access.py`:** sqlglot already models `q(...)`/`qt(...)` as function calls, so `violation()` blocks them too. This matters because the MCP server has no auth of its own: anything that can reach it bypasses the agent otherwise.
3. **kdb stays read-only** underneath, and the credentials file password was rotated.
4. **Regression tests** (benign probes) in `kdb/test_security.q` and `agent/tests/test_access.py`.

The broader lesson, and KX's own: **a text/parse check over free-form SQL is a hardening layer, not a guarantee.** The guarantees are process-level read-only (`reval`) and process-level table scope (loading only some tables). That is exactly why the strongest option (§4) is physical separation.

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
