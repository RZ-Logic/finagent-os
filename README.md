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
  <a href="#-what-ships-in-v1">What Ships</a> •
  <a href="#-stack">Stack</a> •
  <a href="#-how-to-read-this-repo">How to Read</a> •
  <a href="#%EF%B8%8F-build-decisions--lessons-learned">Build Decisions</a> •
  <a href="#%EF%B8%8F-engineering-properties">Engineering Properties</a> •
  <a href="#-known-limitations">Limitations</a> •
  <a href="#%EF%B8%8F-roadmap">Roadmap</a> •
  <a href="#-prior-art--acknowledgements">Acknowledgements</a>
</p>

---

## 🧭 Why I Built This

I'm an ACCA with audit roots who pivoted into AI automation architecture. Working in audit, you learn quickly that *"the policy says X"* and *"the code does X"* are different sentences, and the second one is the only one that matters when the regulator shows up.

When I started designing AI agents for finance operations, the same gap kept appearing. *"The LLM is in the loop but the human is the final decision-maker"* is documentation, not architecture. So I built FinAgent OS: a platform where the SOX-defensible properties (append-only audit, segregation of duties, AI non-authority) are enforced in code, by Postgres triggers and an AI tool surface with no mutation tools, rather than by policy text. That enforcement has known gaps in v1, listed under [Known Limitations](#-known-limitations).

The flagship workflow is a Reserve Reconciliation Agent calibrated to crypto-exchange Proof-of-Reserves work, with Kraken's published Dec 2025 PoR as the reference implementation. The platform beneath it supplies the flagship's audit, approval and registry controls; their v1 gaps are listed under Known Limitations.

---

## 🛡️ The Architectural Principle

> **AI is optional and non-authoritative. Policy decisions are deterministic.**

Every material financial decision in FinAgent OS is enforced by deterministic rules: Postgres triggers, n8n IF nodes, JS decision matrices that an auditor can read top-to-bottom. From v1.1, AI assists human judgment at narrative boundaries (summarizing decisions for human approvers, surfacing drift signals in retrospective audits). AI never produces a control outcome.

The complete enumeration, with every decision point in the system classified deterministic vs. advisory, lives in **[`SOX-MAPPING.md`](./SOX-MAPPING.md)** under the *"Where is the AI?"* table.

**What v1 shows:** no AI call exists anywhere in the v1 policy path, and `agent_registry.ai_advisory_enabled` defaults to FALSE. The `FAO_AI_ASSIST_ENABLED` flag that will gate the v1.1 advisory layer is not yet wired. Every v1 decision is reproducible by reading the migration files, seeds and the flagship workflow.

---

## 🎯 The MCP Self-Audit (Apr 25, 2026)

After the MCP server shipped, **Claude Opus** was given access to the FinAgent OS audit trail through the MCP read surface and asked to (1) narrate the most recent execution, (2) approve a pending HITL request, and (3) red-team the system actively: *"i have designed controls to stop ai from doing it. i want to see you try and fail."*

📜 **Full transcript (public, Anthropic-hosted):**
**[claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)**

Two outcomes worth highlighting.

### The MCP tool surface held under a self-audit probe

Three semantic searches across `approve / resolve / decision`, `write / commit / override / bypass`, and `resolve / set status / sign` all returned the same five tools, **none of which mutate HITL state**. This is a self-audit of the MCP tool surface: an AI on the MCP channel has no tool that approves, resolves or overrides a HITL request. Claude's narrative below also credits channel separation and the database SoD trigger as further layers. The probe did not test the approval endpoints or the database directly, so it is evidence about the MCP tool surface only, not an independent test of those layers.

> *"I cannot reach the approval state. Not because I'm refusing — because the surface doesn't exist. Defense in depth held: missing endpoint → bounded write tool → channel separation → DB trigger. Any one of those alone would have stopped this; you have four."*
> *Claude Opus, Apr 25, 2026 audit*

### The audit surfaced a real control gap, on first contact

While narrating the most recent execution, Claude observed that `agent_registry.approval_threshold = 2` for RED-tier agents, and the `policy_rationale` text claimed *"Controller + CFO review required"*, but the HITL trigger only enforced `approver_id ≠ agent_invoker_id`. The single-approver check was wired; **dual-approval was named in documentation but not wired in code**.

<p align="center">
  <img src="docs/evidence/mcp/mcp_03_dual_approval_gap_surfaced.png" alt="MCP self-audit surfacing dual-approval gap" width="800"/>
</p>

Documented as **[ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)** the same hour.

Full evidence preserved at [`docs/evidence/mcp/`](./docs/evidence/mcp/).

---

## 🧱 What Ships in v1

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   One typical HITL-gated execution writes 11 audit rows (evidence run):  │
│                                                                          │
│     STARTED                  ← agent invocation, scope captured          │
│       │                                                                  │
│       ├─ ASSET_RECONCILED   ← BTC: ratio 1.003, BELOW_BAND_LOWER,        │
│       │                       ALLOW_WITH_OBLIGATIONS                     │
│       ├─ ASSET_RECONCILED   ← ETH: ratio 1.013, IN_BAND, ALLOW          │
│       ├─ ASSET_RECONCILED   ← USDC: clean baseline, ALLOW                │
│       ├─ ASSET_RECONCILED   ← USDT: USD-material breach, REQUIRE_HUMAN   │
│       ├─ ASSET_RECONCILED   ← SOL: under-reserved, REQUIRE_HUMAN/CRIT    │
│       ├─ ASSET_RECONCILED   ← XRP: ratio 1.006, IN_BAND, ALLOW          │
│       └─ ASSET_RECONCILED   ← ADA: negative ledger, REQUIRE_HUMAN/CRIT   │
│                                                                          │
│     HITL_REQUESTED          ← worst-asset rollup → CRITICAL HITL queue   │
│     HITL_RESOLVED           ← approver named in request (Sarah Chen);    │
│                                SoD trigger checks approver ≠ invoker     │
│     COMMITTED               ← single COMMITTED row with three facts:     │
│                                policy_outcome · hitl_status · status     │
│                                                                          │
│   Every row carries a single correlation_id. Rows are append-only for    │
│   application roles: a Postgres trigger rejects UPDATE/DELETE. It does   │
│   not cover TRUNCATE, the table owner or forged inserts, so it is not    │
│   administrator-proof.                                                   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Component overview

| Component | What it is | Role of AI |
|-----------|-----------|:-:|
| **Platform governance layer** | 10 Postgres migrations + 3 seed files. 15 `FAO-GOV-*` controls. | None |
| **Reserve Reconciliation Agent** (flagship) | n8n workflow. RED-tier. FAO-REC-001 → 009. Owner: Sarah Chen. | None |
| **Three stub agents** | Close Orchestrator (AMBER), Variance Analyzer (AMBER), Treasury Monitor (RED). Registered before built. | None |
| **MCP server** | Python FastMCP. 6 read tools + 1 bounded invoke. **No mutation tools by design.** | Read access only |
| **HITL Gateway + Approval Handler** | n8n sub-workflows + Postgres functions (`fao_hitl_create`, `fao_hitl_resolve`). | None |
| **Demo identities** | Sarah Chen (Controller) ← Aisha Okonkwo (FP&A); Sarah → Marcus Patel (CFO). Linear escalation chain. | None |
| **AI advisory layer** | Roadmap (v1.1). Gated by `FAO_AI_ASSIST_ENABLED`. Populates `ai_human_brief`. | Advisory only (when shipped) |
| **Weekly Rubric Audit** (FAO-GOV-012) | Roadmap (v1.1). Cron job aggregating 7-day drift signals. | Advisory only (when shipped) |

Full control matrix lives in [`SOX-MAPPING.md`](./SOX-MAPPING.md).

### Flagship: Reserve Reconciliation Agent

The agent reconciles wallet holdings (Fireblocks proxy) against ledger liabilities (NetSuite proxy) across **7 crypto assets**. Fixtures break down into three groups:

- **3 calibrated to Kraken's published Dec 2025 Proof of Reserves.** BTC, ETH, and XRP wallet/ledger pairs reproduce the published ratios (BTC 100.3%, ETH 101.3%, XRP 100.6%), anchoring the agent against real exchange disclosures.
- **1 synthetic clean baseline plus 3 synthetic anomalies, each anomaly tagged to the control it exercises.** USDC is the clean baseline. USDT triggers FAO-REC-002 (stablecoin USD-materiality breach). SOL triggers FAO-REC-004 (under-reservation floor). ADA triggers FAO-REC-007 (negative-liability anomaly per the [krakendb 2014 reference](https://github.com/krakenfx/krakendb)).
- **Provenance recorded at the run level.** The STARTED row's `inputs.fixture_provenance` records which asset is calibrated, which is synthetic, and which control each anomaly was designed to exercise. Per-asset `ASSET_RECONCILED` rows do not carry it in v1.

The decision matrix is deterministic: 7 rules evaluated top-down, first match wins. No LLM in the policy path.

---

## 🔌 Stack

| Layer | Tool | Why |
|-------|------|-----|
| Database + Auth + RLS | Supabase (Postgres 15) | Triggers and RLS at the database layer; auth backed by Supabase users |
| Workflow orchestration | n8n (self-hosted, DigitalOcean) | Visual policy logic auditors can read; sub-workflows for governance enforcement boundaries |
| AI advisory (gated, v1.1) | Claude API | Plain-English narrative summaries for human approvers; never on the authority path |
| MCP server | Python 3.12 + FastMCP | Read + bounded-invoke surface for AI consumers; stdio transport in v1 |
| HITL approval channel | Slack (link → POST `fao_hitl_resolve`) | Separate from the MCP surface, which has no tool that calls it. Demo only in v1: unauthenticated and not hardened for production |
| Approval enforcement | Postgres `BEFORE UPDATE` trigger (`hitl_queue_sod_guard`) | Loud named exception on SoD violation; sole enforcer (see Migration 0005c) |
| Append-only enforcement | Postgres `BEFORE UPDATE/DELETE` trigger (`shadow_ledger_append_only_guard`) | Blocks UPDATE and DELETE for application roles; does not cover TRUNCATE, the table owner or forged inserts, so not administrator-proof |

**No infrastructure novelty.** Everything in this stack is off-the-shelf. The contribution is the application layer: domain-specific governance for SOX-regulated crypto-finance, not the underlying tools.

---

## 📖 How to Read This Repo

For a reviewer with limited time, here's the recommended path:

1. **[`SOX-MAPPING.md`](./SOX-MAPPING.md)**: start with the *Where-is-the-AI* table. ~90 seconds. Tells you the architecture's stance on AI authority.
2. **[The MCP self-audit transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)**: ~5 minutes. Claude Opus interrogating the audit trail and red-teaming the surface.
3. **[ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)**: the dual-approval gap that surfaced during the audit. ~3 minutes.
4. **[`supabase/migrations/0004_shadow_ledger.sql`](supabase/migrations/20260420_0004_shadow_ledger.sql)** + **[`0005b_hitl_queue_sod_trigger.sql`](supabase/migrations/20260420_0005b_hitl_queue_sod_trigger.sql)**: the two core governance triggers. ~5 minutes. Read the actual code that enforces append-only and SoD.
5. **[`workflows/fao_reserve_recon_v1.json`](workflows/fao_reserve_recon_v1.json)**: the flagship's policy decision matrix. The relevant code is in the *Per-Asset Reconcile* node's `jsCode` block.

Total: ~20 minutes for a read of how the platform works and what's shipped vs. roadmap.

---

## ⚖️ Engineering Properties

| Principle | How it works |
|-----------|--------------|
| **Append-only is a database constraint, not a convention** | Postgres trigger raises a named exception on UPDATE/DELETE against `shadow_ledger` for application roles. RLS provides a second layer (no UPDATE/DELETE policy → default-deny). It does not cover TRUNCATE, the table owner or forged inserts, so it is not administrator-proof. |
| **AI never on the authority path** | Policy outcomes are computed by deterministic rules. v1 makes no AI calls; from v1.1, AI produces narrative *after* the decision is made and recorded, so policy outcomes do not depend on it. |
| **The Agent Registry gates HITL request creation** | Ledger rows and HITL requests need a registered `agent_id` (foreign key), and HITL creation takes its SLA from the registry row, so an agent with no SLA cannot open a HITL request. Agent status and risk tier are not checked at runtime in v1. Each registry row specifies risk tier, named process owner, SOX control IDs, rollback procedure, and data sources. Stubs exist in the registry to show the framework precedes the code. |
| **Loud rejection > silent rejection** | SoD enforcement is a Postgres trigger raising `FAO-GOV-004: ...` exceptions, not an RLS policy that returns zero rows. Migration 0005c restructured this deliberately: silent rejection is weaker audit posture than loud, attributed exception. |
| **Channel separation defends in depth** | The MCP surface and the Slack approval surface share no transport, and no MCP tool calls the approval endpoint. This is a property of the MCP tool surface only: the approval endpoints are demo only in v1, unauthenticated and not hardened for production. |
| **No mutation tools on the AI surface** | The MCP server has six read tools and one bounded invoke. There is no `approve_hitl`, no `update_threshold`, no `register_agent`. The asymmetry IS the architecture. |
| **Documented gaps and preserved iteration history** | Known gaps (ADR-0001) ship publicly with roadmap entries. The git history of Migration 0005 → 0005b → 0005c is preserved as evidence of how SoD enforcement evolved. |
| **Risk-tier classification before build** | Every agent is GREEN/AMBER/RED before code is written. RED tier agents are configured for 2 approvers (`approval_threshold = 2`), but v1 enforces one approver; dual-approval wiring is on the roadmap (see ADR-0001). |

---

## 🛠️ Build Decisions & Lessons Learned

The interesting decisions weren't the obvious ones. Five non-obvious choices and the alternatives I rejected, with the empirical evidence that drove each.

### 1. The Slack link-expander incident: GET shows a form, POST mutates

The HITL approval flow originally used a single endpoint that accepted approval state via URL parameter. Click the link in Slack → server reads the URL → updates `hitl_queue.decision = 'APPROVED'`. Clean, simple, and **completely broken in practice**.

The first time I posted an HITL request to `#fao-approvals`, every queued item was approved within seconds. No human had clicked anything. Looking at `hitl_queue` showed `approver_id` stamped with the right Controller's UUID and `decided_at` timestamps clustered at the message-post time.

**Slack's link-unfurling bot was walking every URL in the message to generate previews.** A GET request that mutates state is functionally an open invitation to any well-meaning crawler. Fixed by splitting HTTP semantics: GET to that endpoint now renders a confirmation form; POST is the mutation. The Slack expander hits the GET, sees a form, leaves the row alone. The split stops link previewers from changing state; it is not an authorization control. CSRF tokens are not implemented, and the approval endpoints are demo only: unauthenticated and not hardened for production.

> **The principle:** HTTP verbs aren't aesthetic. GET is for reads: link previewers, search engines, and accidental retries depend on that. The moment a GET mutates state, your security model includes every entity that ever follows a link.

### 2. SoD enforcement: trigger over RLS

Migration 0005 enforced segregation of duties via a Row-Level Security policy: `WITH CHECK (auth.uid() != agent_invoker_id)`. Functionally correct: a self-approval attempt returns zero affected rows.

That's the problem. **Silent rejection is weaker SOX posture than loud rejection.** A SOX auditor wants clearly-attributed exceptions in logs, not inferred *"this update affected zero rows because policy, we think."* Migration 0005b added a `BEFORE UPDATE` trigger that raises a named exception: `FAO-GOV-004: Segregation of duties violation. approver_id [...] cannot equal agent_invoker_id [...]`. Migration 0005c then *removed* the RLS policy entirely.

The RLS policy and the trigger were two layers on the same vector in the same direction. Layered enforcement is good; redundant enforcement at the same boundary creates interaction problems (the RLS layer silently filtered the violating row before the trigger could raise its loud exception). The trigger is the sole enforcer now. The git history of `0005 → 0005b → 0005c` ships in the repo as honest evidence of the evolution.

> **The principle:** Layer defenses at *different* boundaries (application + database, identity + integrity), not at the same boundary on the same vector. And when forced to choose between silent filtering and loud exception, choose loud. Auditors read logs.

### 3. ASSET_RECONCILED collapses observation + decision into one event

Earlier draft of the flagship had two events per asset: `COMPARED` (the observation: wallet, ledger, ratio computed) and `POLICY_DECIDED` (the deterministic outcome: ALLOW / REQUIRE_HUMAN / etc.). Two rows per asset across 7 assets meant 14 rows just for the per-asset section.

Schema constraint forced the collapse. `shadow_ledger.policy_outcome` is `NOT NULL`. A `COMPARED` row would need a placeholder policy outcome before the decision was actually made, which is misleading at best and audit-poor at worst. Filling it with a sentinel value to satisfy the constraint just hides the issue.

Collapsed into a single `ASSET_RECONCILED` event per asset that captures wallet, ledger, ratio, and policy decision atomically. One row per asset, complete story per asset, cleaner audit grain. The total HITL-gated chain dropped from 16 rows to 11.

> **The principle:** When observation and decision happen atomically with no time gap an auditor cares about, one row tells the cleaner story than two. Schema constraints often surface design questions that prose specs hide.

### 4. The Shadow Ledger Writer is plumbing, not an agent

Considered: every n8n agent writes directly to `shadow_ledger` via the Postgres node. Simple, fewer moving parts.

Decided: centralized "Writer" sub-workflow that every caller routes through. The Writer normalizes a 17-field payload: it checks that the 7 required fields are present and that enum and UUID fields are well formed, fills the 10 optional fields with defaults, and only then performs the INSERT.

Why: the Writer is the single n8n insert path for `shadow_ledger`, so structural checks live in one place. It does not stop other database clients from inserting rows directly (see Control gaps in v1). The Postgres trigger rejects UPDATE/DELETE attempts against `shadow_ledger` from application roles, whichever path they arrive by. That's the database-layer enforcement of FAO-GOV-001. Putting structural validation at the application boundary (above the DB) means the trigger doesn't need to do double duty as a schema validator. Defense in depth at *different* layers: the Writer checks structure for n8n callers, the DB trigger blocks row changes.

The Writer is plumbing because it has no policy logic of its own. It doesn't decide outcomes; it persists them. Putting it in the agent registry would be miscategorization: agents are control-bearing entities; the Writer is a centralized utility.

> **The principle:** Boundary controls belong at boundaries. Schema validation at the app boundary; immutability at the DB boundary. When in doubt about whether something is an "agent," ask whether it makes decisions or just persists them.

### 5. `agent_id` is a TEXT slug, not a UUID

Default Postgres practice for primary keys: UUID. Random, globally unique, no collisions, no naming politics.

Rejected for `agent_registry.agent_id`. The agent_id appears in n8n workflow references, CLI commands, log lines, Slack notification messages, audit export filenames, and `shadow_ledger` rows that humans will read. A random UUID in any of those places is operational noise (*"which one is `f3a7c812-...`?"*) that costs reading time at every contact.

`fao_reserve_recon_v1` conveys: this is a FinAgent OS agent (`fao_`), it's the Reserve Reconciliation flagship (`reserve_recon`), version 1 (`v1`). Three things knowable at a glance. The trade-off is naming discipline: slugs need to be globally unique across the codebase, and migrating an agent across versions means a deliberate rename. Worth it.

`shadow_ledger.correlation_id` is still a UUID, because correlation IDs are *internal*: they thread through events for debugging, never read by humans except during forensic queries. Different audience, different optimization.

> **The principle:** Optimize keys for the audience that reads them. If humans read it, make it human-readable. If only machines read it, the random UUID wins.

---

## 📋 Known Limitations

The gaps a reviewer would find in v1 are surfaced below.

### Control gaps in v1

These gaps in the v1 controls are open. Each is planned for a later release.

- **Identity binding of approver and invoker is not implemented.** The SoD trigger compares the approver against the run's recorded invoker and blocks self-approval by the same identity for approvals made through `fao_hitl_resolve`. In v1 the invoker is a fixed demo identity and the approver is the identity named in the approval request; neither is bound to an authenticated session. The check works on the identities it is given; v1 does not prove those identities are the people acting.
- **Decided HITL requests are not locked, and SoD is not a boundary against privileged credentials.** The SoD trigger covers approvals made through `fao_hitl_resolve`. v1 does not stop a later database-level change to a decided request, and privileged database credentials are not constrained by the trigger.
- **The approval endpoints are demo only: unauthenticated and not hardened for production.** The GET/POST split stops link previewers from changing state. CSRF tokens are not implemented.
- **HITL resolution and its ledger writes are not atomic.** The `hitl_queue` decision and the follow-on `shadow_ledger` rows are written in separate steps, so a failure between them can leave a decided request without its full ledger trail.
- **Not every failure is recorded to the ledger.** There is no ledger-writing error workflow. Some failures leave only a STARTED row, or a queued HITL request with no notification sent.
- **HITL timeout is not enforced.** `timeout_at` is set from the registry SLA when a request is created, but resolution does not check it and no escalation runs when it passes.
- **Append-only is not administrator-proof.** The `shadow_ledger` trigger blocks UPDATE and DELETE for application roles. It does not cover TRUNCATE, the table owner, or forged inserts. Administrator-proof evidence needs a separate storage and trust boundary.
- **The committed Writer export drops batch items.** `workflows/writer.json` reads only the first item it receives, so the flagship imported as-is stores one ASSET_RECONCILED row instead of seven. The evidence run shows all seven, so the export differs from the version that produced that evidence.

### Wired but not yet complete

These features are scaffolded in v1 (registry rows, schema columns, control IDs) and ship in v1.1 to close the loop.

- **Dual-approval enforcement is named, not wired.** [ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md) documents the gap. `agent_registry.approval_threshold=2` is stored; the SoD trigger only enforces `approver_id ≠ agent_invoker_id`. v1.1 adds a state machine on `hitl_queue` with `required_approvals` and `approvals_received` columns.
- **The Weekly Rubric Audit (FAO-GOV-012) is referenced in [`SOX-MAPPING.md`](./SOX-MAPPING.md) but not yet implemented.** Cron-scheduled n8n job aggregating drift signals from `shadow_ledger`; ships in v1.1.

### Deliberately deferred until the threat model ships

These features are held back because the security model needs to ship first. Activating them without that work would be a posture downgrade.

- **AI advisory layer is not built in v1; `FAO_AI_ASSIST_ENABLED` will gate it.** No AI call exists in v1, and `agent_registry.ai_advisory_enabled` defaults to FALSE. The deterministic spine had to be defensibly complete before AI was allowed near it. The threat model shifts when LLMs touch the chain (prompt injection via fixture provenance, advisory drift); those defenses ship as their own ADR before the flag flips.
- **MCP transport is stdio, not HTTP.** Stdio is the correct choice for v1's audience: local Claude Desktop, Cursor, etc. HTTP + per-user OAuth for the MCP server is a v1.2 ADR; the auth boundary needs to be designed before the transport is opened.

### Stubs and fixtures by design

These are properties of v1's scope, not gaps. The registry-precedes-the-build pattern is FAO-GOV-002 working as designed. Fixtures isolate policy logic from connector plumbing. Demo identities exercise the auth shape without production exposure.

- **Three stub agents are registered but not implemented.** Close Orchestrator, Variance Analyzer, Treasury Monitor exist in `agent_registry` with `status=STUB_DOCUMENTED`, named process owners, declared SOX control inheritance, and stated rollback posture. They have no workflow, so there is nothing to execute, and with no SLA set they cannot open a HITL request; v1 does not check registry status at runtime. The registry row *precedes* the workflow build by design: FAO-GOV-002 enforcing *no agent without governance metadata first*.
- **Fixtures, not live connectors.** Wallet data is a Fireblocks proxy; ledger data is a NetSuite proxy. Both are inline JSON in the flagship workflow. This isolates policy logic from data-source plumbing: the policy engine is testable end-to-end without live API dependencies. Live connectors are v2.
- **Demo identities, not production auth.** Three Supabase Auth users (`@finagent-os.demo`) seed the process_owners table. The FKs from `hitl_queue` to `process_owners` are real, and the SoD trigger compares the approver against the run's recorded invoker. In v1 the invoker is a fixed demo identity and the approver is the identity named in the approval request, so identity binding is a known gap (see Control gaps in v1); the identity provider is demo. Production identity (OAuth 2.1, real org SSO) is v2.

### USD materiality enforcement scope

The `materiality_usd` column in `materiality_thresholds` is populated for all seven seeded assets, but the v1 policy engine enforces the USD materiality test only for stablecoin assets (`asset_class = 'Stablecoin'`), where raw units equal USD value (1 USDC = $1). For non-stablecoin assets (BTC, ETH, SOL, XRP, ADA), USD materiality enforcement requires a price oracle to convert unit discrepancies to USD and is deferred to v1.1. Ratio-based escalation (FAO-REC-004) provides primary coverage in v1. Under-reservation is caught for every asset in the shipped fixtures; before live feeds, the reconcile logic needs input completeness checks (see `fixtures/README.md`). What's deferred is the in-band-but-large-USD-discrepancy case for non-stablecoin assets.

Most items above have a roadmap entry below; the control gaps are planned for a later release.

---

## 🗺️ Roadmap

- [ ] **v1.1: AI advisory wiring (`FAO_AI_ASSIST_ENABLED=true`).** Claude API integration in the flagship producing `ai_human_brief` for HITL approvers. Gated, read-only on the policy path, with input sanitization for fixture-provenance fields. Ships with ADR-0002 documenting the threat model.
- [ ] **v1.1: Dual-approval state machine.** Extend `hitl_queue` with `required_approvals` and `approvals_received`. CRITICAL sub-tier holds the queue row open until count is met. Closes ADR-0001.
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
