"""Service guards without the LLM: agent token and group checks, Tomcat user mapping, health. Run: make test"""

import os

import httpx
import pytest
from dotenv import dotenv_values

AGENT_URL = os.getenv("AGENT_URL", "http://127.0.0.1:8001")
TOMCAT_URL = os.getenv("TOMCAT_URL", "http://127.0.0.1:8090")
AGENT_TOKEN = dotenv_values(os.path.join(os.path.dirname(__file__), "..", ".env")).get("AGENT_TOKEN", "")
pytestmark = pytest.mark.integration


def test_agent_requires_token():
    r = httpx.post(f"{AGENT_URL}/chat", json={"session_id": "t", "user_id": "u", "group": "research", "question": "hi"})
    assert r.status_code == 401


def test_agent_rejects_unknown_group():
    r = httpx.post(f"{AGENT_URL}/chat", headers={"X-Agent-Token": AGENT_TOKEN},
                   json={"session_id": "t", "user_id": "u", "group": "admin", "question": "hi"})
    assert r.status_code == 403


@pytest.mark.parametrize("user", [None, "mallory", "demo"])
def test_tomcat_rejects_unknown_users(user):
    headers = {"X-Demo-User": user} if user else {}
    r = httpx.post(f"{TOMCAT_URL}/api/chat", json={"question": "hi"}, headers=headers)
    assert r.status_code == 403


def test_health():
    body = httpx.get(f"{TOMCAT_URL}/api/health", timeout=30).json()
    assert body["agent"]["mcp"]["ok"]
