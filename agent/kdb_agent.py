"""Agent service: FastAPI + Pydantic AI, querying KDB-X through the KDB-X MCP server."""

import asyncio
import json
import logging
import os
import time
from contextlib import asynccontextmanager

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, HTTPException  # noqa: E402
from pydantic import BaseModel  # noqa: E402
from pydantic_ai import Agent  # noqa: E402
from pydantic_ai.exceptions import ModelHTTPError  # noqa: E402
from pydantic_ai.mcp import MCPToolset  # noqa: E402
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart  # noqa: E402

AGENT_MODEL = os.getenv("AGENT_MODEL", "google:gemini-3.5-flash")
MCP_URL = os.getenv("MCP_URL", "http://127.0.0.1:8000/mcp")
SQL_TOOL = "kdbx_run_sql_query"
RETRY_DELAYS = (5, 10)  # seconds; free-tier Gemini often returns 429/503. Keep well under Tomcat's 90s timeout.

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("agent")

INSTRUCTIONS = """You answer questions about stock prices stored in a KDB-X database.
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
- Previous trading day (weekdays only): join b."date"=a."date"-1, UNION ALL a Monday join on b."date"=a."date"-3.
"""

FALLBACK_SCHEMA = """Table daily_prices (one row per weekday per ticker):
date (date), sym (symbol, e.g. T001..T100), name (company name), close (float), volume (long)."""

toolset = MCPToolset(MCP_URL)
agent = Agent(AGENT_MODEL, toolsets=[toolset], instructions=INSTRUCTIONS)
state: dict[str, str] = {"context": FALLBACK_SCHEMA}
sessions: dict[str, list[ModelMessage]] = {}


@agent.instructions
def db_context() -> str:
    return state["context"]


async def load_mcp_context() -> None:
    """Add the MCP server's schema and SQL guidance resources to the instructions."""
    parts = []
    for res in await toolset.list_resources():
        if res.name in ("kdbx_describe_tables", "kdbx_sql_query_guidance"):
            content = await toolset.read_resource(res.uri)
            parts.append(content if isinstance(content, str) else "\n".join(map(str, content)))
    if parts:
        state["context"] = "\n\n".join(parts)
    log.info("loaded MCP context: %d resources, %d chars", len(parts), len(state["context"]))


@asynccontextmanager
async def lifespan(_: FastAPI):
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
async def chat(req: ChatRequest) -> ChatResponse:
    start = time.perf_counter()
    for delay in (*RETRY_DELAYS, None):
        try:
            result = await agent.run(req.question, message_history=sessions.get(req.session_id))
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
    sessions[req.session_id] = result.all_messages()
    sql = sql_from(result.new_messages())
    duration_ms = int((time.perf_counter() - start) * 1000)
    usage = result.usage
    log.info(json.dumps({
        "session": req.session_id, "user": req.user_id, "question": req.question, "sql": sql,
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
