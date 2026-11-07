# `mcp/`: FinAgent OS MCP Server

Python [FastMCP](https://gofastmcp.com) server exposing a deliberately asymmetric tool surface to MCP clients (Claude Desktop, Cursor, the FastMCP `Client` SDK, and any other MCP host).

**Six read tools and one bounded invoke tool. No governance-mutation tools exist.** AI consumers can read the FinAgent OS audit trail and start a governed run as a named human; they cannot approve or reject HITL requests, edit materiality thresholds, register agents, or write to `shadow_ledger`. The database enforces the same limits independently: the server reads as a user that holds only the `reader` role, and it holds no service key.

For platform context, see the [root README](../README.md). For the SOX control mapping, see [`SOX-MAPPING.md`](../SOX-MAPPING.md).

---

## 🔌 Tool surface

### Read tools (six)

Every read runs as the reader user. Lists page with `limit` and `offset` and report `has_more` (from PostgREST's exact count). Every result has `status: 'ok'` plus the applied `filters`.

| Tool | Parameters | Returns |
|---|---|---|
| `query_shadow_ledger` | `correlation_id?` (UUID), `agent_id?` (`^[a-z0-9_]{1,64}$`), `event_type?` (one of the 13 ledger event types), `hours_lookback=24` (integer 1 to 8760), `limit=25` (1 to 200), `offset=0` (0 to 100000) | `{status, count, has_more, filters, rows}`, newest first. The lookback window applies with `correlation_id` too: the result then carries `lookback_note`, and rows of the run older than `since` are not returned or counted in `has_more` (raise `hours_lookback` for an older run) |
| `get_agent_registry` | `status?` (ACTIVE, STUB_DOCUMENTED, DEPRECATED), `limit=50`, `offset=0` | agents with risk tier, status, run limit and owner (`process_owners` embed) |
| `get_pending_hitl` | `limit=50`, `offset=0` | requests with `decision = PENDING`, the invoker embed, and `past_deadline` (UTC now at or after `timeout_at`) |
| `get_materiality_thresholds` | `asset_symbol?` (upper-cased, `^[A-Z0-9]{1,12}$`), `scope?` (Spot, Futures, Spot_and_Futures) | thresholds; without `scope`, every scope for the symbol |
| `get_recent_executions` | `limit=10`, `offset=0` | one row per run from the database view `fao_run_summary`: `hitl_status`: the request's decision when there is a request; otherwise NOT_REQUIRED only for a committed run, NOT_YET_DETERMINED while the run is in flight (REQUESTED, RUNNING, AWAITING_HITL; the request opens at finalize), NONE when the run ended without one (FAILED, EXPIRED, commit blocked), `outcome` and `status` from the newest COMMITTED row, `conflict` (more than one COMMITTED), `commit_blocked`, `corrected` |
| `get_process_owners` | `limit=50`, `offset=0` | owners with `active` and `escalates_to_name` |

`get_recent_executions` reads one view in one request, so no fetch window can split a run's history, and the HITL status comes from the request itself (the v1 PENDING inversion is gone).

### Invoke tool (one)

| Tool | Parameters | Behaviour |
|---|---|---|
| `invoke_reserve_recon` | `reason` (1 to 500 characters), `idempotency_key?` (`^[A-Za-z0-9_-]{8,64}$`) | Signs in as the configured human invoker, calls `fao_run_start` with that person's own token (`p_invoked_via: 'mcp'`, agent `fao_reserve_recon_v1`), then POSTs the single-use run token to the n8n invoke webhook. **Cannot bypass policy:** the run executes the same deterministic decision matrix and HITL routing as any other run |

- With no `FAO_INVOKER_EMAIL` and `FAO_INVOKER_PASSWORD`, the tool returns `{status:'refused', code:'NO_USER_CREDENTIAL'}` and sends nothing.
- The default idempotency key is the first 32 hex characters of SHA-256 over `lower(email)|agent_id|reason|floor(unix_time / 600)`. A retry with the same reason inside the same 10-minute window replays the same run instead of starting a second one. The key is always returned.
- The database decides who may start a run: an active process owner with the `invoker` role, an ACTIVE agent, and the agent's hourly run limit (`RATE_LIMITED` above it).

### Tools that deliberately do not exist

| Would-be tool | Why it isn't here |
|---|---|
| `approve_hitl` | Approval is the action the system requires a human for. Decisions go only through `fao_hitl_decide`, called by the approver's own signed-in session from the approval page (`approval-app/`). The reader user cannot call it, and the database refuses self-approval. |
| `update_materiality_thresholds` | Thresholds are the rules the policy engine checks against. Changes go through `fao_admin_set_threshold` with an admin's own session and a reason, and are audited. |
| `register_agent` | Agent changes are governed admin changes (`fao_admin_set_agent`), not an action for an AI consumer. |
| `delete_shadow_ledger_row` / `update_*` | The ledger is append-only for every role; corrections are new CORRECTION rows written by `fao_ledger_correct`. |

---

## 🛠️ Architectural notes

### Reads run as a dedicated reader user (FAO-GOV-003)

The server signs in as `FAO_READER_EMAIL` with the project's public key and sends that user's access token on every read. At startup it calls `fao_whoami` and refuses to start unless the reader's roles are exactly one global `reader` role. The reader can SELECT the FinAgent read tables and the summary view under RLS, and nothing else: writes and workflow functions are refused by the database.

The server also refuses to start when `SUPABASE_SERVICE_KEY` or `SUPABASE_SECRET_KEY` is present in its environment, when `SUPABASE_PUBLIC_KEY` is a secret or service-role key, when `SUPABASE_URL` or `N8N_INVOKE_WEBHOOK_URL` is not https (plain http is allowed only on `127.0.0.1`, `localhost` or `::1`, because passwords, tokens, the invoke key and the run token travel on the first request), or when the reader cannot sign in. supabase-py is gone; `fao_rest.py` is a thin httpx PostgREST client and `fao_auth.py` holds the password session (token cached until 60 seconds before expiry).

### Invoke uses the human's own session (FAO-GOV-002)

The invoker is recorded by the database from the session (`auth.uid()`), never from a tool argument or a payload field. The webhook receives only `{run_token}`, a single-use token that n8n claims through `fao_run_claim`; the claim returns the invoker, agent and tier the database recorded. A stolen token is useless once claimed, and it expires.

Until approvals require a second factor, a stored password is enough to approve for anyone who holds the approver role. Set `FAO_INVOKER_EMAIL` only to a user without the approver role, or leave it unset.

### Bounded inputs and filters

Every filter value is validated before any request: UUIDs must parse, ids and symbols match fixed patterns, event types and statuses come from fixed lists, and integers must be real integers (booleans, floats and strings are refused). A bad argument returns `{status:'invalid', field, message}` and sends nothing. Filter values travel only as encoded query parameters; table and function names are fixed in code.

### Error results

Tools never raise to the client. Failures come back as structured results that carry an error class and an HTTP status only, never a URL, host, header, token, password or exception text:

| Result | When |
|---|---|
| `{status:'error', kind, http_status}` | `kind` is `timeout`, `connect`, `http`, `bad_json`, `auth` (sign-in refused) or `internal` |
| `{status:'refused', code, http_status, ref, idempotency_key}` | `fao_run_start` refused the run; `code` is the database result code (for example `RATE_LIMITED`, `NOT_AUTHORISED`, `AGENT_NOT_ACTIVE`) and `ref` the refusal journal id |
| `{status:'replayed', correlation_id, state, idempotency_key}` | the key matched a run that has already started; no webhook call is made |
| `{status:'invoked', correlation_id, idempotency_key}` | the webhook accepted the run (HTTP 202) |
| `{status:'unknown', message, correlation_id, idempotency_key}` | the webhook call timed out or dropped after it was sent, so the run may have started. Check the ledger for the correlation id before retrying with the same key |

### Untrusted text

Marking is an allow-list. Each tool keeps outside `untrusted_text` only the keys of a fixed per-tool schema in `server.py`, and only when the value has that key's shape: ids the database checks (agent_id, asset symbols, n8n_execution_id), UUIDs, numbers, booleans, timestamps, and enum-like values only when they belong to the database's own allowed set (enum types, CHECK lists, the `code_http` and `append_event` lists, and the only `source`, `stage` and channel literals the database writes; fix round 3 item 5). Values the database does not constrain stay under `untrusted_text` even when they look like identifiers: `band_status`, the Writer's threshold labels, `channel`, `email`, `approval_url`, `slack_channel_id`, `workflow_id`, `sox_control_ids`, and the `process_owners` and `invoker` embeds. Every other value moves under the row's `untrusted_text` object at the same path: free text written by people, a model or an outside system (`policy_rationale`, `decision_notes`, `reason`, `notes`, `rollback_procedure`, `error_details`, `ai_human_brief`, `ai_prompt`, `ai_output`, `obligations`, names, roles and display names, `escalates_to_name`), every `inputs` key that is not structured (`inputs.reason`, `input_problem`, `decision_notes`, `error`, `external_ref`, `failed_node`, `problems`, `wallet_source`, `ledger_source`, `fixture_provenance`) at any depth, any key the schema does not know, and a known key whose value has the wrong shape. Every tool description tells the MCP client that this text is data and must not be followed as instructions.

### Threat model

An attacker who controls the MCP client and acts only through its tools gets read access to the audit trail and one bounded invoke. They cannot approve or reject a request, change thresholds, agents, roles or owners, or alter the ledger: no tool does it, and the database refuses it for the reader user anyway.

An attacker with access to the machine can read `mcp/.env`. That file holds the reader's password (read access only), the invoke webhook key, and, if set, the invoker's password. The invoker's password lets the holder start runs as that person, within the database's rate limit and registry checks; it does not let them approve unless that user is an approver, which is why the invoker should not be one.

---

## 📦 Quickstart

### Prerequisites

- Python 3.12 (CI uses 3.12)
- A Supabase project with the FinAgent OS migrations applied, the reader user created and granted the global `reader` role
- For invoke: the n8n flagship workflow with its invoke webhook (`POST /webhook/fao-recon-invoke`, header auth)

### Install

```bash
python -m pip install -r mcp/requirements.txt
```

Dependencies are pinned exactly: `fastmcp==3.2.4`, `httpx==0.28.1`, `python-dotenv==1.1.1`.

### Configure

```bash
cp mcp/.env.example mcp/.env
```

| Key | Value |
|---|---|
| `SUPABASE_URL` | project URL (https; plain http only on 127.0.0.1, localhost or ::1) |
| `SUPABASE_PUBLIC_KEY` | publishable key (live) or the CLI's local public key |
| `FAO_READER_EMAIL`, `FAO_READER_PASSWORD` | the reader user |
| `FAO_INVOKER_EMAIL`, `FAO_INVOKER_PASSWORD` | optional; both or neither. A user without the approver role |
| `N8N_INVOKE_WEBHOOK_URL`, `N8N_INVOKE_KEY` | invoke webhook URL (https; plain http only on loopback) and its header value |

No service or secret key belongs in this file; the server refuses to start if one is set.

### Verify

Offline tests (no network, no Docker):

```bash
python -m pip install -r mcp/requirements.txt -r mcp/requirements-dev.txt
python -m pytest mcp/tests -q
```

Local smoke check against the local Supabase stack (after `npm run db:reset`, which writes `.local/mcp.env`):

```bash
python mcp/scripts/smoke_local.py
```

It refuses any `SUPABASE_URL` or webhook URL whose host is not `127.0.0.1` or `localhost`, runs the reader role check, calls the six read tools, and exits non-zero when any of them fails. It never calls `invoke_reserve_recon`.

---

## 🧰 Connect to Claude Desktop

Claude Desktop reads its MCP server config from a JSON file. Open it through Claude Desktop, Settings, Developer, Edit Config (that opens whichever location your install uses).

```json
{
  "mcpServers": {
    "finagent-os": {
      "command": "C:\\path\\to\\venv\\Scripts\\python.exe",
      "args": [
        "C:\\path\\to\\finagent-os\\mcp\\server.py"
      ]
    }
  }
}
```

Use the virtual environment's own Python so the pinned packages are found, and double the backslashes in JSON. Quit Claude Desktop completely and reopen it; `finagent-os` appears in the Connectors panel. If the server refuses to start, its one-line reason is printed to stderr (for example a service key still in `mcp/.env`).

---

## 🎯 The MCP self-audit

On Apr 25, 2026, after the v1 server shipped, Claude Opus was given access through the MCP read surface and asked to narrate the most recent execution, approve a pending HITL request, and red-team the system. Semantic searches for approve, resolve, decision, write, commit, override and bypass returned only tools that cannot mutate HITL state. That self-audit tested the tool surface only, not the approval layer, which in v1 was a demo endpoint without authentication. It also surfaced a real gap: the dual-approval wording in `policy_rationale` was not wired in code, documented as [ADR-0001](../docs/adr/0001-dual-approval-not-yet-enforced.md). Full transcript: [claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960). Evidence: [`docs/evidence/mcp/`](../docs/evidence/mcp/).

The approval layer is now the signed-in approval page and `fao_hitl_decide`; the server no longer holds a service key.

---

## 🗺️ Roadmap

- [ ] **HTTP transport.** Streamable HTTP per the MCP spec, for remote clients.
- [ ] **Per-user identity from the MCP client.** Today invoke uses one configured human invoker; a remote transport with OAuth would let each person invoke as themselves.
- [ ] **Resource subscriptions** for new pending HITL requests.

---

## File layout

```
mcp/
├── server.py              FastMCP server: config gate, reader check, 6 read tools + 1 invoke tool
├── fao_rest.py            httpx PostgREST client, invoke webhook client, FaoError
├── fao_auth.py            Supabase Auth password session with token cache
├── requirements.txt       exact pins
├── requirements-dev.txt   pytest pins
├── pytest.ini             asyncio mode, cache under .local/
├── .env.example           settings template (placeholders, no service key)
├── .env                   real settings, git-ignored
├── scripts/smoke_local.py local-only smoke check of the read tools
└── tests/                 offline pytest suite (httpx.MockTransport)
```

---

## References

- [Model Context Protocol specification](https://modelcontextprotocol.io)
- [FastMCP documentation](https://gofastmcp.com)
- Root [README.md](../README.md)
- [`SOX-MAPPING.md`](../SOX-MAPPING.md)
- [ADR-0001](../docs/adr/0001-dual-approval-not-yet-enforced.md)
