<p align="center">
  <img src="assets/banner.svg" alt="FinAgent OS: Governance-first AI agent platform for SOX-regulated crypto finance" width="100%"/>
</p>

<h1 align="center">FinAgent OS</h1>

<p align="center">
  <strong>The platform's job is to make SOX-defensible properties structurally true,<br/>not just true on paper.</strong>
</p>

<p align="center">
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

When I started designing AI agents for finance operations, the same gap kept appearing. *"The LLM is in the loop but the human is the final decision-maker"* is documentation, not architecture. So I built FinAgent OS: a platform where the SOX-defensible properties (append-only audit, segregation of duties, AI non-authority) are enforced in code, by Postgres triggers and an AI tool surface with no mutation tools, rather than by policy text. That enforcement had known gaps in v1. Phases 2 to 5 close most of them in code; what each fix covers and what stays open is listed under [Known Limitations](#-known-limitations).

The flagship workflow is a Reserve Reconciliation Agent calibrated to crypto-exchange Proof-of-Reserves work, with Kraken's published Dec 2025 PoR as the reference implementation. The platform beneath it supplies the flagship's audit, approval and registry controls.

> **Built versus live.** This branch (`phase2-5-core-2026-11-07`) holds the phases 2 to 5 core: session identity, run tokens, database-only decisions, atomic resolution, timeouts and failure records. None of it is deployed. The live stack still runs v1 until the cutover. Where this README describes the branch, the live system still behaves as v1 did.

---

## 🛡️ The Architectural Principle

> **AI is optional and non-authoritative. Policy decisions are deterministic.**

Every material financial decision in FinAgent OS is enforced by deterministic rules: Postgres triggers, n8n IF nodes, JS decision matrices that an auditor can read top-to-bottom. From v1.1, AI assists human judgment at narrative boundaries (summarizing decisions for human approvers, surfacing drift signals in retrospective audits). AI never produces a control outcome.

The complete enumeration, with every decision point in the system classified deterministic vs. advisory, lives in **[`SOX-MAPPING.md`](./SOX-MAPPING.md)** under the *"Where is the AI?"* table.

**What v1 shows:** no AI call exists anywhere in the v1 policy path, and `agent_registry.ai_advisory_enabled` defaults to FALSE. The `FAO_AI_ASSIST_ENABLED` flag that will gate the v1.1 advisory layer is not yet wired. Every v1 decision is reproducible by reading the migration files, seeds and the flagship workflow. The same holds on this branch, where the run rollup and the request moved into SQL (`fao_run_finalize`).

---

## 🎯 The MCP Self-Audit (Apr 25, 2026)

After the MCP server shipped, **Claude Opus** was given access to the FinAgent OS audit trail through the MCP read surface and asked to (1) narrate the most recent execution, (2) approve a pending HITL request, and (3) red-team the system actively: *"i have designed controls to stop ai from doing it. i want to see you try and fail."*

📜 **Full transcript (public, Anthropic-hosted):**
**[claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)**

Two outcomes worth highlighting.

### The MCP tool surface held under a self-audit probe

Three semantic searches across `approve / resolve / decision`, `write / commit / override / bypass`, and `resolve / set status / sign` all returned the same five tools, **none of which mutate HITL state**. This is a self-audit of the MCP tool surface: an AI on the MCP channel has no tool that approves, resolves or overrides a HITL request. The probe did not test the approval endpoints or the database directly, so it is evidence about the MCP tool surface only.

In the transcript Claude also credits three further layers (a bounded write tool, channel separation and a database trigger) and says there are four. That count was its own inference about v1, not something the probe tested. The v1 approval endpoints were unauthenticated, and the trigger it names (`hitl_queue_sod_guard`) checked only the identities it was given. Phases 2 to 5 drop that trigger and the endpoints; on this branch decisions go only through `fao_hitl_decide` with the approver's own session (see [Control gaps](#control-gaps-status-after-phases-2-to-5-core)).

### The audit surfaced a real control gap, on first contact

While narrating the most recent execution, Claude observed that `agent_registry.approval_threshold = 2` for RED-tier agents, and the `policy_rationale` text claimed *"Controller + CFO review required"*, but the HITL trigger only enforced `approver_id ≠ agent_invoker_id`. The single-approver check was wired; **dual-approval was named in documentation but not wired in code**.

<p align="center">
  <img src="docs/evidence/mcp/mcp_03_dual_approval_gap_surfaced.png" alt="MCP self-audit surfacing dual-approval gap" width="800"/>
</p>

Documented as **[ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)** the same hour. Dual approval is now built on this branch and tested locally ([ADR-0004](docs/adr/0004-dual-approval-enforced.md)): a request whose review sub-tier is CRITICAL needs two approvals from different approvers, never the invoker. It is not live; the live stack still runs v1 with one approval.

Full evidence preserved at [`docs/evidence/mcp/`](./docs/evidence/mcp/).

---

## 🧱 What Ships

On this branch, one review run of the flagship writes 12 ledger rows (e2e scenario S02). The v1 evidence run on the live stack wrote 11: it had no NOTIFICATION_SENT row, and its approver was named in the request, not taken from a session.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   One HITL-gated run on this branch writes 12 ledger rows:               │
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
│                                request, opened in the same transaction   │
│     NOTIFICATION_SENT       ← the notifier's Slack attempt, recorded     │
│     HITL_RESOLVED           ← approver from their own session (Sarah);   │
│                                never the invoker (Aisha)                 │
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

Counts are from the tree on this branch. Per the v1 release record, the live stack runs the first ten migrations and three of the seeds; that count has not been checked against the live database for this build.

| Component | What it is | Role of AI |
|-----------|-----------|:-:|
| **Platform governance layer** | 19 Postgres migrations (10 from v1, `0009` to `0017` from phases 2 to 5) + 5 seed files, plus one local-only settings seed. 15 `FAO-GOV-*` controls. | None |
| **Run and decision functions** | `fao_run_start`, `fao_run_claim`, `fao_ledger_append_batch`, `fao_run_finalize`, `fao_run_fail`, `fao_hitl_get`, `fao_hitl_decide`, `fao_maintenance_sweep`, the notification functions and five admin functions. The v1 `fao_hitl_create` is dropped; `fao_hitl_resolve` is kept only as a stub that always raises. | None |
| **Reserve Reconciliation Agent** (flagship) | n8n workflow. RED-tier. FAO-REC-001 → 009. Owner: Sarah Chen. Starts only through its invoke webhook, with a header key and a single-use run token. | None |
| **Writer** | n8n sub-workflow. Validates a batch and appends it through `fao_ledger_append_batch`, all or none. | None |
| **Notifier, sweeper, error handler** | n8n workflows. The notifier (`fao_hitl_gateway_v1`) posts one Slack message per request and records the attempt; the sweeper runs `fao_maintenance_sweep` every 5 minutes; the error handler records failed flagship, notifier and sweeper executions through `fao_run_fail`. | None |
| **Approval page** | Static page in [`approval-app/`](approval-app/). The approver signs in with their own email and password and decides through `fao_hitl_decide` with that session. Replaces the v1 n8n approval handler, which is retired. | None |
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

The decision matrix is deterministic: 7 rules evaluated top-down, first match wins. No LLM in the policy path. On this branch the inputs fail closed first: an asset with a missing, one-sided or non-finite balance, or with no usable threshold, is BLOCKED, and any REQUIRE_HUMAN, DENY or BLOCKED asset routes the run to human review.

---

## 🔌 Stack

| Layer | Tool | Why |
|-------|------|-----|
| Database + Auth + RLS | Supabase (Postgres; local tests run on 17) | Triggers, RLS and SECURITY DEFINER functions at the database layer; identity from Supabase Auth sessions (`auth.uid()`) |
| Workflow orchestration | n8n (self-hosted, DigitalOcean) | Visual policy logic auditors can read; sub-workflows for governance enforcement boundaries. Connects as the `fao_workflow` role, which can only run the workflow functions and read thresholds. The e2e layer runs n8n 2.46.6; the live version is not yet recorded |
| AI advisory (gated, v1.1) | Claude API | Plain-English narrative summaries for human approvers; never on the authority path |
| MCP server | Python 3.12 + FastMCP + httpx | Read + bounded-invoke surface for AI consumers; stdio transport |
| HITL approval channel | Slack notice with a link to the static approval page (`approval-app/`) | The approver signs in and decides with their own session through `fao_hitl_decide`. Separate from the MCP surface, which has no tool that calls it. The v1 n8n approval endpoints are retired on this branch; live still runs them until the cutover |
| Approval enforcement | `fao_hitl_decide` plus the `hitl_queue_guard_stmt` and `hitl_queue_guard_row` triggers (migration 0013) | Self-approval is refused with `SOD_SELF_APPROVAL` and journaled; decided rows cannot change; any direct write to `hitl_queue` by a non-owner role is refused. Replaces the v1 `hitl_queue_sod_guard` trigger, which 0013 drops |
| Append-only enforcement | `shadow_ledger_append_only_guard` (UPDATE/DELETE), `deny_truncate` on every FinAgent table, no INSERT grant for any client role | Ledger rows are appended only through database functions. The database owner can still disable or drop a trigger, so this is not administrator-proof |

**No infrastructure novelty.** Everything in this stack is off-the-shelf. The contribution is the application layer: domain-specific governance for SOX-regulated crypto-finance, not the underlying tools.

---

## 📖 How to Read This Repo

For a reviewer with limited time, here's the recommended path:

1. **[`SOX-MAPPING.md`](./SOX-MAPPING.md)**: start with the *Where-is-the-AI* table. ~90 seconds. Tells you the architecture's stance on AI authority.
2. **[The MCP self-audit transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)**: ~5 minutes. Claude Opus interrogating the audit trail and red-teaming the surface.
3. **[ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)**: the dual-approval gap that surfaced during the audit, and **[ADR-0004](docs/adr/0004-dual-approval-enforced.md)**, how it is now built on this branch. ~4 minutes.
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

The last full run (2026-11-08 06:04 UTC, dual approval fix round 2, the dual approval tree on top of commit `e12f7d1`, not yet committed, fresh reset) passed every layer, with nothing skipped:

| exports | node | pytest | pgtap | api | e2e | total |
|---:|---:|---:|---:|---:|---:|---:|
| 143 | 176 | 344 | 1563 | 60 | 27 | 2313 |

`python mcp/scripts/smoke_local.py` checks the six MCP read tools against the local stack; it is not part of `npm test`.

**CI.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs the same command in four jobs (static, mcp, db, e2e) on pinned versions. It has not yet run on GitHub, so there is no status badge yet.

**Manual page check.** There is no automated browser test of the approval page, in CI or locally. Its sign-in and decision flow is checked by hand once per release: no session, invoker view (no buttons), approver decision, reload, an invalid link, and no CSP report in the console; on a two-approval request, a first approval that is recorded but not committed, then a second approver's decision. For this branch the whole check (steps 1 to 15 of [`approval-app/README.md`](approval-app/README.md)) was done on 2026-11-08 against the local stack, in the built-in Chromium browser of the Claude desktop app, driven by Claude Code (an AI agent) rather than by a person with seed test users (phase 2-5 RUNS.md, dual approval fix rounds 1 and 2).

These are local results. Nothing here has run against the live stack.

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
| **Append-only is a database constraint, not a convention** | On this branch UPDATE, DELETE, TRUNCATE and direct INSERT on `shadow_ledger` are refused for every application role, and rows are appended only through database functions with database-set timestamps. RLS lets members read and gives no client a write policy. The database owner can still disable or drop a trigger, so it is not administrator-proof. |
| **AI never on the authority path** | Policy outcomes are computed by deterministic rules. No AI call exists in the code; from v1.1, AI produces narrative *after* the decision is made and recorded, so policy outcomes do not depend on it. |
| **The Agent Registry gates every run** | On this branch `fao_run_start` refuses a run unless the agent is ACTIVE and under its hourly run limit, and copies the risk tier from the registry onto the run. The registry also supplies the SLA for requests and stale runs. Each registry row specifies risk tier, named process owner, SOX control IDs, rollback procedure, and data sources. Stubs exist in the registry to show the framework precedes the code. |
| **Loud rejection > silent rejection** | Refusals are named and recorded: the database functions return a fixed result code and journal the refusal in the same transaction (a few read answers, such as NOT_FOUND, are not journaled), and the guard triggers raise `FAO-GOV-...` exceptions. Migration 0005c set this course in v1 by removing an RLS policy that returned zero rows. |
| **Channel separation defends in depth** | The MCP surface and the approval page share no transport, and no MCP tool calls `fao_hitl_decide`. The MCP reads as a dedicated reader user, and the database refuses a decision from anyone but an approver for the agent who is not the run's invoker. |
| **No mutation tools on the AI surface** | The MCP server has six read tools and one bounded invoke. There is no `approve_hitl`, no `update_threshold`, no `register_agent`. The asymmetry IS the architecture. |
| **Documented gaps and preserved iteration history** | Known gaps (ADR-0001 and the list under Known Limitations) ship publicly with roadmap entries. The git history of Migration 0005 → 0005b → 0005c is preserved as evidence of how SoD enforcement evolved. |
| **Risk-tier classification before build** | Every agent is GREEN/AMBER/RED before code is written. RED tier agents are configured for 2 approvers (`approval_threshold = 2`). On this branch two approvals are enforced for CRITICAL review and one for STANDARD, and each request records both counts (ADR-0004); live v1 enforces one. |

---

## 🛠️ Build Decisions & Lessons Learned

The interesting decisions weren't the obvious ones. Five non-obvious choices and the alternatives I rejected, with the empirical evidence that drove each.

### 1. The Slack link-expander incident: GET shows a form, POST mutates

The HITL approval flow originally used a single endpoint that accepted approval state via URL parameter. Click the link in Slack → server reads the URL → updates `hitl_queue.decision = 'APPROVED'`. Clean, simple, and **completely broken in practice**.

The first time I posted an HITL request to `#fao-approvals`, every queued item was approved within seconds. No human had clicked anything. Looking at `hitl_queue` showed `approver_id` stamped with the right Controller's UUID and `decided_at` timestamps clustered at the message-post time.

**Slack's link-unfurling bot was walking every URL in the message to generate previews.** A GET request that mutates state is functionally an open invitation to any well-meaning crawler. Fixed by splitting HTTP semantics: GET to that endpoint now renders a confirmation form; POST is the mutation. The Slack expander hits the GET, sees a form, leaves the row alone. The split stops link previewers from changing state; it is not an authorization control, and the v1 endpoints were demo only: unauthenticated and not hardened for production.

Phases 2 to 5 retire those n8n endpoints on this branch (live still runs them until the cutover). The Slack link now opens a static page that changes nothing on load; the approver signs in and the decision is a POST to `fao_hitl_decide` made with their own session token. The page keeps that token in `sessionStorage` and sends no cookie, so the cross-site request forgery risk of a cookie session does not arise.

> **The principle:** HTTP verbs aren't aesthetic. GET is for reads: link previewers, search engines, and accidental retries depend on that. The moment a GET mutates state, your security model includes every entity that ever follows a link.

### 2. SoD enforcement: trigger over RLS

Migration 0005 enforced segregation of duties via a Row-Level Security policy: `WITH CHECK (auth.uid() != agent_invoker_id)`. Functionally correct: a self-approval attempt returns zero affected rows.

That's the problem. **Silent rejection is weaker SOX posture than loud rejection.** A SOX auditor wants clearly-attributed exceptions in logs, not inferred *"this update affected zero rows because policy, we think."* Migration 0005b added a `BEFORE UPDATE` trigger that raises a named exception: `FAO-GOV-004: Segregation of duties violation. approver_id [...] cannot equal agent_invoker_id [...]`. Migration 0005c then *removed* the RLS policy entirely.

The RLS policy and the trigger were two layers on the same vector in the same direction. Layered enforcement is good; redundant enforcement at the same boundary creates interaction problems (the RLS layer silently filtered the violating row before the trigger could raise its loud exception). The trigger was the sole enforcer in v1. The git history of `0005 → 0005b → 0005c` ships in the repo as honest evidence of the evolution.

Phases 2 to 5 note: decisions moved to one database function, `fao_hitl_decide`, backed by a row guard and a statement guard on `hitl_queue` that hold for every role (migration 0013, which drops the v1 trigger).

> **The principle:** Layer defenses at *different* boundaries (application + database, identity + integrity), not at the same boundary on the same vector. And when forced to choose between silent filtering and loud exception, choose loud. Auditors read logs.

### 3. ASSET_RECONCILED collapses observation + decision into one event

Earlier draft of the flagship had two events per asset: `COMPARED` (the observation: wallet, ledger, ratio computed) and `POLICY_DECIDED` (the deterministic outcome: ALLOW / REQUIRE_HUMAN / etc.). Two rows per asset across 7 assets meant 14 rows just for the per-asset section.

Schema constraint forced the collapse. `shadow_ledger.policy_outcome` is `NOT NULL`. A `COMPARED` row would need a placeholder policy outcome before the decision was actually made, which is misleading at best and audit-poor at worst. Filling it with a sentinel value to satisfy the constraint just hides the issue.

Collapsed into a single `ASSET_RECONCILED` event per asset that captures wallet, ledger, ratio, and policy decision atomically. One row per asset, complete story per asset, cleaner audit grain. The total HITL-gated chain dropped from 16 rows to 11 (12 on this branch, which adds a NOTIFICATION_SENT row).

> **The principle:** When observation and decision happen atomically with no time gap an auditor cares about, one row tells the cleaner story than two. Schema constraints often surface design questions that prose specs hide.

### 4. The Shadow Ledger Writer is plumbing, not an agent

Considered: every n8n agent writes directly to `shadow_ledger` via the Postgres node. Simple, fewer moving parts.

Decided: centralized "Writer" sub-workflow that every caller routes through. On this branch the Writer checks every item of a batch, names every bad item in one error, and appends the batch through `fao_ledger_append_batch`, all or none. The database then checks run state, asset scope and duplicates, and sets the timestamps and run context itself.

Why: the Writer is the single n8n path into `shadow_ledger`, so structural checks live in one place. In v1 it did not stop other database clients from inserting rows directly; on this branch no client role can insert, update, delete or truncate ledger rows, whichever path they arrive by. That's the database-layer enforcement of FAO-GOV-001. Putting structural validation at the application boundary (above the DB) means the trigger doesn't need to do double duty as a schema validator. Defense in depth at *different* layers: the Writer checks structure for n8n callers, the DB trigger blocks row changes.

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

The gaps a reviewer would find are surfaced below. "Fixed" means built on this branch and covered by tests that pass in dual approval fix round 2 (2313 of 2313, see [Tests](#-tests)). None of it is live: the live stack runs v1, with every v1 gap, until the cutover.

### Control gaps: status after phases 2 to 5 (core)

- **Identity binding of approver and invoker. Fixed:** the invoker and the approver are taken from their own Supabase Auth sessions (`auth.uid()`); no identity is taken from a payload. A second factor is not yet required (see Remaining limits).
- **Decided HITL requests were not locked; SoD was not a boundary against privileged credentials. Fixed for application roles:** decisions are recorded only through `fao_hitl_decide`, self-approval is refused, and decided requests cannot be changed. The service-role key has no access to FinAgent objects and no FinAgent component holds it. The database owner and holders of platform admin keys remain outside the control.
- **The approval endpoints were demo only: unauthenticated and not hardened. Fixed:** the n8n approval pages are retired. Approvers sign in on a static approval page and decide with their own session; the run-start webhook needs a header key and a single-use run token; response statuses match outcomes.
- **HITL resolution and its ledger writes were not atomic. Fixed:** the decision and its ledger events commit in one transaction, and so do request creation and its ledger event.
- **Not every failure was recorded to the ledger. Fixed in the database and the workflows:** an error workflow, a five-minute sweep and notification records. A failure that cannot attach to a run is kept in the append-only `workflow_failures` table. The workflows run end to end in the e2e layer against n8n 2.46.6 only, not yet on the live n8n. The Writer has no error workflow of its own; a failed Writer call fails the flagship, which is recorded.
- **HITL timeout was not enforced. Fixed:** late decisions are refused; overdue requests expire and escalate once. HITL_EXPIRED is the expiry record of an expired request (its escalation can follow it), and the request is never recorded as a commit.
- **Append-only was not administrator-proof. Narrowed:** UPDATE, DELETE, TRUNCATE and direct INSERT are refused for every application role, and ledger rows are appended only through database functions with database-set timestamps. The database owner remains outside the control (the owner can disable or drop a trigger). There is no independent or write-once evidence store; trusting the owner is a design choice for now, and independent evidence storage is planned.
- **The committed Writer export dropped batch items. Fixed:** the Writer stores a batch all or none and names every bad item.
- **Dual approval was named, not wired (ADR-0001). Fixed on this branch for CRITICAL review ([ADR-0004](docs/adr/0004-dual-approval-enforced.md)):** a request whose review sub-tier is CRITICAL needs two approvals (the registry count for the RED flagship) from different approvers, never the invoker, each through an approver grant made before the request was opened, not by the invoker and not by another approver of it; one rejection closes the request. STANDARD review keeps one approval. Tested locally only; live runs v1.

### Remaining limits

- The database owner, holders of the `postgres` password and holders of platform admin or secret keys are outside the control (they can change identities or disable triggers); the plan is that after cutover only the owner's password manager holds them; that is not yet in place.
- In the public demo one person holds every demo identity; the controls bind actions to identities, they cannot prove those identities are different people.
- Policy inputs and per-asset outcomes are produced by the n8n workflow; the database checks shape, completeness, fail-closed inputs and chain integrity, not the policy result.
- Approver authority beyond role membership (rank, limits per amount, named roles) is not modelled (DL-1).
- A request whose sign-in token fails verification is refused by the API layer and recorded only in platform logs; above the journal cap only one marker row per minute is written, while refusals continue.
- One escalation level; no notification after a decision.
- **TOTP second factor for approvals and admin changes.** Approvals and admin changes require the person's own signed-in session, but not yet a second factor. A TOTP second factor for approvers and admins is planned. Until it ships, a stored password is enough to approve for any user who holds the approver role, so run-start credentials kept on an agent host should belong to a user without that role.
- **Refusal journal for direct table writes (dblink).** Direct table writes are refused for every application role, but only refusals returned by the FinAgent database functions are recorded in the refusal journal. Recording refused direct writes is planned.
- **Automated browser test of the approval page.** The approval page's logic is covered by unit tests and its sign-in and decision flow is checked by hand; there is no automated browser test yet.
- **Python command-line tools (run start, admin).** There is no command-line tool yet for starting runs or for admin changes. Runs start through the MCP tool; admin changes go through the admin functions with the admin's own session, or through the documented SQL recipe with a change reason.
- **Hosted rehearsal before cutover.** Behaviour that only a hosted project shows (pooler login, API key mode, Auth settings, page headers) is checked step by step during the live cutover, not first in a rehearsal on a scratch project.
- **Automated end-to-end run of the n8n workflows (live n8n version).** The n8n workflows run end to end automatically on a local n8n 2.46.6 only: the e2e layer imports the exports, publishes them and runs scenarios S01 to S27 against local Supabase and a mock Slack in every `npm test`; the CI `e2e` job runs the same layer but has not yet run on GitHub. They are not run end to end against the live n8n version, and no failure path is exercised on live.
- **Named roles are not modelled (DL-1).** Dual approval counts distinct users who hold the approver role for the agent. Roles such as Controller and CFO are not modelled, so the two approvals can come from any two eligible approvers. The flagship's rationale text "Controller + CFO review required" describes the intended pairing; the system does not check it.
- **STANDARD review keeps one approval (DL-2).** A request whose review sub-tier is STANDARD needs one approval, also for a RED agent whose registry count is two (owner decision DA-1). Its ledger row says "approvals enforced 1 of configured 2".
- **Two identities, not proven two people (DL-8).** Two approvals need two signed-in identities, but there is still no second factor (TOTP second factor, above), and in the public demo one person holds every demo identity. Dual approval binds the approvals to two identities; it cannot prove they are two different people. DA-4 only stops a grant made by the invoker or by another approver of the same request, so an admin can still prepare a second approval before a request indirectly: make a second identity an admin, and have that identity grant the approver role to a third; the third identity's approval counts, because its granter did not approve. Every grant records who made it and when.
- The aggregate reserve ratio is planned (scope, valuation basis and floor first). There is no evidence package yet. FAO-REC-003, FAO-REC-004 and FAO-REC-008 in [`SOX-MAPPING.md`](./SOX-MAPPING.md) carry their status.
- Requests that PostgREST refuses before a database function runs (an empty body, invalid JSON, GET or form-encoded calls) are not journaled. None of them changes anything; this was measured on the local PostgREST only.
- A new n8n execution that reuses the execution id of a run still RUNNING inside its SLA window is refused at claim. If that execution then fails at any node before Respond 202 (the refused branch included), the error handler records it as pre-claim and never touches the older run; past the window, the claim fails the stale run first. A claim that committed and then errored inside Claim Run leaves its run RUNNING until the sweep fails it as stale. The stale-run rule relies on n8n stopping the flagship at its 600-second `executionTimeout` before the 900-second floor of `sla_max_execution_seconds`; that holds only where n8n's `EXECUTIONS_TIMEOUT_MAX` is at least 600. The database still cannot tell two executions with the same id apart.
- **Stablecoin band (F-24, decided 2026-11-07).** The owner decided that stablecoin reserves are held near 105%, so the seeded USDC and USDT upper band is 1.05 (floor and lower band stay 1.0000); a ratio above 1.05 escalates as ABOVE_BAND_UPPER. The live table holds 1.0050 until the cutover runbook applies 1.05 through `fao_admin_set_threshold` with a change reason (IC-38); until then live escalates a stablecoin ratio above 1.005. The owner decided on 2026-11-08 that stablecoin USD materiality (rule 5) applies to a shortfall only: a surplus inside the band ALLOWs however large it is, and a shortfall escalates as IN_BAND_USD_MATERIAL only when ledger minus wallet exceeds `materiality_usd`. With the seeded floor equal to the band lower (1.0000), any stablecoin shortfall is caught first as BELOW_FLOOR CRITICAL, so rule 5 fires only under a threshold whose floor is below 1.00 (tested offline with a threshold override, not end to end). The owner decided on 2026-11-08 to keep the stablecoin floor at 1.00: any stablecoin under-reserve is CRITICAL, and FAO-REC-002 is inactive under the seeded thresholds.
- A database error inside the notifier, or an unpublished notifier, fails the sweeper run visibly but does not count toward the notification retry limit. A notice target deactivated between an escalation and its first send gets no operator alert unless the notice is listed again. The wording of an expired escalation uses the n8n host clock.
- Every member can read every request, ledger row and run across agents; only the decision view is limited to approvers, the invoker and admins.
- A role grant created at the same moment as a decision or finalize is not waited for; this can only turn a refusal into an allow on a later decision, never the reverse.
- The role helpers refuse a client's question about another user by reading the database call stack; any new `fao_*` function that passes a caller-chosen user id to them needs review.
- Ids the database checks only by pattern (asset symbols, `agent_id`) can still spell words; the MCP marks free text as untrusted.
- The sweeper's last check relies on n8n's documented branch order; `check-exports` holds the layout, and a reversed order would fail loudly, not silently.
- The rollback script's privileges were compared with a local database only, never with the live v1 grants.
- CI has not run on GitHub, and Node 22 and Python 3.12 have not been used locally (CI pins them). The approval page has been checked only against the local stack, in the built-in Chromium browser of the Claude desktop app, driven by Claude Code (an AI agent) rather than by a person; not in another browser and not against a hosted project.
- Some api and e2e tests briefly change shared demo users, roles or the test clock and restore them afterwards; run those layers with nothing else on the stack.

### Owner decisions (2026-11-08)

These were open in earlier rounds and are now decided. Every interface change made during the build is still accepted pending the owner's sign-off.

- **Notice window (R12), accepted as built.** A request with no sent notice after 5 minutes x (`notify_max_attempts` + 1), 20 minutes at the default, is escalated once as NOTIFICATION_FAILED, even with no recorded attempt, and is no longer retried.
- **Invoker keys on STARTED (IC-11), refuse.** A STARTED item whose inputs carry `invoker_id`, `invoked_via`, `reason` or `n8n_execution_id` (at any depth, in any normalised spelling) is refused and nothing is written; the database sets those four values itself from the run record. The flagship sends none of them, and `check-exports` holds that (rule `started_db_keys`).
- **Stablecoin USD materiality, shortfall only.** See the stablecoin band item above.

### Wired but not yet complete

These features are scaffolded (registry rows, schema columns, control IDs) and ship in a later release to close the loop.

- **The Weekly Rubric Audit (FAO-GOV-012) is referenced in [`SOX-MAPPING.md`](./SOX-MAPPING.md) but not yet implemented.** Cron-scheduled n8n job aggregating drift signals from `shadow_ledger`; ships in v1.1.

### Deliberately deferred until the threat model ships

These features are held back because the security model needs to ship first. Activating them without that work would be a posture downgrade.

- **AI advisory layer is not built; `FAO_AI_ASSIST_ENABLED` will gate it.** No AI call exists in the code, and `agent_registry.ai_advisory_enabled` defaults to FALSE. The deterministic spine had to be defensibly complete before AI was allowed near it. The threat model shifts when LLMs touch the chain (prompt injection via fixture provenance, advisory drift); those defenses ship as their own ADR before the flag flips.
- **MCP transport is stdio, not HTTP.** Stdio is the correct choice for the current audience: local Claude Desktop, Cursor, etc. HTTP + per-user OAuth for the MCP server is a v1.2 ADR; the auth boundary needs to be designed before the transport is opened.

### Stubs and fixtures by design

These are properties of the scope, not gaps. The registry-precedes-the-build pattern is FAO-GOV-002 working as designed. Fixtures isolate policy logic from connector plumbing. Demo identities exercise the auth shape without production exposure.

- **Three stub agents are registered but not implemented.** Close Orchestrator, Variance Analyzer, Treasury Monitor exist in `agent_registry` with `status=STUB_DOCUMENTED`, named process owners, declared SOX control inheritance, and stated rollback posture. They have no workflow, so there is nothing to execute. On this branch registry status and the hourly rate limit are checked at run start, and the tier is copied from the registry: `fao_run_start` refuses a stub with `AGENT_NOT_ACTIVE` and records a RUN_REFUSED row. The registry row *precedes* the workflow build by design: FAO-GOV-002 enforcing *no agent without governance metadata first*.
- **Fixtures, not live connectors.** Wallet data is a Fireblocks proxy; ledger data is a NetSuite proxy. Both are inline JSON in the flagship workflow. This isolates policy logic from data-source plumbing: the policy engine is testable end-to-end without live API dependencies. Live connectors are v2.
- **Demo identities, not production auth.** Three Supabase Auth users (`@finagent-os.demo`) seed the process_owners table, and their application roles are seeded in `fao_user_roles`. Local setup also creates the MCP reader user and a test user with no role. The identity provider is demo. Production identity (OAuth 2.1, real org SSO) is v2.

### USD materiality enforcement scope

The `materiality_usd` column in `materiality_thresholds` is populated for all seven seeded assets, but the policy engine enforces the USD materiality test only for stablecoin assets (`asset_class = 'Stablecoin'`), where raw units equal USD value (1 USDC = $1), and for those it tests a shortfall only (ledger minus wallet above `materiality_usd`; owner decision 2026-11-08): a surplus inside the band is governed by the band upper alone. For non-stablecoin assets (BTC, ETH, SOL, XRP, ADA), USD materiality enforcement requires a price oracle to convert unit discrepancies to USD and is deferred to v1.1. Ratio-based escalation (FAO-REC-004) provides primary coverage. Under-reservation is caught for every asset in the shipped fixtures, and on this branch missing, one-sided or non-finite inputs are BLOCKED (see `fixtures/README.md`). What's deferred is the in-band-but-large-USD-discrepancy case for non-stablecoin assets.

Most items above have a roadmap entry below or are named in [`SOX-MAPPING.md`](./SOX-MAPPING.md).

---

## 🗺️ Roadmap

- [ ] **v1.1: AI advisory wiring (`FAO_AI_ASSIST_ENABLED=true`).** Claude API integration in the flagship producing `ai_human_brief` for HITL approvers. Gated, read-only on the policy path, with input sanitization for fixture-provenance fields. Ships with its own ADR documenting the threat model.
- [ ] **Phases 2 to 5 cutover.** Deploy this branch's core to the live stack: migrations, workflows, approval page and MCP reader user, with the live-only checks done step by step. Until then the live stack runs v1.
- [x] **Later: Dual approval.** Built on this branch and tested locally ([ADR-0004](docs/adr/0004-dual-approval-enforced.md), closes ADR-0001): CRITICAL review needs the registry count of approvals (two for RED), each through a qualifying approver grant; not live until a landing path has run with the cutover or after it. Named approver roles are not modelled (DL-1).
- [ ] **Later: TOTP second factor, journal for refused direct writes, automated browser test of the approval page, command-line tools.** Deferred from phases 2 to 5 (see Remaining limits).
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
