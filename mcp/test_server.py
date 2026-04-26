"""End-to-end smoke test of all seven FinAgent OS MCP tools."""
import asyncio
import json
from fastmcp import Client
from server import mcp


def pretty(label: str, result) -> None:
    print(f"\n{'=' * 70}")
    print(f"  {label}")
    print("=" * 70)
    print(json.dumps(result.data, indent=2, default=str)[:1500])


async def main():
    async with Client(mcp) as client:
        tools = await client.list_tools()
        print(f"Tools registered: {[t.name for t in tools]}")

        pretty("get_process_owners", await client.call_tool("get_process_owners", {}))
        pretty("get_agent_registry", await client.call_tool("get_agent_registry", {}))
        pretty("get_materiality_thresholds (BTC)",
               await client.call_tool("get_materiality_thresholds",
                                      {"asset_symbol": "BTC"}))
        pretty("get_pending_hitl", await client.call_tool("get_pending_hitl", {}))
        pretty("get_recent_executions (limit=3)",
               await client.call_tool("get_recent_executions", {"limit": 3}))
        pretty("query_shadow_ledger (last 24h, limit=5)",
               await client.call_tool("query_shadow_ledger",
                                      {"hours_lookback": 24, "limit": 5}))
        # Skipping invoke_reserve_recon in the smoke test to avoid actually
        # firing the flagship. Tested manually in Phase 4 if you want.


if __name__ == "__main__":
    asyncio.run(main())