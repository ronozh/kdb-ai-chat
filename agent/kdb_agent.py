"""Agent service: FastAPI + Pydantic AI, querying KDB-X through the KDB-X MCP server."""

import asyncio
import json
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, Header, HTTPException  # noqa: E402
from pydantic import BaseModel  # noqa: E402
from pydantic_ai import Agent, RunContext  # noqa: E402
from pydantic_ai.exceptions import ModelHTTPError  # noqa: E402
from pydantic_ai.mcp import MCPToolset  # noqa: E402
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart  # noqa: E402

AGENT_MODEL = os.getenv("AGENT_MODEL", "google:gemini-3.5-flash")
# One MCP server per role; each logs in to kdb as that role's read-only user and sees only that role's table.
ROLE_MCP_URLS = {
    "prices": os.getenv("MCP_URL_PRICES", "http://127.0.0.1:8101/mcp"),
    "trades": os.getenv("MCP_URL_TRADES", "http://127.0.0.1:8102/mcp"),
    "quotes": os.getenv("MCP_URL_QUOTES", "http://127.0.0.1:8103/mcp"),
}
AGENT_TOKEN = os.getenv("AGENT_TOKEN", "")  # shared secret: only Tomcat may call /chat
SQL_TOOL = "kdbx_run_sql_query"
RETRY_DELAYS = (5, 10)  # seconds; free-tier Gemini often returns 429/503. Keep well under Tomcat's 90s timeout.

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("agent")

INSTRUCTIONS = """You answer questions about market data (simulated stock prices, trades or quotes) stored in a KDB-X database.
You can only see the table(s) described below. If asked about data not in them, say you don't have access to it.
Rules:
- Always query the database with the kdbx_run_sql_query tool for any figure. Never estimate or calculate numbers yourself.
- In your answer, state the tickers and the date range you used.
- If a date has no data (weekend, holiday or out of range) or a ticker doesn't exist, say so plainly instead of guessing.
- You can only read data. Refuse any request to insert, change or delete data.
- Keep answers short.

KDB-X SQL dialect notes:
- Quote column names with double quotes: "date", "sym", "close", "volume", "name". Date literals: '2026-06-15'.
- Date arithmetic works: "date"-1. Aggregates: avg, sum, count, min, max, first, last.
- Not supported: window functions (LAG, OVER), abs(), correlated subqueries in SELECT, inequality conditions in JOIN ... ON.
- Period return per ticker: SELECT "sym", last("close")/first("close")-1 AS ret FROM daily_prices WHERE ... GROUP BY "sym".
- N-day moving average as of the latest date: avg over (SELECT "close" ... ORDER BY "date" DESC LIMIT N).
- Weekday: MOD(CAST("date" AS INTEGER), 7) gives 2=Mon .. 6=Fri (0=Sat, 1=Sun).
- Previous trading day (data has weekdays only): join b."date"=a."date"-1 WHERE weekday<>2,
  UNION ALL join b."date"=a."date"-3 WHERE weekday=2 (Mondays look back to Friday).
- Absolute value: CASE WHEN x<0 THEN -x ELSE x END.
"""

FALLBACK_SCHEMA = {
    "prices": "Table daily_prices: date, sym (T001..T100), name, close (float), volume (long). One row per weekday per ticker.",
    "trades": "Table trades: date, sym (T001..T100), time, price (float), size (long). Intraday trades.",
    "quotes": "Table quotes: date, sym (T001..T100), time, bid, ask (float), bsize, asize (long). Intraday quotes.",
}

toolsets = {role: MCPToolset(url) for role, url in ROLE_MCP_URLS.items()}
# No toolsets on the agent itself: each run gets exactly one, chosen by our code from the caller's role (never by the LLM).
agent = Agent(AGENT_MODEL, deps_type=str, instructions=INSTRUCTIONS)
contexts: dict[str, str] = dict(FALLBACK_SCHEMA)          # role -> schema + SQL guidance text
sessions: dict[tuple[str, str], list[ModelMessage]] = {}  # (role, session_id) -> history; roles never share history


@agent.instructions
def db_context(ctx: RunContext[str]) -> str:
    return contexts[ctx.deps]  # ctx.deps is the role of this run


async def load_mcp_context(role: str) -> None:
    """Add the role's MCP schema and SQL guidance resources to its instructions."""
    toolset, parts = toolsets[role], []
    for res in await toolset.list_resources():
        if res.name in ("kdbx_describe_tables", "kdbx_sql_query_guidance"):
            content = await toolset.read_resource(res.uri)
            parts.append(content if isinstance(content, str) else "\n".join(map(str, content)))
    if parts:
        contexts[role] = "\n\n".join(parts)
    log.info("role %s: loaded MCP context, %d resources, %d chars", role, len(parts), len(contexts[role]))


@asynccontextmanager
async def lifespan(_: FastAPI):
    if not AGENT_TOKEN:
        raise RuntimeError("AGENT_TOKEN is not set (run: make secrets)")  # fail closed
    # Each agent run opens its own MCP connection, so the agent recovers when an MCP server restarts.
    for role, toolset in toolsets.items():
        try:
            async with toolset:
                await load_mcp_context(role)
        except Exception as e:  # keep the hand-written schema
            log.warning("role %s: could not read MCP resources, using fallback schema: %s", role, e)
    yield


app = FastAPI(title="kdb-ai-chat agent", lifespan=lifespan)


class ChatRequest(BaseModel):
    session_id: str
    user_id: str
    role: str
    question: str


class ChatResponse(BaseModel):
    session_id: str
    answer: str
    sql: list[str]
    duration_ms: int


def sql_from(messages: list[ModelMessage]) -> list[str]:
    return [
        str(part.args_as_dict().get("query", ""))
        for m in messages
        if isinstance(m, ModelResponse)
        for part in m.parts
        if isinstance(part, ToolCallPart) and part.tool_name == SQL_TOOL
    ]


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest, x_agent_token: str = Header(default="")) -> ChatResponse:
    if not secrets.compare_digest(x_agent_token, AGENT_TOKEN):
        raise HTTPException(status_code=401, detail="missing or invalid X-Agent-Token")
    if req.role not in toolsets:
        raise HTTPException(status_code=403, detail=f"unknown role: {req.role}")
    key = (req.role, req.session_id)
    start = time.perf_counter()
    for delay in (*RETRY_DELAYS, None):
        try:
            result = await agent.run(req.question, message_history=sessions.get(key),
                                     deps=req.role, toolsets=[toolsets[req.role]])
            break
        except ModelHTTPError as e:
            daily_quota = "PerDay" in str(e.body)  # retrying a daily quota is pointless
            if e.status_code not in (429, 503) or daily_quota or delay is None:
                log.exception("agent run failed")
                raise HTTPException(status_code=502, detail=f"model error: {e}") from e
            log.warning("model returned %s, retrying in %ss", e.status_code, delay)
            await asyncio.sleep(delay)
        except Exception as e:
            log.exception("agent run failed")
            raise HTTPException(status_code=502, detail=f"agent error: {e}") from e
    sessions[key] = result.all_messages()
    sql = sql_from(result.new_messages())
    duration_ms = int((time.perf_counter() - start) * 1000)
    usage = result.usage
    log.info(json.dumps({
        "session": req.session_id, "user": req.user_id, "role": req.role, "question": req.question, "sql": sql,
        "duration_ms": duration_ms, "input_tokens": usage.input_tokens, "output_tokens": usage.output_tokens,
        "requests": usage.requests,
    }))
    return ChatResponse(session_id=req.session_id, answer=result.output, sql=sql, duration_ms=duration_ms)


@app.get("/health")
async def health() -> dict:
    roles = {}
    for role, toolset in toolsets.items():
        try:
            async with toolset:
                await toolset.read_resource("kdbx://tables")  # not cached: really reaches the MCP server and kdb
            roles[role] = {"ok": True}
        except Exception as e:
            roles[role] = {"ok": False, "error": str(e)}
    ok = all(r["ok"] for r in roles.values())
    return {"status": "ok" if ok else "degraded", "model": AGENT_MODEL, "roles": roles}
