"""Table-level access control for user groups, enforced in the agent.

kdb itself only guarantees read-only (one login, mcp_ro, that can read every table). Which tables a
group may query is checked here, on every SQL tool call, before it reaches the MCP server:

    violation(sql, allowed) -> None if allowed, else the reason to block (fails closed).
"""

from pathlib import Path

import sqlglot
import yaml
from sqlglot import exp
from sqlglot.optimizer.scope import traverse_scope

GROUPS: dict[str, set[str]] = {
    group: {t.lower() for t in tables}
    for group, tables in yaml.safe_load((Path(__file__).parent / "groups.yaml").read_text()).items()
}
KNOWN_TABLES: set[str] = set().union(*GROUPS.values())

# Statements that change anything. kdb rejects writes anyway; this keeps the check self-contained.
WRITES = (exp.Insert, exp.Update, exp.Delete, exp.Create, exp.Drop, exp.Alter, exp.Merge, exp.Command)

# KX SQL escapes that evaluate arbitrary q: q(...) runs a q expression, qt(...) a q table expression.
# kdb blocks these authoritatively via its own parse tree; this is the matching second layer in the agent.
Q_ESCAPES = {"q", "qt"}


def violation(sql: str, allowed: set[str]) -> str | None:
    """Why this SQL must be blocked for a group allowed to read `allowed`, or None if it may run."""
    try:
        statements = [s for s in sqlglot.parse(sql, read="postgres") if s is not None]
    except sqlglot.errors.SqlglotError as e:
        return f"could not parse the SQL ({type(e).__name__})"
    if len(statements) != 1 or not isinstance(statements[0], exp.Query):
        return "only a single SELECT query is allowed"
    tree = statements[0]
    if tree.find(*WRITES):
        return "only read queries are allowed"
    if {f.name.lower() for f in tree.find_all(exp.Anonymous)} & Q_ESCAPES:
        return "q-escape functions (q/qt) are not allowed"
    try:
        # Tables each FROM/JOIN really reads, resolved per scope: a CTE named `trades` is not the table,
        # but `WITH trades AS (SELECT * FROM trades)` still reads the real `trades` inside the CTE.
        real = {src.name for scope in traverse_scope(tree) for src in scope.sources.values()
                if isinstance(src, exp.Table)}
    except Exception as e:  # noqa: BLE001 - any analysis failure means we can't vouch for the query
        return f"could not analyse the SQL ({type(e).__name__})"
    # Belt and braces: every table-like name must be an allowed table or a CTE defined in this query.
    ctes = {cte.alias_or_name for cte in tree.find_all(exp.CTE)}
    named = {t.name for t in tree.find_all(exp.Table)} - ctes
    # KX also resolves a table name used elsewhere, e.g. as a column (`SELECT trades FROM daily_prices`),
    # so any identifier or function name that is another group's table is blocked too.
    mentioned = {i.name.lower() for i in tree.find_all(exp.Identifier)} | \
                {f.name.lower() for f in tree.find_all(exp.Anonymous)}
    denied = sorted(({t.lower() or "<unnamed>" for t in real | named} | (mentioned & KNOWN_TABLES)) - allowed)
    if denied:
        return f"no access to table(s): {', '.join(denied)}"
    return None


def filter_schema(schema: str, allowed: set[str]) -> str:
    """Keep only the allowed tables' sections of the MCP server's kdbx://tables text.

    Hiding other tables isn't the protection (violation() is); it keeps the LLM from trying them.
    """
    marker = "TABLE ANALYSIS: "
    sections = schema.split(marker)[1:]  # sections[i] starts with the table name
    kept = [marker + s for s in sections if s.split()[0].lower() in allowed]
    return f"Tables you can query: {', '.join(sorted(allowed))}\n\n" + "\n".join(kept)
