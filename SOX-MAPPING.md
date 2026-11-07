# SOX Control Mapping

**Purpose:** Map every architectural pattern in FinAgent OS to its corresponding SOX control type, COSO framework component, and explicit AI authority level.

**Scope:** This document is the source of truth for how FinAgent OS maintains control integrity in a SOX-regulated financial environment. It is referenced by the Agent Registry (`sox_control_ids`) and the agent workflows. A separate Risk Matrix document is planned.

**Author:** Rizwan Ahmed, ACCA · Velocyt Consulting
**Status:** v1.0, April 2026

---

## Core Principle

> **AI is optional and non-authoritative. Policy decisions are deterministic. Every material financial decision is enforced by deterministic rules, not by model output. AI assists human judgment at the classification boundary; AI never has final authority over a control outcome.**

This principle is inherited from the ATLAS governance plane pattern and adapted to finance-specific controls. It answers the first question a SOX auditor asks about any AI-enabled workflow: *can an LLM hallucination cause a control to pass when it should have failed?* The answer in FinAgent OS is: no, because the control outcome is not produced by the LLM. The LLM produces advisory input; the policy engine produces the outcome.

---

## The "Where is the AI?" Table

Before the control mapping, an explicit answer to which components use AI and which do not.

| Component | Role of AI | Authority |
|-----------|-----------|-----------|
| Wallet-Ledger Comparison (Reserve Reconciliation Agent) | ❌ None. Deterministic arithmetic. | N/A |
| Materiality Threshold Check | ❌ None. Deterministic rules. | N/A |
| Risk Tier Classification (agents) | ❌ None. Database-resident config (Supabase). | N/A |
| Risk Tier Classification (outcomes) | ❌ None. Deterministic policy table. | N/A |
| Segregation of Duties Check | ❌ None. Identity comparison. | N/A |
| Shadow Ledger Write | ❌ None. Append-only persistence. | N/A |
| HITL Routing Decision | ❌ None. Run rollup policy outcome → deterministic route. `approval_threshold` is not read in v1 (see ADR-0001). | N/A |
| Reserve Ratio Computation | ❌ None. Deterministic arithmetic. | N/A |
| Policy Outcome (ALLOW / ALLOW_WITH_OBLIGATIONS / REQUIRE_HUMAN / DENY / BLOCKED) | ❌ None. Deterministic policy rules. | N/A |
| Discrepancy Classification (CLEAN / BENIGN_TIMING / ANOMALY / MATERIAL) | ⚠️ AI advisory | Advisory only. Final classification is validated by deterministic rules before policy engine consumes it. |
| Human Approval Brief (summary presented to human reviewer at HITL gate) | ⚠️ AI advisory | Advisory only. Does not alter the policy outcome or bypass the approval requirement. |
| Weekly Rubric Refinement Proposals | ⚠️ AI advisory | Advisory only. All proposed changes require human approval before deployment. |
| Journal Entry Draft Generation (stub: Close Orchestrator) | ⚠️ AI advisory | Advisory only. Planned: every drafted entry will pass through materiality gates, segregation-of-duties checks, and human review before posting. |

**Key property:** in v1 no component calls an LLM, so FinAgent OS runs fully deterministically: every comparison, threshold, and policy rule fires without AI input. The four AI-advisory rows above are planned for v1.1. The runtime switch `FAO_AI_ASSIST_ENABLED` is not built yet: nothing in v1 reads it, and `agent_registry.ai_advisory_enabled` defaults to FALSE but is not checked at runtime. AI is designed to be additive to human judgment, not a replacement for deterministic controls.

**v1 ships with AI advisory off.** The deterministic backbone (wallet-ledger comparison, per-asset materiality and ratio evaluation, policy outcome engine, same-identity self-approval block, append-only audit table, correlation threading, registry checks at HITL creation, and the MCP read surface) is wired. **Of the 24 controls in this document, 8 are live in v1, 10 are partial and 6 are planned.** Partial means part of the stated control is implemented and the rest is not; each row says which part. The 6 planned controls (`Planned (v1.1)`) cover AI-advisory features (FAO-REC-005, FAO-REC-009, FAO-GOV-010, FAO-GOV-011, FAO-GOV-012) and the rollback engine (FAO-GOV-005). The AI-advisory controls activate only after the AI switch is built and turned on, and that happens only after the AI threat model ships as its own ADR. This sequencing (deterministic spine first, AI advisory gated behind a flag and a published threat model) is deliberate. The deterministic ground truth has to be defensibly complete before AI is allowed near it.

---

## Control Type Definitions

For reference, because auditors and engineers use these terms differently.

| Type | Definition | Example in FinAgent OS |
|------|-----------|------------------------|
| **Preventive** | Stops an event from occurring. | HITL gate: a REQUIRE_HUMAN run is not committed until an approval or rejection is recorded through the approval webhook. |
| **Detective** | Identifies an event after it has occurred. | Shadow Ledger: each completed run records STARTED, one ASSET_RECONCILED event per asset, and COMMITTED in an append-only table. |
| **Monitoring** | Continuously observes the operation of other controls. | 5% randomized QA audit sampling agent outputs against their inputs (planned, v1.1). |
| **Corrective** | Reverses or mitigates the effect of an event. | Rollback Engine: staged changes can be reverted on failure or HITL rejection (planned, v1.1). |

COSO 2013 components referenced: (1) Control Environment, (2) Risk Assessment, (3) Control Activities, (4) Information & Communication, (5) Monitoring Activities.

---

## Architectural Pattern → Control Mapping

Every pattern in FinAgent OS has a Control ID in the format `FAO-XXX-NNN` where `XXX` is the governance area:

- `FAO-GOV`: Governance layer (platform-wide controls)
- `FAO-REC`: Reserve Reconciliation Agent
- `FAO-CLS`: Close Orchestrator (stub)
- `FAO-VAR`: Variance Analyzer (stub)
- `FAO-TRE`: Treasury Monitor (stub)

### Platform Governance Controls (FAO-GOV)

| Control ID | Pattern | Type | COSO | AI Authority | Status | Implementation |
|------------|---------|------|------|--------------|--------|----------------|
| **FAO-GOV-001** | Shadow Ledger immutable audit trail | Detective | Information & Communication | None | Partial | Postgres table in Supabase with an append-only guard: a row-level trigger rejects every UPDATE and DELETE. A completed run writes STARTED on entry, one ASSET_RECONCILED record per asset, and COMMITTED on exit; a REQUIRE_HUMAN run also records HITL_REQUESTED, and the approval handler writes HITL_RESOLVED and COMMITTED after the decision. The HITL decision and those ledger events are written in separate steps, not one transaction. v1 has no error workflow, so a run that fails mid-way can leave only its STARTED record and no FAILURE row. The exported `workflows/writer.json` processes only the first item of a batch; the evidence screenshot shows all seven per-asset rows, so the export differs from the version that produced that evidence. Auto-incrementing `ledger_id` as primary key. Every write includes `correlation_id`. Append-only against UPDATE and DELETE is a database constraint, not an application convention; it does not validate inserted rows and is not an administrator-proof boundary. |
| **FAO-GOV-002** | Agent Registry (formalized control population) | Preventive | Control Activities | None | Partial | Postgres table (`agent_registry`) in Supabase with foreign keys to `process_owners`. The registry gates HITL creation: `hitl_queue.agent_id` is a foreign key to the registry, and `fao_hitl_create` refuses an agent with no registry row or no SLA, and takes the request timeout from the registry SLA. Registry status and risk tier are not enforced at runtime in v1: the flagship workflow sets its own `agent_id` and risk tier and does not read the registry before it executes. |
| **FAO-GOV-003** | Risk-Tier Classification (GREEN/AMBER/RED/BLOCKED) | Preventive | Risk Assessment | None | Partial | Every agent has a `risk_tier` on `agent_registry` (Supabase); a CHECK constraint forbids BLOCKED as an agent's operating tier, since BLOCKED is reserved for policy outcomes. In v1 the tier is recorded, not enforced: the flagship sets RED in code, the HITL request takes its tier from the caller, and `approval_threshold` is not read by any code path (see [ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)). |
| **FAO-GOV-004** | HITL Gateway with segregation-of-duties enforcement | Preventive | Control Activities | None | Partial | n8n sub-workflow plus Postgres `BEFORE UPDATE` trigger (`hitl_queue_sod_guard`). For approvals made through `fao_hitl_resolve`, the trigger blocks same-identity self-approval: when the approver identity equals the recorded invoker identity, it raises a named `FAO-GOV-004` exception and the transaction aborts. The trigger is not a boundary against privileged database credentials, and decided requests are not locked against later changes at the database level (known gaps, planned for a later release). Identity binding of invoker and approver is a known gap in v1: the invoker is a fixed demo identity set by the workflow, and the approver identity comes from the approval request, so the trigger compares recorded identities, not authenticated people. The approval endpoints are demo only: unauthenticated and not hardened for production; identity binding is planned for a later release. Migration 0005c removed the original RLS-policy enforcement so the trigger is the sole SoD check. A rejected self-approval returns an error page and is not written to the Shadow Ledger. Loud named exception is stronger SOX posture than silent zero-row update. v1 enforces single-approver SoD; multi-approver thresholds (see [ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)) ship in v1.1. |
| **FAO-GOV-005** | Rollback Engine (Break / Commit / Rollback) | Corrective | Control Activities | None | Planned (v1.1) | Staging area pattern. Agents will write intended changes to staging; commit only on successful HITL approval; revert staged changes on failure or rejection. v1 logs ROLLED_BACK as the `execution_status` of the COMMITTED event when a HITL request is rejected, but nothing is staged or reverted; the staging-area workflow ships in v1.1. |
| **FAO-GOV-006** | Database-First Vault Capture | Preventive | Control Activities | None | Partial | The STARTED record is written to Postgres (Supabase) before reconciliation runs, and each ASSET_RECONCILED record stores that asset's wallet and ledger balances. v1 makes no LLM calls. Full upfront raw capture is not achieved: the raw wallet and ledger input sets carried with the STARTED payload are dropped by the Writer's normalization, so a failure before the per-asset writes can lose the inputs. |
| **FAO-GOV-007** | Webhook-Gated State Progression | Preventive | Control Activities | None | Live | State transitions blocked until external confirmations are received. v1 implements this for approvals in the workflows: the run's HITL_RESOLVED and COMMITTED events are written only by the approval handler after `fao_hitl_resolve` moves the request from PENDING to a decision. The `hitl_queue` table itself does not restrict decision changes to that path (see FAO-GOV-004). Payment webhooks and scheduled cron confirmations are not part of v1. The approval endpoints are demo only: unauthenticated and not hardened for production. |
| **FAO-GOV-008** | Correlation ID threading | Detective | Information & Communication | None | Live | Every agent invocation generates a UUID `correlation_id`. All Shadow Ledger entries, HITL requests, approval records, and downstream events carry the same ID. Enables end-to-end audit trace from trigger to outcome. |
| **FAO-GOV-009** | Policy Outcome vocabulary (ALLOW / ALLOW_WITH_OBLIGATIONS / REQUIRE_HUMAN / DENY / BLOCKED) | Preventive | Control Activities | None | Live | Every completed run records one rollup policy outcome on its COMMITTED row, and each asset gets one per-asset outcome. Outcomes are deterministic: computed by rules, not generated by LLM. A run that fails mid-way may record no rollup outcome (see FAO-GOV-001). |
| **FAO-GOV-010** | 5% Randomized QA Audit sampling | Monitoring | Monitoring Activities | None | Planned (v1.1) | Sampling job will select 5% of agent executions per week. Process Owner reviews each sample: input, AI advisory (if present), policy outcome, match to expected. Deviations logged and drive rubric refinements. |
| **FAO-GOV-011** | Fractional API Cost Tracking | Monitoring | Monitoring Activities | None | Planned (v1.1) | Every AI advisory call will log prompt tokens, completion tokens, and USD cost (6-decimal precision) to Shadow Ledger. Schema columns (`ai_prompt`, `ai_output`, `ai_confidence`, `fractional_cost_usd`) exist and are NULL across all v1 rows; population begins when `FAO_AI_ASSIST_ENABLED=true` ships. |
| **FAO-GOV-012** | Closed-Loop Rubric Refinement with HITL Gate | Monitoring + Segregation of Duties | Monitoring Activities | Advisory | Planned (v1.1) | Weekly audit job will aggregate outcomes, flag anomalies where AI advisory diverged from human decision, propose rubric changes. All changes require human approval before deployment. AI proposes; human disposes. |
| **FAO-GOV-013** | Process Owner Named on Every Agent | Preventive | Control Environment | None | Live | Agent Registry schema requires a foreign key to `process_owners`: an authenticated identity record, not a free-text string. Every registry row, and so every agent that writes to the Shadow Ledger, has a named Process Owner. This addresses the named-Process-Owner part of the governance requirement *"No build goes to production without a named Process Owner, documented data flows, access controls, and audit logging confirmed."*; the access-control and audit-logging parts are only partly met in v1 (see FAO-GOV-001 and FAO-GOV-004). |
| **FAO-GOV-014** | AI Disabled by Default | Preventive | Control Environment | None | Partial | AI advisory is off in v1: no workflow calls an LLM, and `agent_registry.ai_advisory_enabled` defaults to FALSE. The runtime switch is not built: nothing in v1 reads `FAO_AI_ASSIST_ENABLED` or checks `ai_advisory_enabled` at runtime. Enabling AI is not yet a logged configuration change: v1 has no change log or automatic `updated_at` maintenance for registry rows. |
| **FAO-GOV-015** | MCP Tool Surface (Read + Bounded Invoke; No Governance Mutation) | Preventive | Control Activities | None | Live | Python FastMCP server ([`mcp/server.py`](mcp/server.py)) exposing 6 read tools and 1 bounded invoke tool. There is deliberately no `approve_hitl`, no `update_threshold`, no `register_agent`. AI consumers can read the audit trail and call the invoke tool; the tool surface offers no tool that mutates governance state. Asymmetry enforced at the tool surface only: the server's database credential is not yet a read-only role (planned for v1.2). The committed flagship export has only a manual trigger, so the webhook the invoke tool calls is not included in the exported workflows. Self-audit of the MCP tool surface on Apr 25, 2026, via Claude Opus: three semantic searches across approve/resolve/decision/write/commit/override/bypass keywords returned the same five tools (four read tools and `invoke_reserve_recon`), none of which mutates HITL state. The self-audit covered tool discovery only; it did not test the approval layer, its authentication, or database authorization. See [`mcp/README.md`](mcp/README.md) and the [self-audit transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960). |

### Reserve Reconciliation Agent Controls (FAO-REC)

| Control ID | Pattern | Type | COSO | AI Authority | Status | Implementation |
|------------|---------|------|------|--------------|--------|----------------|
| **FAO-REC-001** | Wallet-Ledger Balance Comparison | Detective | Information & Communication | None | Live | Per-asset deterministic arithmetic: `discrepancy = wallet_balance - ledger_liability`. No AI. |
| **FAO-REC-002** | Per-Asset Materiality Threshold Evaluation | Preventive | Control Activities | None | Live | For stablecoin assets: if \|wallet − ledger\| > materiality_usd AND ratio is within band → REQUIRE_HUMAN STANDARD. Deterministic rule. v1 limitation: non-stablecoin USD materiality deferred pending price oracle integration; FAO-REC-004 ratio check provides primary coverage. See README Limitations. |
| **FAO-REC-003** | Reserve Ratio Computation | Detective | Information & Communication | None | Partial | `reserve_ratio = wallet_balance / ledger_liability` per asset. No AI. An aggregate ratio across assets is not computed in v1; it needs a defined scope, a common valuation and a floor before it can be built. |
| **FAO-REC-004** | Reserve Ratio Threshold Check | Preventive | Control Activities | None | Partial | If an asset's `reserve_ratio` is below its configured `ratio_floor` (1.00 for every seeded asset), that asset's policy outcome = REQUIRE_HUMAN CRITICAL. Deterministic rule; no AI input exists in v1. The aggregate floor check is not implemented in v1: no aggregate floor is configured or evaluated. See FAO-REC-006 for a v1 limit on how mixed runs are routed. |
| **FAO-REC-005** | AI Discrepancy Advisory Classification | Detective | Information & Communication | Advisory | Planned (v1.1) | When `FAO_AI_ASSIST_ENABLED=true`, LLM produces advisory classification (CLEAN / BENIGN_TIMING / ANOMALY / MATERIAL) with reasoning. Classification is input to FAO-REC-006, never the output. v1 ships with the flag off. `ai_prompt`, `ai_output`, `ai_confidence` columns are NULL across all v1 rows; the deterministic policy engine runs without AI input. |
| **FAO-REC-006** | Policy Outcome Engine | Preventive | Control Activities | None | Partial | Deterministic function: given materiality check (FAO-REC-002), ratio check (FAO-REC-004), and (when enabled) AI advisory (FAO-REC-005), compute one of: ALLOW (auto-log only), ALLOW_WITH_OBLIGATIONS (log + weekly review), REQUIRE_HUMAN (HITL gate), DENY (rejected with reason), BLOCKED (never auto-proceeds, full investigation required). Per-asset outcomes are computed as stated. v1 limits: no v1 rule produces DENY; BLOCKED is produced when an asset has no configured threshold. The run takes its worst per-asset outcome, so a BLOCKED or DENY asset makes the run's COMMITTED record BLOCKED or DENY with status FAILURE, and no HITL request is raised for other escalated assets in that run. This path is not reached with the current seeds, where every asset has a threshold. |
| **FAO-REC-007** | Negative-Balance Anomaly Detection | Detective | Information & Communication | None | Live | Per Kraken's own 2014 PoR reference implementation (`krakendb`), "large negative values" at leaf nodes require investigation. Agent flags any negative ledger liability as REQUIRE_HUMAN CRITICAL. Deterministic rule. |
| **FAO-REC-008** | Audit Evidence Package Generation | Detective | Information & Communication | None | Partial | Each run writes correlated, timestamped JSON records to the Shadow Ledger: STARTED, one ASSET_RECONCILED record per asset (balances, ratio, threshold, policy outcome and rationale), and COMMITTED with the per-asset summary. v1 has no step that assembles these into one self-contained evidence package; the records are retrieved by `correlation_id`. AI advisory fields are NULL in v1. |
| **FAO-REC-009** | Human Approval Brief (AI Advisory) | Monitoring | Monitoring Activities | Advisory | Planned (v1.1) | When policy outcome = REQUIRE_HUMAN and `FAO_AI_ASSIST_ENABLED=true`, LLM generates a plain-English brief summarizing the discrepancy, the AI advisory classification, and the reasons for escalation. Brief is attached to the HITL request via `hitl_queue.ai_human_brief`. Does not alter policy outcome or substitute for human judgment. v1 ships with the column NULL across all rows; the deterministic `policy_rationale` is rendered to approvers as the authoritative source. |

### Stub Module Controls (FAO-CLS, FAO-VAR, FAO-TRE)

These stubs have Agent Registry rows and are designed to inherit the `FAO-GOV-*` controls as they are implemented. The stub folders are placeholders in v1; module-specific controls will be documented in a `README.md` per stub (planned) and will populate this table as modules are implemented.

| Module | Risk Tier | Primary Control Types | Production Target |
|--------|-----------|----------------------|-------------------|
| Close Orchestrator (stub) | AMBER | Preventive (materiality gates) + Detective (checklist completion) | NetSuite + BlackLine |
| Variance Analyzer (stub) | AMBER | Monitoring (period-over-period flux) | NetSuite + internal data warehouse |
| Treasury Monitor (stub) | RED | Detective (position monitoring) + Preventive (liquidity threshold alerts) | Kyriba + Fireblocks |

**Reserve Reconciliation Agent (flagship) is RED tier.** Rationale: its outputs inform the quarterly Proof of Reserves attestation, a published regulatory-adjacent artifact. A material discrepancy that escapes the HITL gate would reach publication. A per-agent risk matrix (`docs/RISK-MATRIX.md`) is planned.

---

## Governance Requirements Crosswalk

The governance requirements typical of an AI-agent platform in a SOX-regulated financial environment fall into seven dimensions. Each maps to one or more controls above.

| Governance Requirement | FinAgent OS Controls |
|-----------------------|---------------------|
| Data classification | FAO-GOV-002 (Agent Registry declares data sources per agent, production targets named: Fireblocks, NetSuite, Kyriba) |
| Auditability | FAO-GOV-001 (Shadow Ledger), FAO-GOV-008 (correlation ID threading), FAO-REC-008 (audit evidence package) |
| Human-in-the-loop checkpoints | FAO-GOV-004 (HITL Gateway), FAO-REC-006 (policy outcome engine routing to REQUIRE_HUMAN) |
| Failure detection | FAO-GOV-001 (BLOCKED and DENY runs are committed to the Shadow Ledger with status FAILURE; v1 has no error workflow, so a run that fails mid-way can leave only its STARTED record), FAO-GOV-005 (Rollback Engine triggered on failure, planned v1.1) |
| Rollback mechanisms | FAO-GOV-005 (Break/Commit/Rollback staged changes) |
| Regulatory compliance | Every control above maps to a SOX control type and COSO component |
| Audit-ready design documentation | This document, the root `README.md`, and the decision records in [`docs/adr/`](docs/adr/). `docs/ARCHITECTURE.md` and `docs/AGENT-GUIDE.md` are planned. |

**Risk-tier-before-build requirement.** A common requirement in this domain: *"Classify all automation builds by risk tier before work begins. No build goes to production without a named Process Owner, documented data flows, access controls, and audit logging confirmed."* This is addressed in part by FAO-GOV-002 + FAO-GOV-003 + FAO-GOV-013 + FAO-GOV-001. The registry schema requires a named Process Owner and a risk tier for every agent, and a HITL request cannot be created for an agent without a registry row and SLA. In v1 the registry is not checked before a workflow executes, and status and tier are not enforced at runtime.

---

## Testing and Attestation

A control catalog without a testing plan is documentation, not assurance. The plan below names who tests each class of control, with what cadence, and what evidence is preserved.

| Control class | Test method | Cadence | Evidence preserved |
|---|---|---|---|
| Database-level enforcement (FAO-GOV-001 append-only, FAO-GOV-004 SoD) | Adversarial probe: attempt UPDATE/DELETE on `shadow_ledger`, attempt self-approval via `fao_hitl_resolve` | Each migration to either table; before any release | Failing query + raised exception captured to `docs/evidence/`; one row per probe |
| Application-layer validation (FAO-GOV-006 vault capture, Shadow Ledger Writer 17-field contract) | Test harnesses ([`workflows/test_writer_harness_multi_item.json`](workflows/test_writer_harness_multi_item.json), [`workflows/test_hitl_gateway_harness.json`](workflows/test_hitl_gateway_harness.json)) (the Writer harness currently has no working negative case; see `workflows/README.md`) | Before each n8n workflow change | n8n execution log linked to the relevant correlation_id |
| MCP tool surface (FAO-GOV-015) | Self-audit via Claude Opus or equivalent: semantic search of the MCP tool list across mutation-intent keywords; attempted HITL approval through the MCP tools. Covers the tool surface only, not the approval endpoints or database authorization | Each MCP server release | Transcript + screenshots in [`docs/evidence/mcp/`](docs/evidence/mcp/) |
| Per-asset reconciliation rules (FAO-REC-001 through 008) | Fixture replay against current Kraken Dec 2025 PoR + 3 synthetic anomalies; ratios and policy outcomes must match the documented expected values | Before each flagship workflow change | `shadow_ledger` rows for the test correlation_id |
| Process Owner accountability (FAO-GOV-013) | Attestation review: each Process Owner signs off on the controls they own | Quarterly, per process owner | Signed attestation in `docs/attestations/` (v1.1; not captured in v1: v1 history is direct commits with no PR review record) |

**External attestation roadmap.** v1 ships without external attestation: the testing posture above is internal to the build. SOC 2 Type 1 (point-in-time) is feasible at v1.2 once the read-only Postgres role and OAuth-bound MCP transport ship. SOC 2 Type 2 (operating effectiveness over a period) requires 3 to 6 months of operational evidence and is feasible from v2 onwards once live connector data flows through the pipeline. SOC 2 reports against the trust services criteria (such as security); it is not an ICFR report. A SOC 1 report would be the ICFR-relevant one if FinAgent OS is offered as a service to entities that rely on it for financial reporting.

---

## Prior Art and Acknowledgements

FinAgent OS does not exist in a vacuum. The governance-first design is informed by publicly available prior art in the agentic AI and financial controls space:

- **[ATLAS (`quantumlayer-atlas/atlas`)](https://github.com/quantumlayer-atlas/atlas)**: the first principle that AI should be optional and non-authoritative in policy decisions. The "Where is the AI?" table format at the top of this document is adapted from their approach.
- **[Kraken's own `krakendb` (Payward, 2014)](https://github.com/krakenfx/krakendb)**: the PoR hash scheme reference, the canonical operational concern about negative-balance leaves, and the principle that external verification is necessary for trust.
- **[Kraken's `kraken-cli`](https://github.com/krakenfx/kraken-cli)**: the *AI-native* framing applied to a Kraken-shipped trading system, the convention of dedicated agent-facing root documentation alongside the human README, the structured-JSON output discipline at workflow boundaries, and the MCP-server-as-first-class-component design pattern. The discovery of OpenClaw as prior art happened through their documentation.
- **[Dewale-A's `Agentic-Accounting-Close`](https://github.com/Dewale-A/Agentic-Accounting-Close)**: the concrete dollar-threshold materiality gate pattern and the approach of enforcing segregation of duties at the API boundary rather than as documentation.
- **[OpenClaw Airlock (`tushar5623/OpenClaw_Airlock`)](https://github.com/tushar5623/OpenClaw_Airlock)**: the GREEN/AMBER/RED/BLOCKED risk tier vocabulary and the per-action decision matrix pattern.
- **COSO 2013 Internal Control: Integrated Framework**: the five-component structure every control maps to.

Adopted prior-art patterns are cited above. FinAgent OS extends them by applying governance-first architecture to crypto-native financial infrastructure. Decision records are in [`docs/adr/`](docs/adr/); v1 has one, ADR-0001.

---

## Change Control

This document is versioned in git. **In v1**, changes are direct commits by the single author; v1 history has no pull requests and no PR review record. The intended process, planned for when a second reviewer is in place, routes changes through a git pull request with named sign-off from the Process Owner of any control whose row is touched, plus a separate sign-off from the document's author, recorded in the PR's review log. **In v1.1**, changes additionally route through the Rubric Refinement Gate (FAO-GOV-012): the weekly audit job aggregates outcomes, flags drift between AI advisory and human decisions, and proposes rubric changes which are then subject to the same PR + sign-off workflow. Historical versions in git provide the audit trail of how this document has evolved. Database configuration (materiality thresholds and registry rows) has no change log or automatic `updated_at` maintenance in v1.

**v1.0, April 2026.** Initial publication.

**November 2026.** Control statuses and implementation text corrected to match the v1 code after two external reviews.
