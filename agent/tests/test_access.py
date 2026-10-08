"""Unit tests for the table allowlist (access.py). No services needed: make test"""

import pytest

from access import GROUPS, filter_schema, violation

PRICES = {"daily_prices"}

ALLOWED = [  # real query shapes the agent produces
    'SELECT "close" FROM daily_prices WHERE "sym" = \'T001\' AND "date" = \'2026-06-15\'',
    'SELECT avg("close") FROM (SELECT "close" FROM daily_prices WHERE "sym"=\'T010\' ORDER BY "date" DESC LIMIT 20) t',
    'WITH m AS (SELECT a."sym" AS s, 100*(a."close"/b."close"-1) AS pct FROM daily_prices a JOIN daily_prices b '
    'ON b."sym"=a."sym" AND b."date"=a."date"-1 WHERE MOD(CAST(a."date" AS INTEGER), 7)<>2 UNION ALL '
    'SELECT a."sym", 1 FROM daily_prices a JOIN daily_prices b ON b."sym"=a."sym") SELECT s, pct FROM m',
    'SELECT "sym", last("close")/first("close")-1 AS ret FROM daily_prices GROUP BY "sym" ORDER BY ret DESC LIMIT 5',
    "SELECT * FROM daily_prices;",
    "SELECT * FROM DAILY_PRICES",
]

BLOCKED = [  # attempts to reach other tables, write, or confuse the parser
    "SELECT * FROM trades",
    'SELECT * FROM "trades"',
    "SELECT * FROM public.trades",
    "SELECT * FROM TRADES",
    "SELECT * FROM daily_prices, quotes",
    "SELECT * FROM daily_prices /* x */ , trades",
    "SELECT 1 FROM daily_prices WHERE \"sym\" IN (SELECT \"sym\" FROM trades)",
    "SELECT 1 FROM daily_prices WHERE EXISTS (SELECT 1 FROM quotes)",
    "SELECT (SELECT max(price) FROM trades) AS m FROM daily_prices",
    "SELECT * FROM daily_prices UNION ALL SELECT * FROM quotes",
    "WITH daily_prices AS (SELECT * FROM trades) SELECT * FROM daily_prices",
    "WITH trades AS (SELECT * FROM trades) SELECT * FROM trades",  # CTE shadowing a real table
    "SELECT * FROM information_schema.tables",
    "SELECT 1 FROM daily_prices; SELECT * FROM trades",
    "WITH d AS (DELETE FROM daily_prices RETURNING *) SELECT * FROM d",
    "DROP TABLE daily_prices",
    "INSERT INTO daily_prices SELECT * FROM daily_prices",
    "UPDATE daily_prices SET \"close\" = 0",
    "SELECT trades FROM daily_prices LIMIT 1",          # table name used as a column: KX resolves it
    "SELECT (trades).price AS p FROM daily_prices",
    "SELECT count(quotes) FROM daily_prices",
    "SELECT * FROM trades()",
    "SELECT * FROM qt('([]a:1 2)')",                   # KX q-escape: run a q table expression
    "SELECT q('J','count',\"close\") FROM daily_prices",  # KX q-escape: run a q expression
    "SELECT * FROM QT('([]a:1 2)')",                   # case-insensitive
    "SELEC * FRM daily_prices",
    "",
]


@pytest.mark.parametrize("sql", ALLOWED)
def test_allowed(sql):
    assert violation(sql, PRICES) is None


@pytest.mark.parametrize("sql", BLOCKED)
def test_blocked(sql):
    assert violation(sql, PRICES) is not None


def test_blocked_reason_names_the_table():
    assert violation("SELECT count(quotes) FROM daily_prices", PRICES) == "no access to table(s): quotes"
    assert "trades" in violation("SELECT * FROM trades()", PRICES)


def test_group_with_several_tables():
    assert violation("SELECT * FROM trades t JOIN quotes q ON t.\"sym\" = q.\"sym\"", GROUPS["trading"]) is None
    assert violation("SELECT * FROM daily_prices", GROUPS["trading"]) is not None


def test_groups_config():
    assert GROUPS == {"research": {"daily_prices"}, "trading": {"trades", "quotes"},
                      "all": {"daily_prices", "trades", "quotes"}}


def test_filter_schema_keeps_only_allowed_tables():
    schema = ("DATABASE SCHEMA OVERVIEW\n Found 3 table(s)\n\n  TABLE ANALYSIS: daily_prices\n cols a\n"
              "  TABLE ANALYSIS: quotes\n cols b\n  TABLE ANALYSIS: trades\n cols c\n")
    out = filter_schema(schema, {"trades"})
    assert "TABLE ANALYSIS: trades" in out and "cols c" in out
    assert "daily_prices" not in out and "quotes" not in out and "Found 3" not in out
