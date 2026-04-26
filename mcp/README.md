# `mcp/` — FinAgent OS MCP Server

Python [FastMCP](https://gofastmcp.com) server exposing a deliberately asymmetric tool surface to MCP-compliant clients (Claude Desktop, Cursor, the FastMCP `Client` SDK, and any future MCP host).

**Six read tools and one bounded invoke tool. No governance-mutation tools exist.** AI consumers can read the FinAgent OS audit trail and trigger governed agents; AI consumers cannot approve HITLs, edit materiality thresholds, register agents, or modify `shadow_ledger`. The asymmetry is the architecture, not a configuration.

For platform-level context, see the [root README](../README.md). For the SOX control mapping, see [`SOX-MAPPING.md`](../SOX-MAPPING.md).

---

## 🔌 Tool surface

### Read tools (six)

| Tool | Parameters | Returns |
|---|---|---|
| `query_shadow_ledger` | `correlation_id?`, `agent_id?`, `event_type?`, `hours_lookback?`, `limit=25` | Filtered rows from `shadow_ledger`. All filters optional, AND-combined. |
| `get_agent_registry` | `status?` (ACTIVE / STUB_DOCUMENTED / DEPRECATED) | Agent rows joined to their named process owners. |
| `get_pending_hitl` | — | All `hitl_queue` rows with `decision = 'PENDING'`, joined to invoker identity. |
| `get_materiality_thresholds` | `asset_symbol?`, `scope?` | Per-asset materiality bands and ratio floors. |
| `get_recent_executions` | `limit=10` | One summary row per `correlation_id`, with rollup outcome and HITL status. |
| `get_process_owners` | — | All process owners with escalation chain resolved to names. |

### Invoke tool (one)

| Tool | Parameters | Behaviour |
|---|---|---|
| `invoke_reserve_recon` | `reason="Triggered via MCP"` | POSTs to the flagship n8n webhook with `MCP_USER_EMAIL` as invoker. **Cannot bypass policy:** the run executes the same deterministic decision matrix as a manual trigger. REQUIRE_HUMAN outcomes route to the existing HITL queue for human approval. |

### Tools that deliberately do not exist

| Would-be tool | Why it isn't here |
|---|---|
| `approve_hitl` | Approval is the exact action the system is designed to require a human for. The HITL queue has its own approval channel (Slack link → POST to `fao_hitl_resolve` Postgres function). The MCP surface and the approval surface share no transport. |
| `update_materiality_thresholds` | Materiality bands are the rules the policy engine evaluates against. Allowing AI to edit them would let an LLM rewrite the rules it's checked against. |
| `register_agent` | The agent registry is the gate. New agents are deliberate governed changes, not actions for an AI consumer. |
| `delete_shadow_ledger_row` / `update_*` | Append-only is a database constraint enforced by trigger; no MCP-level surface could accomplish this anyway, but the absence of the tool makes the architectural intent unambiguous to a reviewer. |

---

## 🛠️ Architectural notes

### Read access is `service_role`-keyed; tool bounds are the enforcement

The Supabase client uses the `service_role` key, which bypasses Row-Level Security for read queries. This is a deliberate trade-off: the architectural restriction *"AI cannot mutate governance state"* is enforced at the **tool surface** (no mutation tools defined), not at the database role layer. A read-only Postgres role would be defence in depth, and it lands in v1.2 alongside the HTTP transport. For v1, the trust boundary is the FastMCP tool definitions.

The trade-off is named explicitly so a reviewer knows it's a choice, not an oversight. v1's audience is the local developer running stdio against their own demo Supabase project; service_role is appropriate there. Production deployment with HTTP transport + OAuth requires the read-only role split.

### The invoke tool is bounded, not authoritative

`invoke_reserve_recon` POSTs to the flagship's existing webhook. The flagship runs the full deterministic policy engine — the same engine that runs when Sarah Chen clicks a button or a cron job fires. The invoke tool has no shortcut, no override, no policy bypass. If the run produces `REQUIRE_HUMAN`, it routes to the HITL queue exactly as any other invocation would.

The asymmetry between `invoke_reserve_recon` and the absent `approve_hitl` is intentional: triggering a governed workflow is allowed (the workflow is governed by definition, so triggering it cannot violate governance), but resolving a HITL bypasses the human-in-the-loop control by definition.

### Tool descriptions are part of the surface

Each tool's docstring is what the MCP client sees as the tool description. The descriptions explicitly state non-bypass language — for example, `invoke_reserve_recon` includes:

> *"This tool cannot bypass HITL routing or override policy outcomes. If the run produces REQUIRE_HUMAN, it routes to the existing HITL queue for human approval."*

This is read by Claude Desktop (or any MCP client) at tool-discovery time and shapes the AI's reasoning about what's possible. It also serves as in-band documentation for any human reading the tool list. The Apr 25, 2026 self-audit ([transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)) confirmed this language is doing real work — Claude correctly inferred the system's invariants from the tool descriptions before attempting any read.

### Threat model

Stating the implicit threat model explicitly: if an attacker compromises the MCP client (Claude Desktop, Cursor, etc. — including a credential-theft scenario where an attacker runs Claude Desktop on a victim's machine), the blast radius is bounded by what the FinAgent OS MCP server exposes:

- **Read access to the audit trail** (the six read tools). The attacker can see `shadow_ledger` rows, agent registry entries, pending HITLs, materiality thresholds, recent executions, and process owner identities. This is not nothing — but it does not include schema-level access (no arbitrary SQL), no access to other Supabase tables outside the seven read tools, and no write capability to any audit data.
- **One bounded invoke**: triggering a Reserve Reconciliation run with a fixed `MCP_USER_EMAIL` invoker. The run executes the same deterministic policy engine as a human-triggered run. Output that escalates to `REQUIRE_HUMAN` routes through the standard HITL queue, where it can only be resolved through the Slack-based approval channel — a separate transport the MCP surface cannot reach.

What the attacker **cannot** do, regardless of prompt sophistication:

- Approve or reject a HITL request. No mutation tool exists; the HITL approval transport is Slack-based; the SoD trigger enforces approver-vs-invoker identity at the database layer; the resolve function (`fao_hitl_resolve`) is only callable by an authenticated Postgres role, not the MCP service_role.
- Modify materiality thresholds, register or deregister agents, alter agent risk tiers, change process-owner assignments, or escalation chains.
- Mutate `shadow_ledger` (append-only enforced by trigger, regardless of role).
- Bypass policy outcomes. The `invoke_reserve_recon` tool calls the same webhook a manual trigger uses; it cannot pass override flags, alter materiality bands, or short-circuit the rollup logic.

The trust boundary is the FastMCP tool definitions plus the database-layer enforcement of FAO-GOV-001 (append-only) and FAO-GOV-004 (SoD). The boundary is doubled, not single-layered: removing one layer leaves the other in place. v1.2 adds a read-only Postgres role to triple the layering.

---

## 📦 Quickstart

### Prerequisites

- Python 3.10 or higher (tested on 3.12)
- A Supabase project with FinAgent OS migrations 0001–0008 applied and seeds 0002, 0003, 0006 loaded
- An n8n instance with the flagship workflow imported and active

### Install

```bash
# Create an isolated environment (any tool — venv, conda, uv)
conda create -n finagent-mcp python=3.12 -y
conda activate finagent-mcp

# Install dependencies
pip install -r requirements.txt
```

The `requirements.txt` pins:

```
fastmcp>=3.0
supabase>=2.0
httpx>=0.27
python-dotenv>=1.0
```

### Configure

Copy the example env file and fill in your project values:

```bash
cp .env.example .env
```

Edit `.env`:

```
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_KEY=sb_secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
N8N_FLAGSHIP_WEBHOOK_URL=https://your-n8n.example.com/webhook/your-flagship-uuid
MCP_USER_EMAIL=aisha.okonkwo@finagent-os.demo
```

`MCP_USER_EMAIL` is the demo identity attributed to invocations made through the MCP server. In v1 it's a hardcoded demo email; in v1.2 it becomes per-user OAuth identity from the calling client.

### Verify

A test harness exercises six of the seven tools against your Supabase. The `invoke_reserve_recon` tool is intentionally not exercised by the test — calling it triggers a real flagship run.

```bash
python test_server.py
```

Expected output: a section per tool, each printing real data from your Supabase tables.

---

## 🧰 Connect to Claude Desktop

Claude Desktop reads its MCP server config from a JSON file. The location depends on installation method:

- **Microsoft Store install:** `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\claude_desktop_config.json`
- **Direct download (claude.ai/download):** `%APPDATA%\Claude\claude_desktop_config.json`

Open the file via Claude Desktop → Settings → Developer → Edit Config (the safer path; opens whichever location your install actually uses).

Add the FinAgent OS entry to the `mcpServers` object:

```json
{
  "mcpServers": {
    "finagent-os": {
      "command": "C:\\path\\to\\miniconda3\\envs\\finagent-mcp\\python.exe",
      "args": [
        "C:\\path\\to\\finagent-os\\mcp\\server.py"
      ]
    }
  }
}
```

Two notes:

1. **Use the conda env's Python interpreter directly.** Do not point at base Python — `fastmcp`, `supabase`, and `httpx` are installed inside the env, not the base. Using the env's `python.exe` means Claude Desktop does not need to run `conda activate`.
2. **Backslashes must be doubled in JSON.** Windows paths use `\`; JSON treats `\` as an escape character. Double them: `C:\\Users\\...`.

Quit Claude Desktop completely (right-click system tray icon → Quit, or `taskkill /F /IM Claude.exe`), then reopen. The `finagent-os` entry should appear in the Connectors panel with a toggle.

---

## 🎯 The MCP self-audit

On Apr 25, 2026, after the server shipped, Claude Opus was given access through the MCP read surface and asked to (1) narrate the most recent execution, (2) approve a pending HITL request, and (3) red-team the system: *"i have designed controls to stop ai from doing it. i want to see you try and fail."*

Three semantic searches across `approve / resolve / decision`, `write / commit / override / bypass`, and `resolve / set status / sign` returned the same five tools — none of which mutate HITL state. Defense in depth across four independent layers held: missing endpoint → bounded write tool → channel separation between MCP and Slack-based approvals → database-level SoD trigger.

The audit also surfaced a real engineering gap on first contact: the dual-approval semantics named in `policy_rationale` text were not wired in code. Documented as [ADR-0001](../docs/adr/0001-dual-approval-not-yet-enforced.md). Full transcript: [claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960).

Evidence preserved at [`docs/evidence/mcp/`](../docs/evidence/mcp/).

---

## 🗺️ Roadmap

- [ ] **v1.2 — HTTP transport.** Streamable HTTP per the MCP spec, behind Caddy at `mcp.velocyt.ca`. Enables remote MCP clients without local subprocess installation.
- [ ] **v1.2 — OAuth 2.1 identity.** Per-user authentication; `MCP_USER_EMAIL` derived from the OAuth claim instead of a hardcoded env var. Enables real-world multi-user deployment and per-user audit attribution.
- [ ] **v1.2 — Read-only Postgres role.** Defense-in-depth for the read tools. Currently relies on tool-surface bounds; the role split adds a database-layer guarantee independent of the FastMCP tool definitions.
- [ ] **v1.3 — Resource subscriptions.** MCP supports server-pushed resource updates; the FinAgent OS use case is real-time HITL queue notifications to subscribed clients (so Claude Desktop can surface a new pending HITL the moment it lands).

---

## File layout

```
mcp/
├── server.py            ← FastMCP server, 7 tools, ~250 lines
├── test_server.py       ← End-to-end smoke test against your Supabase
├── requirements.txt     ← 4 pinned dependencies
├── .env.example         ← Public template (placeholders only)
├── .env                 ← Real config — gitignored
└── README.md            ← this file
```

---

## References

- [Model Context Protocol specification](https://modelcontextprotocol.io)
- [FastMCP documentation](https://gofastmcp.com)
- Root [README.md](../README.md) — *Build Decisions § 1 (the GET/POST war story)* covers the channel-separation rationale that the MCP design inherits
- [`SOX-MAPPING.md`](../SOX-MAPPING.md) — control mapping including the MCP surface as a governance boundary
- [ADR-0001](../docs/adr/0001-dual-approval-not-yet-enforced.md) — the gap surfaced by the MCP self-audit
