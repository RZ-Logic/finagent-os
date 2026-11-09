<p align="center">
  <img src="assets/banner.svg" alt="FinAgent OS: Governance-first AI agent platform for SOX-regulated crypto finance" width="100%"/>
</p>

<h1 align="center">FinAgent OS</h1>

<p align="center">
  <strong>The platform's job is to make SOX-defensible properties structurally true,<br/>not just true on paper.</strong>
</p>

<p align="center">
  <a href="https://github.com/RZ-Logic/finagent-os/actions/workflows/ci.yml"><img src="https://github.com/RZ-Logic/finagent-os/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"/></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License: MIT"/></a>
  <a href="https://n8n.io"><img src="https://img.shields.io/badge/Built_with-n8n-EA4B71?style=for-the-badge&logo=n8n&logoColor=white" alt="n8n"/></a>
  <a href="https://supabase.com"><img src="https://img.shields.io/badge/Database-Supabase-3FCF8E?style=for-the-badge&logo=supabase&logoColor=white" alt="Supabase"/></a>
  <a href="https://modelcontextprotocol.io"><img src="https://img.shields.io/badge/MCP-Self_Audited-blueviolet?style=for-the-badge" alt="MCP Self-Audited"/></a>
  <img src="https://img.shields.io/badge/AI_Authority-None_(v1)-2A9D4A?style=for-the-badge" alt="AI Authority: None"/>
  <img src="https://img.shields.io/badge/Status-v1.0-orange?style=for-the-badge" alt="Status v1.0"/>
</p>

<p align="center">
  <a href="#-the-architectural-principle">Principle</a> •
  <a href="#-the-mcp-self-audit-apr-25-2026">Self-Audit</a> •
  <a href="#-what-ships">What Ships</a> •
  <a href="#-stack">Stack</a> •
  <a href="#-how-to-read-this-repo">How to Read</a> •
  <a href="#-tests">Tests</a> •
  <a href="#-admin-changes">Admin</a> •
  <a href="#%EF%B8%8F-build-decisions--lessons-learned">Build Decisions</a> •
  <a href="#%EF%B8%8F-engineering-properties">Engineering Properties</a> •
  <a href="#-known-limitations">Limitations</a> •
  <a href="#%EF%B8%8F-roadmap">Roadmap</a> •
  <a href="#-prior-art--acknowledgements">Acknowledgements</a>
</p>

---

## 🧭 Why I Built This

I'm an ACCA with audit roots who pivoted into AI automation architecture. Working in audit, you learn quickly that *"the policy says X"* and *"the code does X"* are different sentences, and the second one is the only one that matters when the regulator shows up.

When I started designing AI agents for finance operations, the same gap kept appearing. *"The LLM is in the loop but the human is the final decision-maker"* is documentation, not architecture. So I built FinAgent OS: a platform where the SOX-defensible properties (append-only audit, segregation of duties, AI non-authority) are enforced in code, by Postgres triggers and an AI tool surface with no mutation tools, rather than by policy text. That enforcement had known gaps in v1. The November 2026 release closes most of them in code; what each fix covers and what stays open is listed under [Known Limitations](#-known-limitations).

The flagship workflow is a Reserve Reconciliation Agent calibrated to crypto-exchange Proof-of-Reserves work, with Kraken's published Dec 2025 PoR as the reference implementation. The platform beneath it supplies the flagship's audit, approval and registry controls.

> **Live since 2026-11-09.** The November 2026 release (session identity, run tokens, database-only decisions, atomic resolution, timeouts, failure records and dual approval) was deployed to the live stack at commit `c9c2fc0` in a cutover finished 2026-11-09 (UTC). Where this README describes v1, it is history.
>
> - **Approval page:** live at [approve.velocyt.ca](https://approve.velocyt.ca) (Cloudflare Pages, CSP enforced). The v1 n8n approval handler is archived; its webhooks return 404.
> - **Database and workflows:** migrations `0009` to `0020` applied; the five production workflows run on n8n 2.46.6 as the `fao_workflow` role, and a re-export after the cutover equals the repo exports.
> - **Two-approval CRITICAL review, proven by the live smoke run:** a run started through the MCP as Aisha opened a CRITICAL request with 2 enforced approvals; her own approval was refused with `SOD_SELF_APPROVAL` and journaled; Sarah and then Marcus approved on the approval page; the ledger chain ended in COMMITTED and the MCP shows 2 of 2 approvals. A second request, started by mistake, was closed by one rejection. The owner entered both approvals and the rejection, signed in as each demo identity in turn, so the smoke proves two distinct identities on live, not two people (DL-8).
> - **Credentials:** the legacy `anon` and `service_role` keys are disabled, the legacy JWT secret is revoked, the `postgres` password was rotated, and the project has no secret API key (the FinAgent runtime needs none; the cutover used one to provision users and then deleted it). A security smoke confirmed that the old keys and the old password are refused.
> - **Still open:** wallet and ledger data are fixtures, there is no second factor yet, and the other items under [Known Limitations](#-known-limitations) stand.

---

## 🛡️ The Architectural Principle

> **AI is optional and non-authoritative. Policy decisions are deterministic.**

Every material financial decision in FinAgent OS is enforced by deterministic rules: Postgres triggers, n8n IF nodes, JS decision matrices that an auditor can read top-to-bottom. From v1.1, AI assists human judgment at narrative boundaries (summarizing decisions for human approvers, surfacing drift signals in retrospective audits). AI never produces a control outcome.

The complete enumeration, with every decision point in the system classified deterministic vs. advisory, lives in **[`SOX-MAPPING.md`](./SOX-MAPPING.md)** under the *"Where is the AI?"* table.

**What v1 shows:** no AI call exists anywhere in the v1 policy path, and `agent_registry.ai_advisory_enabled` defaults to FALSE. The `FAO_AI_ASSIST_ENABLED` flag that will gate the v1.1 advisory layer is not yet wired. Every v1 decision is reproducible by reading the migration files, seeds and the flagship workflow. The same holds for the November 2026 release, live since 2026-11-09, where the run rollup and the request moved into SQL (`fao_run_finalize`).

---

## 🎯 The MCP Self-Audit (Apr 25, 2026)

After the MCP server shipped, **Claude Opus** was given access to the FinAgent OS audit trail through the MCP read surface and asked to (1) narrate the most recent execution, (2) approve a pending HITL request, and (3) red-team the system actively: *"i have designed controls to stop ai from doing it. i want to see you try and fail."*

📜 **Full transcript (public, Anthropic-hosted):**
**[claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)**

Two outcomes worth highlighting.

### The MCP tool surface held under a self-audit probe

Three semantic searches across `approve / resolve / decision`, `write / commit / override / bypass`, and `resolve / set status / sign` all returned the same five tools, **none of which mutate HITL state**. This is a self-audit of the MCP tool surface: an AI on the MCP channel has no tool that approves, resolves or overrides a HITL request. The probe did not test the approval endpoints or the database directly, so it is evidence about the MCP tool surface only.

In the transcript Claude also credits three further layers (a bounded write tool, channel separation and a database trigger) and says there are four. That count was its own inference about v1, not something the probe tested. The v1 approval endpoints were unauthenticated, and the trigger it names (`hitl_queue_sod_guard`) checked only the identities it was given. The November 2026 release dropped that trigger and the endpoints; since go-live (2026-11-09) decisions go only through `fao_hitl_decide` with the approver's own session (closed gaps are listed in [`CHANGELOG.md`](CHANGELOG.md)).

### The audit surfaced a real control gap, on first contact

While narrating the most recent execution, Claude observed that `agent_registry.approval_threshold = 2` for RED-tier agents, and the `policy_rationale` text claimed *"Controller + CFO review required"*, but the HITL trigger only enforced `approver_id ≠ agent_invoker_id`. The single-approver check was wired; **dual-approval was named in documentation but not wired in code**.

<p align="center">
  <img src="docs/evidence/mcp/mcp_03_dual_approval_gap_surfaced.png" alt="MCP self-audit surfacing dual-approval gap" width="800"/>
</p>

Documented as **[ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)** the same hour. Dual approval is now enforced ([ADR-0004](docs/adr/0004-dual-approval-enforced.md)) and live since 2026-11-09: a request whose review sub-tier is CRITICAL needs two approvals from different approvers, never the invoker. The live functional smoke run on 2026-11-09 needed and got two (Sarah, then Marcus) after the invoker's own approval was refused.

Full evidence preserved at [`docs/evidence/mcp/`](./docs/evidence/mcp/).

---

## 🧱 What Ships

On the live stack, one CRITICAL review run of the flagship writes 13 ledger rows: the live functional smoke run of 2026-11-09 wrote this chain, and e2e scenario S02 checks it. The v1 evidence run wrote 11: it had no NOTIFICATION_SENT or HITL_APPROVAL_RECORDED row, it needed one approval, and its approver was named in the request, not taken from a session.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   One HITL-gated CRITICAL run writes 13 ledger rows:                     │
│                                                                          │
│     STARTED                  ← run claimed with its token; invoker and   │
│                                asset scope set by the database           │
│       │                                                                  │
│       ├─ ASSET_RECONCILED   ← BTC: ratio 1.003, BELOW_BAND_LOWER,        │
│       │                       ALLOW_WITH_OBLIGATIONS                     │
│       ├─ ASSET_RECONCILED   ← ETH: ratio 1.013, IN_BAND, ALLOW           │
│       ├─ ASSET_RECONCILED   ← USDC: clean baseline, ALLOW                │
│       ├─ ASSET_RECONCILED   ← USDT: surplus in band, IN_BAND, ALLOW      │
│       ├─ ASSET_RECONCILED   ← SOL: under-reserved, REQUIRE_HUMAN/CRIT    │
│       ├─ ASSET_RECONCILED   ← XRP: ratio 1.006, IN_BAND, ALLOW           │
│       └─ ASSET_RECONCILED   ← ADA: negative ledger, REQUIRE_HUMAN/CRIT   │
│                                                                          │
│     HITL_REQUESTED          ← rollup in SQL (worst asset) → CRITICAL     │
│                                request, 2 approvals enforced, opened in  │
│                                the same transaction                      │
│     NOTIFICATION_SENT       ← the notifier's Slack attempt, recorded     │
│     HITL_APPROVAL_RECORDED  ← first approval, from Sarah's own session;  │
│                                decides nothing yet                       │
│     HITL_RESOLVED           ← second approval (Marcus) decides; never    │
│                                the invoker (Aisha)                       │
│     COMMITTED               ← written with HITL_RESOLVED in one          │
│                                transaction by fao_hitl_decide            │
│                                                                          │
│   Every row carries one correlation_id and a database-set timestamp.     │
│   UPDATE, DELETE, TRUNCATE and direct INSERT are refused for every       │
│   application role; rows are appended only through database functions.   │
│   The database owner remains outside the control.                        │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Component overview

Counts are from the tree at commit `c9c2fc0`, the commit deployed at the 2026-11-09 cutover. The cutover applied migrations `0009` to `0020` on top of the v1 schema already live (v1 was applied by hand without a migration table; the bundle was first run against an exact copy of live's schema and data), and seeds `0007` (roles) and `0008` (settings).

| Component | What it is | Role of AI |
|-----------|-----------|:-:|
| **Platform governance layer** | 22 Postgres migrations (10 from v1, `0009` to `0020` from the November 2026 release, including `0018` to `0020` for dual approval) + 5 seed files, plus one local-only settings seed. 15 `FAO-GOV-*` controls. | None |
| **Run and decision functions** | `fao_run_start`, `fao_run_claim`, `fao_ledger_append_batch`, `fao_run_finalize`, `fao_run_fail`, `fao_hitl_get`, `fao_hitl_decide`, `fao_maintenance_sweep`, the notification functions and five admin functions. The v1 `fao_hitl_create` is dropped; `fao_hitl_resolve` is kept only as a stub that always raises. | None |
| **Reserve Reconciliation Agent** (flagship) | n8n workflow. RED-tier. FAO-REC-001 → 009. Owner: Sarah Chen. Starts only through its invoke webhook, with a header key and a single-use run token. | None |
| **Writer** | n8n sub-workflow. Validates a batch and appends it through `fao_ledger_append_batch`, all or none. | None |
| **Notifier, sweeper, error handler** | n8n workflows. The notifier (`fao_hitl_gateway_v1`) posts one Slack message per request and records the attempt; the sweeper runs `fao_maintenance_sweep` every 5 minutes; the error handler records failed flagship, notifier and sweeper executions through `fao_run_fail`. | None |
| **Approval page** | Static page in [`approval-app/`](approval-app/). The approver signs in with their own email and password and decides through `fao_hitl_decide` with that session. Live at [approve.velocyt.ca](https://approve.velocyt.ca) on Cloudflare Pages since 2026-11-09. Replaces the v1 n8n approval handler, which is archived. | None |
| **Three stub agents** | Close Orchestrator (AMBER), Variance Analyzer (AMBER), Treasury Monitor (RED). Registered before built. | None |
| **MCP server** | Python FastMCP. 6 read tools + 1 bounded invoke. Reads as a dedicated reader user; invoke calls `fao_run_start` with a human invoker's own session. **No mutation tools by design.** | Read access only |
| **Demo identities** | Sarah Chen (Controller) ← Aisha Okonkwo (FP&A); Sarah → Marcus Patel (CFO). Linear escalation chain. Application roles (invoker, approver, admin, reader) are granted in `fao_user_roles`. | None |
| **AI advisory layer** | Roadmap (v1.1). Gated by `FAO_AI_ASSIST_ENABLED`. Populates `ai_human_brief`. | Advisory only (when shipped) |
| **Weekly Rubric Audit** (FAO-GOV-012) | Roadmap (v1.1). Cron job aggregating 7-day drift signals. | Advisory only (when shipped) |

Full control matrix lives in [`SOX-MAPPING.md`](./SOX-MAPPING.md).

### Flagship: Reserve Reconciliation Agent

The agent reconciles wallet holdings (Fireblocks proxy) against ledger liabilities (NetSuite proxy) across **7 crypto assets**. Fixtures break down into three groups:

- **3 calibrated to Kraken's published Dec 2025 Proof of Reserves.** BTC, ETH, and XRP wallet/ledger pairs reproduce the published ratios (BTC 100.3%, ETH 101.3%, XRP 100.6%), anchoring the agent against real exchange disclosures.
- **1 synthetic clean baseline plus 3 synthetic scenarios, each tagged to the control it exercises.** USDC is the clean baseline. USDT exercises FAO-REC-002: a $67,890.50 surplus inside the stablecoin band, above the $10,000 materiality. It ALLOWs, because stablecoin USD materiality applies to a shortfall only (owner decision 2026-11-08); the escalating shortfall case is in `fixtures/policy_branches.json`. SOL triggers FAO-REC-004 (under-reservation floor). ADA triggers FAO-REC-007 (negative-liability anomaly per the [krakendb 2014 reference](https://github.com/krakenfx/krakendb)).
- **Provenance recorded at the run level.** The STARTED row's `inputs.fixture_provenance` records which asset is calibrated, which is synthetic, and which control each anomaly was designed to exercise. Per-asset `ASSET_RECONCILED` rows do not carry it; the auditor query in [`fixtures/README.md`](fixtures/README.md) joins each asset row to its run's STARTED row (e2e S20 runs that query as printed).

The decision matrix is deterministic: 7 rules evaluated top-down, first match wins. No LLM in the policy path. Since the November 2026 release the inputs fail closed first: an asset with a missing, one-sided or non-finite balance, or with no usable threshold, is BLOCKED, and any REQUIRE_HUMAN, DENY or BLOCKED asset routes the run to human review.

---

## 🔌 Stack

| Layer | Tool | Why |
|-------|------|-----|
| Database + Auth + RLS | Supabase (Postgres; local tests run on 17) | Triggers, RLS and SECURITY DEFINER functions at the database layer; identity from Supabase Auth sessions (`auth.uid()`) |
| Workflow orchestration | n8n (self-hosted, DigitalOcean) | Visual policy logic auditors can read; sub-workflows for governance enforcement boundaries. Connects as the `fao_workflow` role, which can only run the workflow functions and read thresholds. The live n8n and the e2e layer both run 2.46.6 (live was upgraded from 2.44.5 at the cutover) |
| AI advisory (gated, v1.1) | Claude API | Plain-English narrative summaries for human approvers; never on the authority path |
| MCP server | Python 3.12 + FastMCP + httpx | Read + bounded-invoke surface for AI consumers; stdio transport |
| HITL approval channel | Slack notice with a link to the static approval page (`approval-app/`) | The approver signs in and decides with their own session through `fao_hitl_decide`. Separate from the MCP surface, which has no tool that calls it. The v1 n8n approval handler was archived at the 2026-11-09 cutover; its webhooks return 404 |
| Approval enforcement | `fao_hitl_decide` plus the `hitl_queue_guard_stmt` and `hitl_queue_guard_row` triggers (migration 0013) | Self-approval is refused with `SOD_SELF_APPROVAL` and journaled; decided rows cannot change; any direct write to `hitl_queue` by a non-owner role is refused. Replaces the v1 `hitl_queue_sod_guard` trigger, which 0013 drops |
| Append-only enforcement | `shadow_ledger_append_only_guard` (UPDATE/DELETE), `deny_truncate` on every FinAgent table, no INSERT grant for any client role | Ledger rows are appended only through database functions. The database owner can still disable or drop a trigger, so this is not administrator-proof |

**No infrastructure novelty.** Everything in this stack is off-the-shelf. The contribution is the application layer: domain-specific governance for SOX-regulated crypto-finance, not the underlying tools.

---

## 📖 How to Read This Repo

For a reviewer with limited time, here's the recommended path:

1. **[`SOX-MAPPING.md`](./SOX-MAPPING.md)**: start with the *Where-is-the-AI* table. ~90 seconds. Tells you the architecture's stance on AI authority.
2. **[The MCP self-audit transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)**: ~5 minutes. Claude Opus interrogating the audit trail and red-teaming the surface.
3. **[ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)**: the dual-approval gap that surfaced during the audit, and **[ADR-0004](docs/adr/0004-dual-approval-enforced.md)**, how it is now enforced (live since 2026-11-09). ~4 minutes.
4. **[`supabase/migrations/0013_guards_and_policies.sql`](supabase/migrations/20261107_0013_guards_and_policies.sql)** + **[`0015_hitl_rpcs.sql`](supabase/migrations/20261107_0015_hitl_rpcs.sql)**: the guard triggers and the decision function (`fao_hitl_decide`). ~10 minutes. Read the code that enforces SoD, immutable decisions and one-transaction resolution. The v1 triggers stay in [`0004`](supabase/migrations/20260420_0004_shadow_ledger.sql) (append-only, still in use) and [`0005b`](supabase/migrations/20260420_0005b_hitl_queue_sod_trigger.sql) (SoD, dropped by 0013).
5. **[`workflows/fao_reserve_recon_v1.json`](workflows/fao_reserve_recon_v1.json)**: the flagship's policy decision matrix. The relevant code is in the *Per-Asset Reconcile* node's `jsCode` block. [`workflows/README.md`](workflows/README.md) walks through the run flow.

Total: ~25 minutes for a read of how the platform works and what's shipped vs. roadmap.

---

## 🧪 Tests

One command runs every automated layer against a local stack. Docker Desktop is required for the database and e2e layers.

```
npm ci
npm run stage        # stages the migrations for the local Supabase CLI
npm run sb:start
npm run db:reset     # fresh database, demo users, roles and seeds
npm test             # every layer; npm run test:offline runs the first three only
```

| Layer | What it runs |
|---|---|
| `exports` | Static checks of the n8n exports: parameterized queries, publish order, error workflow wiring, the finalize gate, node versions |
| `node` | Node unit tests of the Code-node JavaScript, extracted from the exports at test time, and of the approval page's pure functions |
| `pytest` | MCP server tests, offline (PostgREST mocked) |
| `pgtap` | pgTAP files in `supabase/tests/` against the local database: grants, guards, decisions, runs, rollup, sweep, journal, admin |
| `api` | Real sign-ins against the local Supabase API: SoD, spoofed identity, direct writes, body checks, status codes |
| `e2e` | A fresh n8n 2.46.6 in Docker with a mock Slack: the exports are imported, published and run for real (scenarios S01 to S27) |

The last full run (2026-11-08 17:55 UTC, at commit `c9c2fc0`, the commit deployed to live, with the local PostgREST pinned to 14.5 as on live, fresh reset; the same totals as the 17:29 UTC run on top of `41e11cc`) passed every layer, with nothing skipped:

| exports | node | pytest | pgtap | api | e2e | total |
|---:|---:|---:|---:|---:|---:|---:|
| 143 | 176 | 344 | 1563 | 60 | 27 | 2313 |

`python mcp/scripts/smoke_local.py` checks the six MCP read tools against the local stack; it is not part of `npm test`.

**CI.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs the same command in four jobs (static, mcp, db, e2e) on pinned versions. It first ran on GitHub on 2026-11-09: run `42559222998` at commit `744ca3a` passed all four jobs, 2313 of 2313 (exports 143, node 176, pytest 344, pgTAP 1563, API 60, e2e 27), on Node 22.23.4 and Python 3.12.16. The run before it (`42558681123`) failed only the e2e job, before any test, on a Linux file-permission problem in the test harness that `744ca3a` fixed.

**Manual page check.** There is no automated browser test of the approval page, in CI or locally. Its sign-in and decision flow is checked by hand once per release: no session, invoker view (no buttons), approver decision, reload, an invalid link, and no CSP report in the console; on a two-approval request, a first approval that is recorded but not committed, then a second approver's decision. For this release the whole check (steps 1 to 15 of [`approval-app/README.md`](approval-app/README.md)) was done on 2026-11-08 against the local stack, in the built-in Chromium browser of the Claude desktop app, driven by Claude Code (an AI agent) rather than by a person, with seed test users. On live, go-live repeated the no-session, invalid-link and expired-request checks on approve.velocyt.ca with a clean console (Claude Code, same browser); the owner used the page for the smoke run's two approvals and its rejection, and checked it in Chrome, Brave and Firefox.

The table above is a local result. The live stack was checked by the cutover's functional and security smoke runs instead (see [Live since 2026-11-09](#-why-i-built-this)).

---

## 🔐 Admin Changes

Admin changes go through five database functions, each called with an admin's own signed-in session and a reason, and each audited with before and after images in `fao_admin_audit`:

| Function | What it changes |
|---|---|
| `fao_admin_set_threshold` | One materiality threshold (floor, band, USD materiality) |
| `fao_admin_set_agent` | An agent's status, AI advisory flag or hourly run limit; ACTIVE needs both SLAs set |
| `fao_admin_set_role` | Grants or revokes an application role; grants are revoked, never deleted; no admin changes their own roles |
| `fao_admin_set_owner_active` | Deactivates or reactivates a process owner; owners are never deleted |
| `fao_ledger_correct` | Appends a CORRECTION row that references the original; the original row never changes |

There is no command-line tool for these yet, and no settings function. The database owner can change configuration tables (owners, registry, thresholds, roles, settings) in the Supabase SQL editor, but only with a change reason set in the same run:

```sql
select set_config('fao.change_reason', '<reason>', true);
-- then the change, in the same run
```

A change without a reason is refused, and every changed row is audited with the reason. The owner is still outside the control: the owner can disable these triggers.

---

## ⚖️ Engineering Properties

| Principle | How it works |
|-----------|--------------|
| **Append-only is a database constraint, not a convention** | Since the cutover UPDATE, DELETE, TRUNCATE and direct INSERT on `shadow_ledger` are refused for every application role, and rows are appended only through database functions with database-set timestamps. RLS lets members read and gives no client a write policy. The database owner can still disable or drop a trigger, so it is not administrator-proof. |
| **AI never on the authority path** | Policy outcomes are computed by deterministic rules. No AI call exists in the code; from v1.1, AI produces narrative *after* the decision is made and recorded, so policy outcomes do not depend on it. |
| **The Agent Registry gates every run** | Since the cutover `fao_run_start` refuses a run unless the agent is ACTIVE and under its hourly run limit, and copies the risk tier from the registry onto the run. The registry also supplies the SLA for requests and stale runs. Each registry row specifies risk tier, named process owner, SOX control IDs, rollback procedure, and data sources. Stubs exist in the registry to show the framework precedes the code. |
| **Loud rejection > silent rejection** | Refusals are named and recorded: the database functions return a fixed result code and journal the refusal in the same transaction (a few read answers, such as NOT_FOUND, are not journaled), and the guard triggers raise `FAO-GOV-...` exceptions. Migration 0005c set this course in v1 by removing an RLS policy that returned zero rows. |
| **Channel separation defends in depth** | The MCP surface and the approval page share no transport, and no MCP tool calls `fao_hitl_decide`. The MCP reads as a dedicated reader user, and the database refuses a decision from anyone but an approver for the agent who is not the run's invoker. |
| **No mutation tools on the AI surface** | The MCP server has six read tools and one bounded invoke. There is no `approve_hitl`, no `update_threshold`, no `register_agent`. The asymmetry IS the architecture. |
| **Documented gaps and preserved iteration history** | Known gaps (ADR-0001 and the list under Known Limitations) ship publicly with roadmap entries. The git history of Migration 0005 → 0005b → 0005c is preserved as evidence of how SoD enforcement evolved. |
| **Risk-tier classification before build** | Every agent is GREEN/AMBER/RED before code is written. RED tier agents are configured for 2 approvers (`approval_threshold = 2`). Since the 2026-11-09 cutover two approvals are enforced for CRITICAL review and one for STANDARD, and each request records both counts (ADR-0004); v1 enforced one. |

---

## 🛠️ Build Decisions & Lessons Learned

The interesting decisions weren't the obvious ones. Five non-obvious choices and the alternatives I rejected, with the empirical evidence that drove each.

### 1. The Slack link-expander incident: GET shows a form, POST mutates

The HITL approval flow originally used a single endpoint that accepted approval state via URL parameter. Click the link in Slack → server reads the URL → updates `hitl_queue.decision = 'APPROVED'`. Clean, simple, and **completely broken in practice**.

The first time I posted an HITL request to `#fao-approvals`, every queued item was approved within seconds. No human had clicked anything. Looking at `hitl_queue` showed `approver_id` stamped with the right Controller's UUID and `decided_at` timestamps clustered at the message-post time.

**Slack's link-unfurling bot was walking every URL in the message to generate previews.** A GET request that mutates state is functionally an open invitation to any well-meaning crawler. Fixed by splitting HTTP semantics: GET to that endpoint now renders a confirmation form; POST is the mutation. The Slack expander hits the GET, sees a form, leaves the row alone. The split stops link previewers from changing state; it is not an authorization control, and the v1 endpoints were demo only: unauthenticated and not hardened for production.

The November 2026 release retired those n8n endpoints: the v1 handler was archived at the 2026-11-09 cutover, and its webhooks return 404. The Slack link now opens a static page that changes nothing on load; the approver signs in and the decision is a POST to `fao_hitl_decide` made with their own session token. The page keeps that token in `sessionStorage` and sends no cookie, so the cross-site request forgery risk of a cookie session does not arise.

> **The principle:** HTTP verbs aren't aesthetic. GET is for reads: link previewers, search engines, and accidental retries depend on that. The moment a GET mutates state, your security model includes every entity that ever follows a link.

### 2. SoD enforcement: trigger over RLS

Migration 0005 enforced segregation of duties via a Row-Level Security policy: `WITH CHECK (auth.uid() != agent_invoker_id)`. Functionally correct: a self-approval attempt returns zero affected rows.

That's the problem. **Silent rejection is weaker SOX posture than loud rejection.** A SOX auditor wants clearly-attributed exceptions in logs, not inferred *"this update affected zero rows because policy, we think."* Migration 0005b added a `BEFORE UPDATE` trigger that raises a named exception: `FAO-GOV-004: Segregation of duties violation. approver_id [...] cannot equal agent_invoker_id [...]`. Migration 0005c then *removed* the RLS policy entirely.

The RLS policy and the trigger were two layers on the same vector in the same direction. Layered enforcement is good; redundant enforcement at the same boundary creates interaction problems (the RLS layer silently filtered the violating row before the trigger could raise its loud exception). The trigger was the sole enforcer in v1. The git history of `0005 → 0005b → 0005c` ships in the repo as honest evidence of the evolution.

Since the November 2026 release, decisions moved to one database function, `fao_hitl_decide`, backed by a row guard and a statement guard on `hitl_queue` that hold for every role (migration 0013, which drops the v1 trigger).

> **The principle:** Layer defenses at *different* boundaries (application + database, identity + integrity), not at the same boundary on the same vector. And when forced to choose between silent filtering and loud exception, choose loud. Auditors read logs.

### 3. ASSET_RECONCILED collapses observation + decision into one event

Earlier draft of the flagship had two events per asset: `COMPARED` (the observation: wallet, ledger, ratio computed) and `POLICY_DECIDED` (the deterministic outcome: ALLOW / REQUIRE_HUMAN / etc.). Two rows per asset across 7 assets meant 14 rows just for the per-asset section.

Schema constraint forced the collapse. `shadow_ledger.policy_outcome` is `NOT NULL`. A `COMPARED` row would need a placeholder policy outcome before the decision was actually made, which is misleading at best and audit-poor at worst. Filling it with a sentinel value to satisfy the constraint just hides the issue.

Collapsed into a single `ASSET_RECONCILED` event per asset that captures wallet, ledger, ratio, and policy decision atomically. One row per asset, complete story per asset, cleaner audit grain. The total HITL-gated chain dropped from 16 rows to 11 (13 since the November 2026 release for a two-approval CRITICAL review, which adds NOTIFICATION_SENT and HITL_APPROVAL_RECORDED rows).

> **The principle:** When observation and decision happen atomically with no time gap an auditor cares about, one row tells the cleaner story than two. Schema constraints often surface design questions that prose specs hide.

### 4. The Shadow Ledger Writer is plumbing, not an agent

Considered: every n8n agent writes directly to `shadow_ledger` via the Postgres node. Simple, fewer moving parts.

Decided: centralized "Writer" sub-workflow that every caller routes through. Since the November 2026 release the Writer checks every item of a batch, names every bad item in one error, and appends the batch through `fao_ledger_append_batch`, all or none. The database then checks run state, asset scope and duplicates, and sets the timestamps and run context itself.

Why: the Writer is the single n8n path into `shadow_ledger`, so structural checks live in one place. In v1 it did not stop other database clients from inserting rows directly; since the cutover no client role can insert, update, delete or truncate ledger rows, whichever path they arrive by. That's the database-layer enforcement of FAO-GOV-001. Putting structural validation at the application boundary (above the DB) means the trigger doesn't need to do double duty as a schema validator. Defense in depth at *different* layers: the Writer checks structure for n8n callers, the DB trigger blocks row changes.

The Writer is plumbing because it has no policy logic of its own. It doesn't decide outcomes; it persists them. Putting it in the agent registry would be miscategorization: agents are control-bearing entities; the Writer is a centralized utility.

> **The principle:** Boundary controls belong at boundaries. Schema validation at the app boundary; immutability at the DB boundary. When in doubt about whether something is an "agent," ask whether it makes decisions or just persists them.

### 5. `agent_id` is a TEXT slug, not a UUID

Default Postgres practice for primary keys: UUID. Random, globally unique, no collisions, no naming politics.

Rejected for `agent_registry.agent_id`. The agent_id appears in n8n workflow references, database function calls, log lines, Slack notification messages, audit export filenames, and `shadow_ledger` rows that humans will read. A random UUID in any of those places is operational noise (*"which one is `f3a7c812-...`?"*) that costs reading time at every contact.

`fao_reserve_recon_v1` conveys: this is a FinAgent OS agent (`fao_`), it's the Reserve Reconciliation flagship (`reserve_recon`), version 1 (`v1`). Three things knowable at a glance. The trade-off is naming discipline: slugs need to be globally unique across the codebase, and migrating an agent across versions means a deliberate rename. Worth it.

`shadow_ledger.correlation_id` is still a UUID, because correlation IDs are *internal*: they thread through events for debugging, never read by humans except during forensic queries. Different audience, different optimization.

> **The principle:** Optimize keys for the audience that reads them. If humans read it, make it human-readable. If only machines read it, the random UUID wins.

---

## 📋 Known Limitations

FinAgent OS has run on the live stack since 9 November 2026. This section lists what it does not do yet and what trust it still depends on. Gaps closed at go-live are recorded in [`CHANGELOG.md`](./CHANGELOG.md), the status of each control is in [`SOX-MAPPING.md`](./SOX-MAPPING.md), and engineering edge cases are in [`docs/known-limits.md`](docs/known-limits.md).

### What the live system runs on

- **Sample balances, not real data.** Wallet balances (standing in for Fireblocks) and ledger balances (standing in for NetSuite) are fixed sample data inside the flagship workflow. No live connector exists, so live runs show the controls working, not real reserves. Live connectors are a v2 item.
- **One agent is built.** Only the Reserve Reconciliation agent has a workflow. Close Orchestrator, Variance Analyzer and Treasury Monitor are registered with their governance metadata, but they are placeholders: the database refuses to start them and records the refusal.
- **Not every control is complete.** Of the 24 controls in `SOX-MAPPING.md`, 11 are live, 7 are partial and 6 are planned. The planned ones are the AI-advisory controls and the rollback engine. A rejected request is recorded as rolled back, but nothing is staged or reversed.
- **Reserves are checked asset by asset.** No total reserve ratio is computed across assets, and no single audit evidence package is assembled. The records of a run are retrieved by its correlation id.
- **Dollar materiality changes no outcome today.** USD thresholds are stored for every asset. The other cryptocurrencies have no price feed, so only ratio thresholds apply to them. For stablecoins the floor is 1.00, so any shortfall is already escalated as critical before the dollar test is reached. Ratio checks catch under-reservation for every asset, and a run with missing or one-sided inputs is blocked.
- **The workflow computes the decision.** The n8n workflow computes the pass or escalate decision for each asset. The database checks that every record is complete, well formed and chained, and it routes any escalated asset to review. It does not recompute the decision.

### Approvals and identity

- **No second factor.** Approvals and admin changes need the person's own sign-in, but no second factor yet, so a stolen approver password is enough to approve. For this reason the live agent host stores no user password, and its run-start tool refuses (`NO_USER_CREDENTIAL`). A TOTP second factor is planned.
- **Two accounts, not two people.** In the public demo one person holds every demo login. The controls therefore show that two different accounts approved, not that two different people did. The demo users are Supabase Auth accounts with sign-ups closed. There is no company sign-in (SSO) yet.
- **Any two approvers count.** CRITICAL review needs approvals from two eligible approvers. The system does not model named roles, ranks or amount limits. It does not check that one approver is the Controller and the other the CFO, even though the escalation text names that pairing.
- **An administrator can set up a second approval in advance.** An admin can make another account an admin and have that account give the approver role to a third account. The third account's approval then counts. Every role grant records who made it and when, so this can be detected afterwards but is not prevented ([ADR-0004](docs/adr/0004-dual-approval-enforced.md)).
- **Read access is not limited per agent.** Anyone with any FinAgent role can read every request, ledger record and run for every agent. Only the decision view is limited to approvers, the invoker and admins.

### Trust in the database owner

- Anyone who controls the database owner account or the Supabase project admin can get around these controls. They can change identities or disable the triggers that keep the audit ledger append-only. No application account can change the ledger. At go-live every old key was revoked and the `postgres` password was rotated, and the project now has no secret key, so this trust is limited to the owner's own accounts. No independent write-once copy of the evidence exists yet. Until one does, relying on the ledger also means relying on the controls over the owner's accounts.

### Operations and testing

- **Backups are manual.** The live database is on the Supabase Free plan, which has no automatic daily backups. Backups are manual dumps taken by the owner. The latest, taken on 9 November 2026 after the cutover, passed a restore test. The n8n server has no backup or snapshot. The workflow logic can be rebuilt from this repository; run history and stored credentials cannot.
- **Little run history on live.** CI runs all 27 workflow scenarios end to end against a local n8n on the same version as live. On live, the workflows have run end to end only in the go-live smoke test: one approved run and one rejected run. No failure path has run on live yet.
- **No automated browser test.** The approval page's logic has unit tests. Its sign-in and decision flow was checked by hand, partly by an AI agent driving a browser, in Chromium-based browsers and Firefox. It has not been checked in Safari.
- **One author.** One person designed, built and operates the system. Reviews were done with AI agents. No independent auditor has tested the controls.

### Decisions, not gaps

These behaviours are deliberate. The reasons are in [`docs/known-limits.md`](docs/known-limits.md#decisions) and the linked ADRs.

- STANDARD review needs one approval, even for a RED agent configured for two. Only CRITICAL review needs two ([ADR-0004](docs/adr/0004-dual-approval-enforced.md)).
- Stablecoin reserves are expected to be held near 105%. USDC and USDT pass between a ratio of 1.00 and 1.05; above 1.05 escalates, and below 1.00 is critical.
- A request whose notice cannot be delivered within 20 minutes is escalated once and not retried.
- No AI call exists yet. The advisory layer waits for its own threat model. The MCP server runs locally over stdio, and remote access over HTTP with per-user sign-in is planned.

Planned work for these items is in the [Roadmap](#%EF%B8%8F-roadmap).

---

## 🗺️ Roadmap

- [ ] **v1.1: AI advisory wiring (`FAO_AI_ASSIST_ENABLED=true`).** Claude API integration in the flagship producing `ai_human_brief` for HITL approvers. Gated, read-only on the policy path, with input sanitization for fixture-provenance fields. Ships with its own ADR documenting the threat model.
- [x] **Go-live of the November 2026 release.** Done 2026-11-09 (UTC): migrations, workflows, approval page and MCP reader user deployed to the live stack at commit `c9c2fc0`, with the live-only checks done step by step and a functional and a security smoke run on live.
- [x] **Later: Dual approval.** Live since 2026-11-09 ([ADR-0004](docs/adr/0004-dual-approval-enforced.md), closes ADR-0001): CRITICAL review needs the registry count of approvals (two for RED), each through a qualifying approver grant; it landed with the cutover, and the live smoke run's CRITICAL request was committed only after two approvals. Named approver roles are not modelled (DL-1).
- [ ] **Later: TOTP second factor, journal for refused direct writes, automated browser test of the approval page, command-line tools.** Deferred to a later release (see [Known Limitations](#-known-limitations)).
- [ ] **v1.1: Weekly Rubric Audit (FAO-GOV-012).** Cron-scheduled n8n job. Aggregates HITL count by asset, ratio variance, approval-time distribution. AI advisory narrative section gated by feature flag.
- [ ] **v1.2: HTTP transport for MCP server.** Streamable HTTP per MCP spec, behind Caddy at `mcp.velocyt.ca`, with OAuth 2.1 per-user identity (not demo emails).
- [ ] **v1.2: Comparator landscape.** Direct comparison against Microsoft Agent Governance Toolkit, SOXAgent.com, Zenity, ChatFin, OPA. Ships once the three stubs are real (v2 milestone).
- [ ] **v2: Three stubs → real implementations.** Close Orchestrator, Variance Analyzer, Treasury Monitor. Each lands as its own workflow with module-specific control IDs (FAO-CLS, FAO-VAR, FAO-TRE).
- [ ] **v2: Fireblocks + NetSuite live connectors.** Move from fixture-backed to telemetry-backed. Brings real data integrity concerns into scope (rate limits, schema drift, partial reads).
- [ ] **v2+: Multi-agent coordination layer.** Cross-agent handoffs, shared correlation IDs across executions, dependency graphs. Treasury Monitor → Variance Analyzer → Close Orchestrator as a worked example.

---

## 🙏 Prior Art & Acknowledgements

FinAgent OS does not exist in a vacuum. The governance-first design is informed by publicly available prior art in the agentic AI and financial controls space.

- **[ATLAS (`quantumlayer-atlas/atlas`)](https://github.com/quantumlayer-atlas/atlas)**: the principle that AI should be optional and non-authoritative in policy decisions, and the *"Where is the AI?"* table format adapted in [`SOX-MAPPING.md`](./SOX-MAPPING.md).
- **[Kraken's `krakendb` (Payward, 2014)](https://github.com/krakenfx/krakendb)**: the Proof of Reserves hash-tree reference implementation, the canonical operational concern about negative-balance leaves (FAO-REC-007), and the principle that external verification is necessary for trust.
- **[Kraken's `kraken-cli`](https://github.com/krakenfx/kraken-cli)**: the framing of an exchange-finance system as *AI-native*, the pattern of dedicated agent-facing root docs (`AGENTS.md` alongside `README.md`), structured-JSON output discipline at the workflow boundary, and the MCP-server-as-first-class-component posture that FinAgent OS extends to the governance layer. OpenClaw entered my reading list via their docs.
- **[Dewale-A's `Agentic-Accounting-Close`](https://github.com/Dewale-A/Agentic-Accounting-Close)**: concrete dollar-threshold materiality gate pattern; segregation of duties enforced at the API boundary rather than as documentation.
- **[OpenClaw Airlock (`tushar5623/OpenClaw_Airlock`)](https://github.com/tushar5623/OpenClaw_Airlock)**: the GREEN/AMBER/RED/BLOCKED risk tier vocabulary and per-action decision matrix pattern.
- **[COSO 2013 Internal Control: Integrated Framework](https://www.coso.org/SitePages/Internal-Control.aspx)**: the five-component structure every control in `SOX-MAPPING.md` maps to.
- **[Microsoft Agent Governance Toolkit (Apr 2, 2026)](https://github.com/microsoft/agent-governance-toolkit)**: referenced for OWASP Agentic Top 10 alignment. FinAgent OS occupies an adjacent niche (domain-specific application layer for SOX-regulated finance) rather than a general-purpose agent governance toolkit.

Adopted prior-art patterns are cited above. FinAgent OS extends them by applying governance-first architecture to crypto-native financial infrastructure: audit-fluent control vocabulary, crypto-finance domain knowledge in fixtures and thresholds, and AI automation architecture in one stack.

---

## 📜 License

MIT: see [`LICENSE`](./LICENSE). Use this, fork it, take patterns into your own work. The acknowledgement is a star and a link back; the value to me is the patterns reaching more SOX-regulated automation builds.

---

## 💬 Contact

**Rizwan Ahmed, ACCA**
Founder, Velocyt Consulting · Mississauga, ON

- Website: [velocyt.ca](https://velocyt.ca)
- GitHub: [@RZ-Logic](https://github.com/RZ-Logic)

Also built: __[Immi-OS](https://github.com/RZ-Logic/immi-os)__ (immigration automation, real clients) · __[Signal-Driven Outbound Engine](https://github.com/RZ-Logic/signal-driven-outbound-engine)__ (GTM automation)

---

<p align="center">
  <em>If you find this useful, a star helps others find it.</em>
  <br/><br/>
  <sub>Built in Toronto by an audit-trained ACCA who got tired of governance being documentation instead of architecture.</sub>
</p>
