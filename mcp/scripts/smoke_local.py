"""Local smoke check of the FinAgent OS MCP read tools.

Runs against the LOCAL Supabase stack only. Settings come from
`.local/mcp.env` (written by scripts/local-setup.mjs). The script refuses any
SUPABASE_URL or N8N_INVOKE_WEBHOOK_URL whose host is not 127.0.0.1 or
localhost, builds the server exactly as production does (including the reader
role check), calls the six read tools and exits non-zero when any of them
does not return status 'ok'. It never calls invoke_reserve_recon.

Usage (repository root):  python mcp/scripts/smoke_local.py
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

MCP_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = MCP_DIR.parent
ENV_FILE = REPO_ROOT / ".local" / "mcp.env"
LOCAL_HOSTS = {"127.0.0.1", "localhost"}
# Placeholder only so the config loads; the smoke check never invokes.
PLACEHOLDER_WEBHOOK = "http://127.0.0.1:5678/webhook/fao-recon-invoke"

sys.path.insert(0, str(MCP_DIR))

READ_TOOLS = (
    ("get_process_owners", {}),
    ("get_agent_registry", {}),
    ("get_materiality_thresholds", {"asset_symbol": "BTC"}),
    ("get_pending_hitl", {}),
    ("get_recent_executions", {"limit": 3}),
    ("query_shadow_ledger", {"hours_lookback": 24, "limit": 5}),
)


def _is_local(url: str) -> bool:
    try:
        return urlsplit(url).hostname in LOCAL_HOSTS
    except ValueError:
        return False


def load_local_env() -> dict:
    from dotenv import dotenv_values

    if not ENV_FILE.is_file():
        raise SystemExit("smoke_local: .local/mcp.env not found; run npm run db:reset first.")
    env = {k: v for k, v in dotenv_values(ENV_FILE).items() if v is not None}
    if not _is_local(env.get("SUPABASE_URL", "")):
        raise SystemExit("smoke_local: refusing a SUPABASE_URL that is not 127.0.0.1 or localhost.")
    hook = env.get("N8N_INVOKE_WEBHOOK_URL")
    if hook and not _is_local(hook):
        raise SystemExit(
            "smoke_local: refusing an N8N_INVOKE_WEBHOOK_URL that is not 127.0.0.1 or localhost."
        )
    env.setdefault("N8N_INVOKE_WEBHOOK_URL", PLACEHOLDER_WEBHOOK)
    env.setdefault("N8N_INVOKE_KEY", "smoke-local-placeholder")
    # The invoke tool is never called here; drop invoker credentials.
    env.pop("FAO_INVOKER_EMAIL", None)
    env.pop("FAO_INVOKER_PASSWORD", None)
    return env


async def run() -> int:
    from fastmcp import Client

    import server
    from fao_auth import UserSession
    from fao_rest import InvokeClient, RestClient

    config = server.load_config(load_local_env())
    rest = RestClient(config.supabase_url, config.supabase_public_key)
    reader = UserSession(config.reader_email, config.reader_password, rest)
    invoke_client = InvokeClient(config.invoke_webhook_url, config.invoke_key)
    mcp = server.build_server(rest, reader, lambda: None, invoke_client)
    print("reader check passed (exactly one global reader role)")

    failures = 0
    async with Client(mcp) as client:
        names = sorted(t.name for t in await client.list_tools())
        print(f"tools: {', '.join(names)}")
        for name, args in READ_TOOLS:
            result = (await client.call_tool(name, args)).structured_content or {}
            ok = result.get("status") == "ok"
            failures += 0 if ok else 1
            summary = {k: result.get(k) for k in ("status", "count", "has_more", "kind", "http_status")}
            print(f"{'PASS' if ok else 'FAIL'}  {name}  {json.dumps(summary)}")
    print("smoke_local:", "PASS" if failures == 0 else f"FAIL ({failures})")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
