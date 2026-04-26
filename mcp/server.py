"""
FinAgent OS — MCP Server

Exposes governance observability and agent invocation over MCP.

Architectural principle: The MCP server provides READ access to audit state
and INVOCATION of governed agents. It deliberately does NOT expose mutation
of governance state — HITL approvals, materiality threshold edits, and
agent registration are not tools. AI is observer and trigger; humans (via
the existing HITL gateway) decide.

Author: Rizwan Ahmed, ACCA · Velocyt Consulting
"""
from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx
from pathlib import Path
from dotenv import load_dotenv
from fastmcp import FastMCP
from supabase import create_client, Client

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
load_dotenv(dotenv_path=Path(__file__).parent / ".env")

SUPABASE_URL: str = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_KEY: str = os.environ["SUPABASE_SERVICE_KEY"]
N8N_FLAGSHIP_WEBHOOK_URL: str = os.environ["N8N_FLAGSHIP_WEBHOOK_URL"]
MCP_USER_EMAIL: str = os.environ.get(
    "MCP_USER_EMAIL", "aisha.okonkwo@finagent-os.demo"
)

supabase: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)

# ---------------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------------
mcp = FastMCP("FinAgent OS")


# ---------------------------------------------------------------------------
# Tool 1 — query_shadow_ledger
# ---------------------------------------------------------------------------
@mcp.tool
def query_shadow_ledger(
    correlation_id: Optional[str] = None,
    agent_id: Optional[str] = None,
    event_type: Optional[str] = None,
    hours_lookback: Optional[int] = None,
    limit: int = 25,
) -> dict:
    """
    Query the FinAgent OS Shadow Ledger — the immutable audit trail of every
    agent execution. All filters are optional and combine with AND.

    Args:
        correlation_id: UUID of a specific execution (returns all rows for
            that execution — typically 9 to 11 rows for a HITL-gated run).
        agent_id: e.g. 'fao_reserve_recon_v1'. Returns rows for that agent only.
        event_type: One of STARTED, ASSET_RECONCILED, COMMITTED,
            HITL_REQUESTED, HITL_RESOLVED. Filters on inputs->>'event_type'.
        hours_lookback: Restrict to rows from the last N hours.
        limit: Max rows to return (default 25, hard cap 200).

    Returns: Dict with row count, applied filters, and the matching ledger rows.
    """
    limit = min(max(limit, 1), 200)
    q = supabase.table("shadow_ledger").select("*")

    if correlation_id:
        q = q.eq("correlation_id", correlation_id)
    if agent_id:
        q = q.eq("agent_id", agent_id)
    if event_type:
        # event_type lives inside inputs JSONB, not as a top-level column
        q = q.eq("inputs->>event_type", event_type)
    if hours_lookback is not None and hours_lookback > 0:
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours_lookback)).isoformat()
        q = q.gte("event_timestamp", cutoff)

    res = q.order("event_timestamp", desc=True).limit(limit).execute()
    return {
        "count": len(res.data),
        "filters": {
            "correlation_id": correlation_id,
            "agent_id": agent_id,
            "event_type": event_type,
            "hours_lookback": hours_lookback,
            "limit": limit,
        },
        "rows": res.data,
    }


# ---------------------------------------------------------------------------
# Tool 2 — get_agent_registry
# ---------------------------------------------------------------------------
@mcp.tool
def get_agent_registry(status: Optional[str] = None) -> dict:
    """
    List all agents registered in FinAgent OS, with their risk tier, operating
    status, control IDs implemented, and named process owner.

    Args:
        status: Optional filter — ACTIVE, STUB_DOCUMENTED, or DEPRECATED.

    Returns: Dict with row count and the agent rows joined to process_owners.
    """
    q = supabase.table("agent_registry").select(
        "agent_id, display_name, risk_tier, status, workflow_id, "
        "approval_threshold, sox_control_ids, ai_advisory_enabled, "
        "process_owner_id, process_owners(name, role, email)"
    )
    if status:
        q = q.eq("status", status)
    res = q.order("agent_id").execute()
    return {"count": len(res.data), "agents": res.data}


# ---------------------------------------------------------------------------
# Tool 3 — get_pending_hitl
# ---------------------------------------------------------------------------
@mcp.tool
def get_pending_hitl() -> dict:
    """
    List all HITL queue items currently awaiting human approval. Each row
    includes the agent that produced the REQUIRE_HUMAN outcome, the
    invoker's identity, the policy rationale, and the SLA timeout.

    Returns: Dict with row count and the pending HITL rows.
    """
    res = (
        supabase.table("hitl_queue")
        .select(
            "hitl_id, correlation_id, agent_id, agent_invoker_id, "
            "created_at, risk_tier, sub_tier, policy_rationale, "
            "ai_human_brief, timeout_at, "
            "process_owners!hitl_queue_agent_invoker_id_fkey(name, role, email)"
        )
        .eq("decision", "PENDING")
        .order("created_at", desc=True)
        .execute()
    )
    return {"count": len(res.data), "pending": res.data}


# ---------------------------------------------------------------------------
# Tool 4 — get_materiality_thresholds
# ---------------------------------------------------------------------------
@mcp.tool
def get_materiality_thresholds(
    asset_symbol: Optional[str] = None,
    scope: Optional[str] = None,
) -> dict:
    """
    Return per-asset materiality thresholds and expected reserve ratio bands
    used by the Reserve Reconciliation Agent.

    Args:
        asset_symbol: e.g. 'BTC'. Returns one row.
        scope: 'Spot', 'Futures', or 'Spot_and_Futures'. Filters by scope.

    Returns: Dict with row count and the threshold rows.
    """
    q = supabase.table("materiality_thresholds").select("*")
    if asset_symbol:
        q = q.eq("asset_symbol", asset_symbol.upper())
    if scope:
        q = q.eq("scope", scope)
    res = q.order("asset_symbol").execute()
    return {"count": len(res.data), "thresholds": res.data}


# ---------------------------------------------------------------------------
# Tool 5 — get_recent_executions
# ---------------------------------------------------------------------------
@mcp.tool
def get_recent_executions(limit: int = 10) -> dict:
    """
    List the most recent agent executions, one row per correlation_id, with
    the rollup execution outcome (from the COMMITTED row when present).

    Args:
        limit: Number of distinct executions to return (default 10, max 50).

    Returns: Dict with summarized executions.
    """
    limit = min(max(limit, 1), 50)
    # Pull a window of recent ledger rows, then collapse to one entry per
    # correlation_id in Python. Faster than a CTE for this size, and easier
    # to read than the supabase-py group_by syntax.
    res = (
        supabase.table("shadow_ledger")
        .select(
            "correlation_id, agent_id, event_timestamp, risk_tier, "
            "policy_outcome, hitl_status, status, inputs"
        )
        .order("event_timestamp", desc=True)
        .limit(limit * 12)  # ~11 rows per HITL-gated run, headroom for filtering
        .execute()
    )

    by_correlation: dict[str, dict] = {}
    for row in res.data:
        cid = row["correlation_id"]
        evt = (row.get("inputs") or {}).get("event_type")
        if cid not in by_correlation:
            by_correlation[cid] = {
                "correlation_id": cid,
                "agent_id": row["agent_id"],
                "risk_tier": row["risk_tier"],
                "started_at": row["event_timestamp"],
                "latest_event_at": row["event_timestamp"],
                "rollup_outcome": None,
                "rollup_status": None,
                "hitl_status": "NOT_REQUIRED",
                "event_count": 0,
            }
        entry = by_correlation[cid]
        entry["event_count"] += 1
        if row["event_timestamp"] < entry["started_at"]:
            entry["started_at"] = row["event_timestamp"]
        if row["event_timestamp"] > entry["latest_event_at"]:
            entry["latest_event_at"] = row["event_timestamp"]
        if evt == "COMMITTED":
            entry["rollup_outcome"] = row["policy_outcome"]
            entry["rollup_status"] = row["status"]
        if row["hitl_status"] != "NOT_REQUIRED":
            entry["hitl_status"] = row["hitl_status"]

    executions = sorted(
        by_correlation.values(),
        key=lambda e: e["latest_event_at"],
        reverse=True,
    )[:limit]
    return {"count": len(executions), "executions": executions}


# ---------------------------------------------------------------------------
# Tool 6 — get_process_owners
# ---------------------------------------------------------------------------
@mcp.tool
def get_process_owners() -> dict:
    """
    List all named process owners and the escalation chain. Each row shows
    the owner's role and who they escalate to (NULL = top of the chain).

    Returns: Dict with row count and the process owner rows.
    """
    res = (
        supabase.table("process_owners")
        .select("id, name, role, email, escalation_to")
        .order("name")
        .execute()
    )
    # Resolve escalation_to UUIDs to names for readability
    by_id = {p["id"]: p["name"] for p in res.data}
    for p in res.data:
        p["escalates_to_name"] = by_id.get(p["escalation_to"])
    return {"count": len(res.data), "owners": res.data}


# ---------------------------------------------------------------------------
# Tool 7 — invoke_reserve_recon
# ---------------------------------------------------------------------------
@mcp.tool
def invoke_reserve_recon(reason: str = "Triggered via MCP") -> dict:
    """
    Trigger the Reserve Reconciliation Agent flagship workflow. The flagship
    runs the full deterministic policy engine — this tool cannot bypass HITL
    routing or override policy outcomes. If the run produces REQUIRE_HUMAN,
    it routes to the existing HITL queue for human approval.

    Args:
        reason: Free-text rationale logged with the invocation.

    Returns: Dict with the flagship's response payload, or an error.
    """
    payload = {
        "invoked_via": "mcp",
        "invoker_email": MCP_USER_EMAIL,
        "reason": reason,
    }
    try:
        with httpx.Client(timeout=60.0) as client:
            r = client.post(N8N_FLAGSHIP_WEBHOOK_URL, json=payload)
            r.raise_for_status()
            return {
                "status": "invoked",
                "http_status": r.status_code,
                "flagship_response": r.json() if r.text else None,
            }
    except httpx.HTTPError as exc:
        return {
            "status": "error",
            "error": str(exc),
            "note": (
                "Flagship invocation failed. The MCP server cannot retry — "
                "deterministic invocation must remain a single audited event."
            ),
        }


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    mcp.run()