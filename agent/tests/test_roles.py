"""Role isolation without the LLM: talks to the agent, Tomcat and each role's MCP server directly. Run: make test"""

import json
import os

import httpx
import pytest
from dotenv import dotenv_values

AGENT_URL = os.getenv("AGENT_URL", "http://127.0.0.1:8001")
TOMCAT_URL = os.getenv("TOMCAT_URL", "http://127.0.0.1:8090")
AGENT_TOKEN = dotenv_values(os.path.join(os.path.dirname(__file__), "..", ".env")).get("AGENT_TOKEN", "")
ROLE_TABLE = {"prices": "daily_prices", "trades": "trades", "quotes": "quotes"}
ROLE_MCP = {"prices": 8101, "trades": 8102, "quotes": 8103}
pytestmark = pytest.mark.integration


def mcp(port: int, method: str, params: dict | None = None):
    """Minimal MCP client: initialize a session, send one JSON-RPC request, return its result."""
    url = f"http://127.0.0.1:{port}/mcp"
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}

    def post(body: dict, headers: dict) -> httpx.Response:
        return httpx.post(url, json={"jsonrpc": "2.0", **body}, headers=headers, timeout=30)

    init = post({"id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "pytest", "version": "1"}}}, h)
    h["Mcp-Session-Id"] = init.headers["mcp-session-id"]
    post({"method": "notifications/initialized"}, h)
    r = post({"id": 2, "method": method, "params": params or {}}, h)
    data = next(line[6:] for line in r.text.splitlines() if line.startswith("data: "))
    return json.loads(data)["result"]


def sql(port: int, query: str) -> dict:
    res = mcp(port, "tools/call", {"name": "kdbx_run_sql_query", "arguments": {"query": query}})
    return json.loads(res["content"][0]["text"])


@pytest.mark.parametrize("role", ROLE_MCP)
def test_mcp_schema_shows_only_own_table(role):
    text = mcp(ROLE_MCP[role], "resources/read", {"uri": "kdbx://tables"})["contents"][0]["text"]
    assert "Found 1 table" in text and f"TABLE ANALYSIS: {ROLE_TABLE[role]}" in text


@pytest.mark.parametrize("role", ROLE_MCP)
def test_mcp_sql_only_own_table(role):
    for other_role, table in ROLE_TABLE.items():
        result = sql(ROLE_MCP[role], f'SELECT count(*) AS n FROM {table} WHERE "sym"=\'T001\'')
        if other_role == role:
            assert result["status"] == "success"
        else:
            assert result["status"] == "error" and "can't lookup" in result["message"]


@pytest.mark.parametrize("role", ROLE_MCP)
def test_mcp_writes_blocked(role):
    result = sql(ROLE_MCP[role], f"DROP TABLE {ROLE_TABLE[role]}")
    assert result["status"] == "error"


def test_agent_requires_token():
    r = httpx.post(f"{AGENT_URL}/chat", json={"session_id": "t", "user_id": "u", "role": "prices", "question": "hi"})
    assert r.status_code == 401


def test_agent_rejects_unknown_role():
    r = httpx.post(f"{AGENT_URL}/chat", headers={"X-Agent-Token": AGENT_TOKEN},
                   json={"session_id": "t", "user_id": "u", "role": "admin", "question": "hi"})
    assert r.status_code == 403


@pytest.mark.parametrize("user", [None, "mallory", "demo"])
def test_tomcat_rejects_unknown_users(user):
    headers = {"X-Demo-User": user} if user else {}
    r = httpx.post(f"{TOMCAT_URL}/api/chat", json={"question": "hi"}, headers=headers)
    assert r.status_code == 403


def test_health_all_roles():
    body = httpx.get(f"{TOMCAT_URL}/api/health", timeout=30).json()
    assert all(r["ok"] for r in body["agent"]["roles"].values())
