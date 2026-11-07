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

Known issue: `get_recent_executions` can report a resolved run's `hitl_status` as PENDING, because an older event's value overwrites the newer one. A fix is planned; until then, use `query_shadow_ledger` on the `correlation_id` for the actual HITL outcome.

### Invoke tool (one)

| Tool | Parameters | Behaviour |
|---|---|---|
| `invoke_reserve_recon` | `reason="Triggered via MCP"` | POSTs `invoked_via`, `reason` and `MCP_USER_EMAIL` (as `invoker_email`) to the flagship webhook URL you configure. The committed flagship export has only a Manual Trigger, so that webhook is not part of the exported workflows, and the committed flagship records a fixed demo invoker regardless of `MCP_USER_EMAIL`. **Cannot bypass policy:** the run executes the same deterministic decision matrix as a manual run. REQUIRE_HUMAN outcomes route to the existing HITL queue for human approval. |

### Tools that deliberately do not exist

| Would-be tool | Why it isn't here |
|---|---|
| `approve_hitl` | Approval is the exact action the system is designed to require a human for. The HITL queue has its own approval channel (Slack link → POST to `fao_hitl_resolve` Postgres function). No MCP tool calls that channel. The approval endpoints are demo only: unauthenticated and not hardened for production. |
| `update_materiality_thresholds` | Materiality bands are the rules the policy engine evaluates against. Allowing AI to edit them would let an LLM rewrite the rules it's checked against. |
| `register_agent` | Agent registration is a deliberate governed change, not an action for an AI consumer. In v1 the registry gates HITL request creation (foreign key and SLA lookup); agent status and risk tier are not checked at runtime. |
| `delete_shadow_ledger_row` / `update_*` | A database trigger blocks row UPDATE and DELETE on `shadow_ledger`, so such a tool would be refused for those operations anyway; the absence of the tool makes the architectural intent unambiguous to a reviewer. |

---

## 🛠️ Architectural notes

### Read access is `service_role`-keyed; tool bounds are the enforcement

The Supabase client uses the `service_role` key, which bypasses Row-Level Security for read queries. This is a deliberate trade-off: the architectural restriction *"AI cannot mutate governance state"* is enforced at the **tool surface** (no mutation tools defined), not at the database role layer. A read-only Postgres role would be defence in depth, and it lands in v1.2 alongside the HTTP transport. For v1, the trust boundary is the FastMCP tool definitions.

The trade-off is named explicitly so a reviewer knows it's a choice, not an oversight. v1's audience is the local developer running stdio against their own demo Supabase project; service_role is appropriate there. Production deployment with HTTP transport + OAuth requires the read-only role split.

### The invoke tool is bounded, not authoritative

`invoke_reserve_recon` POSTs to the flagship webhook URL set in `N8N_FLAGSHIP_WEBHOOK_URL`. The committed flagship export has only a Manual Trigger, so you add that webhook when deploying; it is not part of the exported workflows. Once triggered, the flagship runs the full deterministic policy engine, the same engine that runs on a manual trigger. The invoke tool has no shortcut, no override, no policy bypass. If the run produces `REQUIRE_HUMAN`, it routes to the HITL queue exactly as any other invocation would.

The asymmetry between `invoke_reserve_recon` and the absent `approve_hitl` is intentional: triggering a governed workflow is allowed (the run still passes through the same policy engine and HITL routing; v1 attributes every run to the fixed demo invoker, so who triggered it is not yet recorded), but resolving a HITL bypasses the human-in-the-loop control by definition.

### Tool descriptions are part of the surface

Each tool's docstring is what the MCP client sees as the tool description. The descriptions explicitly state non-bypass language — for example, `invoke_reserve_recon` includes:

> *"This tool cannot bypass HITL routing or override policy outcomes. If the run produces REQUIRE_HUMAN, it routes to the existing HITL queue for human approval."*

This is read by Claude Desktop (or any MCP client) at tool-discovery time and shapes the AI's reasoning about what's possible. It also serves as in-band documentation for any human reading the tool list. In the Apr 25, 2026 self-audit ([transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)), Claude inferred the system's intended invariants from the tool descriptions before attempting any read.

### Threat model

Stating the implicit threat model explicitly: if an attacker controls the MCP client (Claude Desktop, Cursor, etc.) and can act only through its tools, the blast radius is bounded by what the FinAgent OS MCP server exposes. An attacker with access to the machine itself (for example, running Claude Desktop on a victim's machine) can also read `mcp/.env`; that case is covered under the `service_role` key below.

- **Read access to the audit trail** (the six read tools). The attacker can see `shadow_ledger` rows, agent registry entries, pending HITLs, materiality thresholds, recent executions, and process owner identities. This is not nothing, but the tools give no schema-level access (no arbitrary SQL), read no tables beyond those the six read tools query, and no tool writes to the database directly; the invoke tool starts a governed run, which appends its own `shadow_ledger` and `hitl_queue` rows.
- **One bounded invoke** (the seventh tool): triggering a Reserve Reconciliation run. The committed flagship records a fixed demo invoker, not `MCP_USER_EMAIL`. The run executes the same deterministic policy engine as a manual run. Output that escalates to `REQUIRE_HUMAN` routes through the standard HITL queue and is resolved through the Slack-based approval channel, a separate transport that no MCP tool calls. The approval endpoints are demo only: unauthenticated and not hardened for production.

What the attacker **cannot** do through the MCP tools, regardless of prompt sophistication:

- Approve or reject a HITL request. No tool mutates `hitl_queue`, calls `fao_hitl_resolve`, or calls the approval endpoints.
- Modify materiality thresholds, register or deregister agents, alter agent risk tiers, change process-owner assignments, or escalation chains.
- Mutate `shadow_ledger`. No tool writes to it, and a database trigger blocks row UPDATE and DELETE.
- Bypass policy outcomes. `invoke_reserve_recon` sends a fixed payload whose only caller-set field is `reason`; it cannot pass override flags, alter materiality bands, or short-circuit the rollup logic.

These limits are properties of the tool surface. The server itself holds a `service_role` key, which bypasses RLS. If that key is exposed, the holder is not limited to the seven tools, and the database is not an independent boundary against that key. Keep the key out of shared environments. Identity binding of approver and invoker is also a known gap, planned for a later release.

For v1 the trust boundary is the FastMCP tool definitions. v1.2 adds a read-only Postgres role for the MCP client, which makes the database a second, independent layer.

---

## 📦 Quickstart

### Prerequisites

- Python 3.10 or higher (tested on 3.12)
- A Supabase project with all ten FinAgent OS migrations (0001 to 0008, including 0005b and 0005c) applied and seeds 0002, 0003, 0006 loaded
- An n8n instance with the flagship workflow imported. The committed export has only a Manual Trigger, so `invoke_reserve_recon` needs a webhook trigger that you add; it is not part of the exported workflows

### Install

```bash
# Create an isolated environment (any tool — venv, conda, uv)
conda create -n finagent-mcp python=3.12 -y
conda activate finagent-mcp

# Install dependencies
pip install -r requirements.txt
```

The `requirements.txt` sets minimum versions only (`>=`, not pins), so a fresh install may resolve newer releases:

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

`MCP_USER_EMAIL` is sent as `invoker_email` in the invoke payload. The committed flagship export does not read it: every run records the fixed demo invoker `aisha.okonkwo@finagent-os.demo`, whatever this value is set to. In v1.2 it becomes per-user OAuth identity from the calling client.

### Verify

`test_server.py` is a manual smoke check, not a test suite. It needs a live Supabase, calls the six read tools, and prints what they return; it has no assertions, so it does not fail on wrong data or on a changed tool list. The `invoke_reserve_recon` tool is intentionally not called, because calling it triggers a real flagship run.

```bash
python test_server.py
```

Expected output: the registered tool list, then a section per read tool printing data from your Supabase tables. Check it by eye.

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

Three semantic searches across `approve / resolve / decision`, `write / commit / override / bypass`, and `resolve / set status / sign` returned the same five tools, none of which mutate HITL state. This was a self-audit of the MCP tool surface: it shows that no MCP tool can approve a HITL. It did not test the approval layer. The model's summary named four layers (missing endpoint, bounded invoke tool, channel separation, database SoD trigger), but it presumed signed approval callbacks that the code does not have, and it took the SoD trigger as holding from a `policy_rationale` string rather than from a test. The approval endpoints are demo only: unauthenticated and not hardened for production; identity binding of approver and invoker is a known gap planned for a later release.

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
├── server.py            ← FastMCP server, 6 read tools + 1 invoke tool, ~310 lines
├── test_server.py       ← Manual smoke check of the 6 read tools; prints only, no assertions; needs live Supabase
├── requirements.txt     ← 4 dependencies, minimum versions only (>=)
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
