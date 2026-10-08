"""The guard on the real path (agent -> MCP server -> kdb) with a scripted model instead of the LLM.

Needs make kdb + make mcp. No LLM quota used: make test
"""

import json

import pytest
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

import kdb_agent
from kdb_agent import SQL_TOOL, Caller, agent

pytestmark = pytest.mark.integration


def run_sql(group: str, sql: str, tmp_path) -> dict:
    """Have a scripted model call the SQL tool once as `group`; return what the tool returned."""
    kdb_agent.QUERY_LOG = tmp_path / "queries.jsonl"

    def model(messages, info: AgentInfo) -> ModelResponse:
        if len(messages) == 1:  # first turn: call the tool
            return ModelResponse(parts=[ToolCallPart(tool_name=SQL_TOOL, args={"query": sql})])
        return ModelResponse(parts=[TextPart("done")])

    with agent.override(model=FunctionModel(model)):
        result = agent.run_sync("q", deps=Caller(user="pytest", group=group))
    ret = next(p for m in result.all_messages() for p in getattr(m, "parts", []) if isinstance(p, ToolReturnPart))
    content = ret.content
    return content if isinstance(content, dict) else json.loads(content)


def test_allowed_table_reaches_kdb(tmp_path):
    out = run_sql("research", 'SELECT count(*) AS n FROM daily_prices WHERE "sym"=\'T001\'', tmp_path)
    assert out["status"] == "success" and out["data"][0]["n"] == 261
    entry = json.loads((tmp_path / "queries.jsonl").read_text().splitlines()[-1])
    assert entry["allowed"] and entry["group"] == "research"


def test_other_table_is_blocked_before_kdb(tmp_path):
    out = run_sql("research", "SELECT count(*) FROM trades", tmp_path)
    assert out["status"] == "error" and "Blocked: no access to table(s): trades" in out["message"]
    entry = json.loads((tmp_path / "queries.jsonl").read_text().splitlines()[-1])
    assert not entry["allowed"] and "trades" in entry["reason"]


def test_group_with_two_tables_can_join(tmp_path):
    sql = ('SELECT count(*) AS n FROM trades t JOIN quotes q ON t."sym"=q."sym" AND t."date"=q."date" '
           'WHERE t."date"=\'2026-09-30\' AND t."sym"=\'T001\'')
    assert run_sql("trading", sql, tmp_path)["status"] == "success"


def test_llm_sees_only_its_tables():
    import asyncio

    from access import GROUPS, filter_schema

    async def load():
        async with kdb_agent.toolset:
            await kdb_agent.load_mcp_context()
    asyncio.run(load())
    out = filter_schema(kdb_agent.state["schema"], GROUPS["trading"])
    assert "TABLE ANALYSIS: trades" in out and "TABLE ANALYSIS: quotes" in out
    assert "daily_prices" not in out and "Acme" not in out
