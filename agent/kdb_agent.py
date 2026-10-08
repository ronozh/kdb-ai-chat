"""Agent service: FastAPI + Pydantic AI, querying KDB-X through the KDB-X MCP server.

Every web user belongs to one group (Tomcat decides). The group's allowed tables (groups.yaml) are
enforced on every SQL tool call by guard() before it reaches the MCP server; see access.py.
"""

import asyncio
import json
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, Header, HTTPException  # noqa: E402
from pydantic import BaseModel  # noqa: E402
from pydantic_ai import Agent, RunContext  # noqa: E402
from pydantic_ai.exceptions import ModelHTTPError  # noqa: E402
from pydantic_ai.mcp import CallToolFunc, MCPToolset, ToolResult  # noqa: E402
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart  # noqa: E402

from access import GROUPS, filter_schema, violation  # noqa: E402

AGENT_MODEL = os.getenv("AGENT_MODEL", "google:gemini-3.5-flash")
MCP_URL = os.getenv("MCP_URL", "http://127.0.0.1:8000/mcp")
AGENT_TOKEN = os.getenv("AGENT_TOKEN", "")  # shared secret: only Tomcat may call /chat
QUERY_LOG = Path(os.getenv("QUERY_LOG", Path(__file__).parent / "logs" / "queries.jsonl"))
SQL_TOOL = "kdbx_run_sql_query"
RETRY_DELAYS = (5, 10)  # seconds; free-tier Gemini often returns 429/503. Keep well under Tomcat's 90s timeout.

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("agent")

INSTRUCTIONS = """You answer questions about market data (simulated stock prices, trades or quotes) stored in a KDB-X database.
You can only query the table(s) described below. If asked about other data, say you don't have access to it.
Rules:
- Always query the database with the kdbx_run_sql_query tool for any figure. Never estimate or calculate numbers yourself.
- In your answer, state the tickers and the date range you used.
- If a date has no data (weekend, holiday or out of range) or a ticker doesn't exist, say so plainly instead of guessing.
- You can only read data. Refuse any request to insert, change or delete data.
- If a query is blocked, tell the user; don't try to work around it.
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

# Used only if the MCP schema resource can't be read at startup.
FALLBACK_SCHEMA = """TABLE ANALYSIS: daily_prices
 date, sym (T001..T100), name, close (float), volume (long). One row per weekday per ticker.
TABLE ANALYSIS: trades
 date, sym (T001..T100), time, price (float), size (long). Intraday trades.
TABLE ANALYSIS: quotes
 date, sym (T001..T100), time, bid, ask (float), bsize, asize (long). Intraday quotes."""


@dataclass
class Caller:
    user: str
    group: str
    session: str = ""


async def guard(ctx: RunContext[Caller], call_tool: CallToolFunc, name: str, args: dict[str, Any]) -> ToolResult:
    """Runs before every MCP tool call: allow only SQL on the caller's tables; log every attempt."""
    caller = ctx.deps
    sql = str(args.get("query", ""))
    reason = f"tool {name} is not allowed" if name != SQL_TOOL else violation(sql, GROUPS[caller.group])
    log_query(caller, name, sql, reason)
    if reason:
        return {"status": "error", "message": f"Blocked: {reason}"}  # the LLM sees this and tells the user
    return await call_tool(name, args)


def log_query(caller: Caller, tool: str, sql: str, reason: str | None) -> None:
    """Append one JSON line per tool call, allowed or blocked, for later analysis.

    A model retry (429/503) re-runs the whole turn, so the same SQL can appear twice for one question.
    """
    QUERY_LOG.parent.mkdir(parents=True, exist_ok=True)
    entry = {"ts": datetime.now(timezone.utc).isoformat(), "user": caller.user, "group": caller.group,
             "session": caller.session, "tool": tool, "sql": sql, "allowed": reason is None, "reason": reason}
    with QUERY_LOG.open("a") as f:
        f.write(json.dumps(entry) + "\n")
    if reason:
        log.warning("blocked %s (%s): %s | %s", caller.user, caller.group, reason, sql)


toolset = MCPToolset(MCP_URL, process_tool_call=guard)
agent = Agent(AGENT_MODEL, deps_type=Caller, toolsets=[toolset], instructions=INSTRUCTIONS)
state = {"schema": FALLBACK_SCHEMA, "guidance": ""}      # MCP resources, read once at startup
sessions: dict[tuple[str, str], list[ModelMessage]] = {}  # (group, session_id) -> history; groups never share history


@agent.instructions
def db_context(ctx: RunContext[Caller]) -> str:
    """The caller's tables only, plus KX's SQL guidance."""
    return filter_schema(state["schema"], GROUPS[ctx.deps.group]) + "\n\n" + state["guidance"]


def unwrap(text: str) -> str:
    """The KX server returns kdbx://tables as JSON text of [{"type": "text", "text": ...}]; return the plain text."""
    try:
        return "\n".join(item["text"] for item in json.loads(text))
    except (ValueError, TypeError, KeyError):
        return text


async def load_mcp_context() -> None:
    """Read the MCP server's schema and SQL guidance resources."""
    for res in await toolset.list_resources():
        if res.name in ("kdbx_describe_tables", "kdbx_sql_query_guidance"):
            content = await toolset.read_resource(res.uri)
            text = content if isinstance(content, str) else "\n".join(map(str, content))
            state["schema" if res.name == "kdbx_describe_tables" else "guidance"] = unwrap(text)
    log.info("loaded MCP context: schema %d chars, guidance %d chars", len(state["schema"]), len(state["guidance"]))


@asynccontextmanager
async def lifespan(_: FastAPI):
    if not AGENT_TOKEN:
        raise RuntimeError("AGENT_TOKEN is not set (run: make secrets)")  # fail closed
    # Each agent run opens its own MCP connection, so the agent recovers when the MCP server restarts.
    try:
        async with toolset:
            await load_mcp_context()
    except Exception as e:  # keep the hand-written schema
        log.warning("could not read MCP resources, using fallback schema: %s", e)
    yield


app = FastAPI(title="kdb-ai-chat agent", lifespan=lifespan)


class ChatRequest(BaseModel):
    session_id: str
    user_id: str
    group: str
    question: str


class ChatResponse(BaseModel):
    session_id: str
    answer: str
    sql: list[str]
    duration_ms: int


def sql_from(messages: list[ModelMessage]) -> list[str]:
    """SQL the LLM asked to run this turn (including any that guard() blocked)."""
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
    if req.group not in GROUPS:
        raise HTTPException(status_code=403, detail=f"unknown group: {req.group}")
    caller = Caller(user=req.user_id, group=req.group, session=req.session_id)
    key = (req.group, req.session_id)
    start = time.perf_counter()
    for delay in (*RETRY_DELAYS, None):
        try:
            result = await agent.run(req.question, message_history=sessions.get(key), deps=caller)
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
        "session": req.session_id, "user": req.user_id, "group": req.group, "question": req.question, "sql": sql,
        "duration_ms": duration_ms, "input_tokens": usage.input_tokens, "output_tokens": usage.output_tokens,
        "requests": usage.requests,
    }))
    return ChatResponse(session_id=req.session_id, answer=result.output, sql=sql, duration_ms=duration_ms)


@app.get("/health")
async def health() -> dict:
    try:
        async with toolset:
            await toolset.read_resource("kdbx://tables")  # not cached: really reaches the MCP server and kdb
        mcp = {"ok": True}
    except Exception as e:
        mcp = {"ok": False, "error": str(e)}
    return {"status": "ok" if mcp["ok"] else "degraded", "model": AGENT_MODEL, "mcp": mcp}
