# SOX Control Mapping

**Purpose:** Map every architectural pattern in FinAgent OS to its corresponding SOX control type, COSO framework component, and explicit AI authority level.

**Scope:** This document is the source of truth for how FinAgent OS maintains control integrity in a SOX-regulated financial environment. It is referenced by the Agent Registry, the Risk Matrix, and every agent workflow.

**Author:** Rizwan Ahmed, ACCA · Velocyt Consulting
**Status:** v1.0 — April 2026

---

## Core Principle

> **AI is optional and non-authoritative. Policy decisions are deterministic. Every material financial decision is enforced by deterministic rules, not by model output. AI assists human judgment at the classification boundary; AI never has final authority over a control outcome.**

This principle is inherited from the ATLAS governance plane pattern and adapted to finance-specific controls. It answers the first question a SOX auditor asks about any AI-enabled workflow: *can an LLM hallucination cause a control to pass when it should have failed?* The answer in FinAgent OS is: no — because the control outcome is not produced by the LLM. The LLM produces advisory input; the policy engine produces the outcome.

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
| HITL Routing Decision | ❌ None. Risk tier + approval threshold → deterministic route. | N/A |
| Reserve Ratio Computation | ❌ None. Deterministic arithmetic. | N/A |
| Policy Outcome (ALLOW / ALLOW_WITH_OBLIGATIONS / REQUIRE_HUMAN / DENY / BLOCKED) | ❌ None. Deterministic policy rules. | N/A |
| Discrepancy Classification (CLEAN / BENIGN_TIMING / ANOMALY / MATERIAL) | ⚠️ AI advisory | Advisory only. Final classification is validated by deterministic rules before policy engine consumes it. |
| Human Approval Brief (summary presented to human reviewer at HITL gate) | ⚠️ AI advisory | Advisory only. Does not alter the policy outcome or bypass the approval requirement. |
| Weekly Rubric Refinement Proposals | ⚠️ AI advisory | Advisory only. All proposed changes require human approval before deployment. |
| Journal Entry Draft Generation (stub: Close Orchestrator) | ⚠️ AI advisory | Advisory only. Every drafted entry passes through materiality gates, segregation-of-duties checks, and human review before posting. |

**Key property:** disabling AI entirely (`FAO_AI_ASSIST_ENABLED=false`) does not disable FinAgent OS. The system continues to operate deterministically — every comparison, threshold, and policy rule still fires. AI is additive to human judgment, not a replacement for deterministic controls.

**v1 ships with `FAO_AI_ASSIST_ENABLED=false`.** The deterministic backbone — wallet-ledger comparison, materiality evaluation, ratio thresholds, policy outcome engine, SoD enforcement, immutable audit, correlation threading, agent registry gating, and the MCP read surface — is fully wired and active. **Of 24 controls in this document, 18 are live in v1.** The 6 controls marked `v1.1` cover AI-advisory features (FAO-REC-005, FAO-REC-009, FAO-GOV-010, FAO-GOV-011, FAO-GOV-012) and the rollback engine (FAO-GOV-005). The AI-advisory controls activate only when the AI flag flips, and the flag flips only after the AI threat model ships as its own ADR. This sequencing — deterministic spine first, AI advisory gated behind a flag and a published threat model — is deliberate. The deterministic ground truth has to be defensibly complete before AI is allowed near it.

---

## Control Type Definitions

For reference, because auditors and engineers use these terms differently.

| Type | Definition | Example in FinAgent OS |
|------|-----------|------------------------|
| **Preventive** | Stops an event from occurring. | Webhook-gated state progression: the file cannot move to "Submitted" until payment confirms. |
| **Detective** | Identifies an event after it has occurred. | Shadow Ledger: every execution, whether success or failure, is recorded. |
| **Monitoring** | Continuously observes the operation of other controls. | 5% randomized QA audit sampling agent outputs against their inputs. |
| **Corrective** | Reverses or mitigates the effect of an event. | Rollback Engine: staged changes can be reverted on failure or HITL rejection. |

COSO 2013 components referenced: (1) Control Environment, (2) Risk Assessment, (3) Control Activities, (4) Information & Communication, (5) Monitoring Activities.

---

## Architectural Pattern → Control Mapping

Every pattern in FinAgent OS has a Control ID in the format `FAO-XXX-NNN` where `XXX` is the governance area:

- `FAO-GOV` — Governance layer (platform-wide controls)
- `FAO-REC` — Reserve Reconciliation Agent
- `FAO-CLS` — Close Orchestrator (stub)
- `FAO-VAR` — Variance Analyzer (stub)
- `FAO-TRE` — Treasury Monitor (stub)

### Platform Governance Controls (FAO-GOV)

| Control ID | Pattern | Type | COSO | AI Authority | Status | Implementation |
|------------|---------|------|------|--------------|--------|----------------|
| **FAO-GOV-001** | Shadow Ledger immutable audit trail | Detective | Information & Communication | None | v1 | Postgres table in Supabase with append-only constraint enforced by a trigger that rejects UPDATE and DELETE at the row level. Every agent execution writes one record on entry and one on exit. Auto-incrementing `ledger_id` as primary key. Every write includes `correlation_id` threading through all downstream events. Append-only is a database constraint, not an application convention. |
| **FAO-GOV-002** | Agent Registry (formalized control population) | Preventive | Control Activities | None | v1 | Postgres table (`agent_registry`) in Supabase with foreign keys to `process_owners` and referenced by every workflow. No agent executes without a registry row specifying risk tier, process owner, data sources, rollback procedure, and SOX control IDs. The registry row is the gate. |
| **FAO-GOV-003** | Risk-Tier Classification (GREEN/AMBER/RED/BLOCKED) | Preventive | Risk Assessment | None | v1 | Every agent classified before deployment via `risk_tier` column on `agent_registry` (Supabase). Classification determines HITL requirements and approval thresholds. BLOCKED tier actions are never authorized by any approver. |
| **FAO-GOV-004** | HITL Gateway with segregation-of-duties enforcement | Preventive | Control Activities | None | v1 (partial) | n8n sub-workflow plus Postgres `BEFORE UPDATE` trigger (`hitl_queue_sod_guard`). Approver identity is compared to agent-invoker identity at the database boundary; same identity → trigger raises a named `FAO-GOV-004` exception, transaction aborts. Migration 0005c removed the original RLS-policy enforcement so the trigger is the sole enforcer — loud named exception is stronger SOX posture than silent zero-row update. v1 enforces single-approver SoD; multi-approver thresholds (see [ADR-0001](docs/adr/0001-dual-approval-not-yet-enforced.md)) ship in v1.1. |
| **FAO-GOV-005** | Rollback Engine (Break / Commit / Rollback) | Corrective | Control Activities | None | v1.1 | Staging area pattern. Agents will write intended changes to staging; commit only on successful HITL approval; revert staged changes on failure or rejection. v1 logs ROLLED_BACK as an `execution_status` enum value but the staging-area workflow ships in v1.1. |
| **FAO-GOV-006** | Database-First Vault Capture | Preventive | Control Activities | None | v1 | Inputs persist to Postgres (Supabase) before any LLM call or downstream processing. Zero data loss on API timeouts or mid-execution failures. |
| **FAO-GOV-007** | Webhook-Gated State Progression | Preventive | Control Activities | None | v1 | State transitions blocked until external confirmations received (payment webhooks, approval webhooks, scheduled cron). |
| **FAO-GOV-008** | Correlation ID threading | Detective | Information & Communication | None | v1 | Every agent invocation generates a UUID `correlation_id`. All Shadow Ledger entries, HITL requests, approval records, and downstream events carry the same ID. Enables end-to-end audit trace from trigger to outcome. |
| **FAO-GOV-009** | Policy Outcome vocabulary (ALLOW / ALLOW_WITH_OBLIGATIONS / REQUIRE_HUMAN / DENY / BLOCKED) | Preventive | Control Activities | None | v1 | Every agent execution produces exactly one policy outcome. Outcomes are deterministic — computed by rules, not generated by LLM. |
| **FAO-GOV-010** | 5% Randomized QA Audit sampling | Monitoring | Monitoring Activities | None | v1.1 | Sampling job will select 5% of agent executions per week. Process Owner reviews each sample: input, AI advisory (if present), policy outcome, match to expected. Deviations logged and drive rubric refinements. |
| **FAO-GOV-011** | Fractional API Cost Tracking | Monitoring | Monitoring Activities | None | v1.1 | Every AI advisory call will log prompt tokens, completion tokens, and USD cost (6-decimal precision) to Shadow Ledger. Schema columns (`ai_prompt`, `ai_output`, `ai_confidence`, `fractional_cost_usd`) exist and are NULL across all v1 rows; population begins when `FAO_AI_ASSIST_ENABLED=true` ships. |
| **FAO-GOV-012** | Closed-Loop Rubric Refinement with HITL Gate | Monitoring + Segregation of Duties | Monitoring Activities | Advisory | v1.1 | Weekly audit job will aggregate outcomes, flag anomalies where AI advisory diverged from human decision, propose rubric changes. All changes require human approval before deployment. AI proposes; human disposes. |
| **FAO-GOV-013** | Process Owner Named on Every Agent | Preventive | Control Environment | None | v1 | Agent Registry schema requires a foreign key to `process_owners` — an authenticated identity record, not a free-text string. No agent deploys to production without it. Directly satisfies the governance requirement: *"No build goes to production without a named Process Owner, documented data flows, access controls, and audit logging confirmed."* |
| **FAO-GOV-014** | AI Disabled by Default | Preventive | Control Environment | None | v1 | `FAO_AI_ASSIST_ENABLED=false` is the default configuration. System operates deterministically with AI disabled. Enabling AI is an explicit, logged configuration change. |
| **FAO-GOV-015** | MCP Tool Surface (Read + Bounded Invoke; No Governance Mutation) | Preventive | Control Activities | None | v1 | Python FastMCP server ([`mcp/server.py`](mcp/server.py)) exposing 6 read tools and 1 bounded invoke tool. There is deliberately no `approve_hitl`, no `update_threshold`, no `register_agent`. AI consumers can read the audit trail and trigger governed agents; AI consumers cannot mutate governance state. Asymmetry enforced at the tool surface — verified Apr 25, 2026 by adversarial probe via Claude Opus: three semantic searches across approve/resolve/decision/write/commit/override/bypass keywords returned the same five read-only tools. See [`mcp/README.md`](mcp/README.md) and the [self-audit transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960). |

### Reserve Reconciliation Agent Controls (FAO-REC)

| Control ID | Pattern | Type | COSO | AI Authority | Status | Implementation |
|------------|---------|------|------|--------------|--------|----------------|
| **FAO-REC-001** | Wallet-Ledger Balance Comparison | Detective | Information & Communication | None | v1 | Per-asset deterministic arithmetic: `discrepancy = wallet_balance - ledger_liability`. No AI. |
| **FAO-REC-002** | Per-Asset Materiality Threshold Evaluation | Preventive | Control Activities | None | v1 | Each asset has a configured USD-value materiality threshold in the `materiality_thresholds` Supabase table. Discrepancies above threshold trigger escalation. Deterministic rule. Threshold changes are logged to Shadow Ledger with the `last_reviewed_by` identity. |
| **FAO-REC-003** | Reserve Ratio Computation | Detective | Information & Communication | None | v1 | `reserve_ratio = wallet_balance / ledger_liability` per asset. Aggregate ratio computed across all assets. No AI. |
| **FAO-REC-004** | Reserve Ratio Threshold Check | Preventive | Control Activities | None | v1 | If `reserve_ratio < 1.00` for any asset OR aggregate ratio < configured floor → policy outcome = REQUIRE_HUMAN regardless of AI classification. Deterministic rule. |
| **FAO-REC-005** | AI Discrepancy Advisory Classification | Detective | Information & Communication | Advisory | v1.1 | When `FAO_AI_ASSIST_ENABLED=true`, LLM produces advisory classification (CLEAN / BENIGN_TIMING / ANOMALY / MATERIAL) with reasoning. Classification is input to FAO-REC-006, never the output. v1 ships with the flag off — `ai_prompt`, `ai_output`, `ai_confidence` columns are NULL across all v1 rows; the deterministic policy engine runs without AI input. |
| **FAO-REC-006** | Policy Outcome Engine | Preventive | Control Activities | None | v1 | Deterministic function: given materiality check (FAO-REC-002), ratio check (FAO-REC-004), and (when enabled) AI advisory (FAO-REC-005), compute one of: ALLOW (auto-log only), ALLOW_WITH_OBLIGATIONS (log + weekly review), REQUIRE_HUMAN (HITL gate), DENY (rejected with reason), BLOCKED (never auto-proceeds, full investigation required). |
| **FAO-REC-007** | Negative-Balance Anomaly Detection | Detective | Information & Communication | None | v1 | Per Kraken's own 2014 PoR reference implementation (`krakendb`), "large negative values" at leaf nodes require investigation. Agent flags any ledger liability with sign discrepancy. Deterministic rule. |
| **FAO-REC-008** | Audit Evidence Package Generation | Detective | Information & Communication | None | v1 | On completion, agent writes a timestamped JSON package containing all inputs, classifications, ratios, policy outcomes, AI advisory (if used), and correlation_id to Shadow Ledger. Reproducible audit trail for quarterly PoR publication. |
| **FAO-REC-009** | Human Approval Brief (AI Advisory) | Monitoring | Monitoring Activities | Advisory | v1.1 | When policy outcome = REQUIRE_HUMAN and `FAO_AI_ASSIST_ENABLED=true`, LLM generates a plain-English brief summarizing the discrepancy, the AI advisory classification, and the reasons for escalation. Brief is attached to the HITL request via `hitl_queue.ai_human_brief`. Does not alter policy outcome or substitute for human judgment. v1 ships with the column NULL across all rows; the deterministic `policy_rationale` is rendered to approvers as the authoritative source. |

### Stub Module Controls (FAO-CLS, FAO-VAR, FAO-TRE)

These stubs inherit all `FAO-GOV-*` controls automatically via the Agent Registry. Module-specific controls are documented in each stub's `README.md` and will populate this table as modules are implemented.

| Module | Risk Tier | Primary Control Types | Production Target |
|--------|-----------|----------------------|-------------------|
| Close Orchestrator (stub) | AMBER | Preventive (materiality gates) + Detective (checklist completion) | NetSuite + BlackLine |
| Variance Analyzer (stub) | AMBER | Monitoring (period-over-period flux) | NetSuite + internal data warehouse |
| Treasury Monitor (stub) | RED | Detective (position monitoring) + Preventive (liquidity threshold alerts) | Kyriba + Fireblocks |

**Reserve Reconciliation Agent (flagship) is RED tier.** Rationale: its outputs inform the quarterly Proof of Reserves attestation, a published regulatory-adjacent artifact. A material discrepancy that escapes the HITL gate would reach publication. See `docs/RISK-MATRIX.md` for per-agent justification.

---

## Governance Requirements Crosswalk

The governance requirements typical of an AI-agent platform in a SOX-regulated financial environment fall into seven dimensions. Each maps to one or more controls above.

| Governance Requirement | FinAgent OS Controls |
|-----------------------|---------------------|
| Data classification | FAO-GOV-002 (Agent Registry declares data sources per agent, production targets named: Fireblocks, NetSuite, Kyriba) |
| Auditability | FAO-GOV-001 (Shadow Ledger), FAO-GOV-008 (correlation ID threading), FAO-REC-008 (audit evidence package) |
| Human-in-the-loop checkpoints | FAO-GOV-004 (HITL Gateway), FAO-REC-006 (policy outcome engine routing to REQUIRE_HUMAN) |
| Failure detection | FAO-GOV-001 (every failure written to Shadow Ledger), FAO-GOV-005 (Rollback Engine triggered on failure) |
| Rollback mechanisms | FAO-GOV-005 (Break/Commit/Rollback staged changes) |
| Regulatory compliance | Every control above maps to a SOX control type and COSO component |
| Audit-ready design documentation | This document, plus `docs/ARCHITECTURE.md`, `docs/ADR.md`, `docs/AGENT-GUIDE.md` |

**Risk-tier-before-build requirement.** A common requirement in this domain: *"Classify all automation builds by risk tier before work begins. No build goes to production without a named Process Owner, documented data flows, access controls, and audit logging confirmed."* This is satisfied by FAO-GOV-002 + FAO-GOV-003 + FAO-GOV-013 + FAO-GOV-001 — an agent cannot exist in FinAgent OS without a Registry entry specifying all four, and the Registry entry is the gate to executing any workflow.

---

## Testing and Attestation

A control catalog without a testing plan is documentation, not assurance. The plan below names who tests each class of control, with what cadence, and what evidence is preserved.

| Control class | Test method | Cadence | Evidence preserved |
|---|---|---|---|
| Database-level enforcement (FAO-GOV-001 append-only, FAO-GOV-004 SoD) | Adversarial probe — attempt UPDATE/DELETE on `shadow_ledger`, attempt self-approval via `fao_hitl_resolve` | Each migration to either table; before any release | Failing query + raised exception captured to `docs/evidence/`; one row per probe |
| Application-layer validation (FAO-GOV-006 vault capture, Shadow Ledger Writer 17-field contract) | Test harnesses ([`workflows/Test_Writer_Harness__Multi-Item_.json`](workflows/Test_Writer_Harness__Multi-Item_.json), [`workflows/test_hitl_gateway_harness.json`](workflows/test_hitl_gateway_harness.json)) | Before each n8n workflow change | n8n execution log linked to the relevant correlation_id |
| MCP tool surface (FAO-GOV-015) | Adversarial-AI probe via Claude Opus or equivalent — semantic search across mutation-intent keywords; attempted HITL approval | Each MCP server release | Transcript + screenshots in [`docs/evidence/mcp/`](docs/evidence/mcp/) |
| Per-asset reconciliation rules (FAO-REC-001 through 008) | Fixture replay against current Kraken Dec 2025 PoR + 3 synthetic anomalies; ratios and policy outcomes must match the documented expected values | Before each flagship workflow change | `shadow_ledger` rows for the test correlation_id |
| Process Owner accountability (FAO-GOV-013) | Attestation review — each Process Owner signs off on the controls they own | Quarterly, per process owner | Signed attestation in `docs/attestations/` (v1.1 — currently captured via PR review log) |

**External attestation roadmap.** v1 ships without external attestation — the testing posture above is internal to the build. SOC 2 Type 1 (point-in-time) is feasible at v1.2 once the read-only Postgres role and OAuth-bound MCP transport ship. SOC 2 Type 2 (operating effectiveness over a period) requires 3–6 months of operational evidence and is feasible from v2 onwards once live connector data flows through the pipeline.

---

## Prior Art and Acknowledgements

FinAgent OS does not exist in a vacuum. The governance-first design is informed by publicly available prior art in the agentic AI and financial controls space:

- **[ATLAS (`quantumlayer-atlas/atlas`)](https://github.com/quantumlayer-atlas/atlas)** — for the first principle that AI should be optional and non-authoritative in policy decisions. The "Where is the AI?" table format at the top of this document is adapted from their approach.
- **[Kraken's own `krakendb` (Payward, 2014)](https://github.com/krakenfx/krakendb)** — for the PoR hash scheme reference, the canonical operational concern about negative-balance leaves, and the principle that external verification is necessary for trust.
- **[Kraken's `kraken-cli`](https://github.com/krakenfx/kraken-cli)** — for the *AI-native* framing applied to a Kraken-shipped trading system, the convention of dedicated agent-facing root documentation alongside the human README, the structured-JSON output discipline at workflow boundaries, and the MCP-server-as-first-class-component design pattern. The discovery of OpenClaw as prior art happened through their documentation.
- **[Dewale-A's `Agentic-Accounting-Close`](https://github.com/Dewale-A/Agentic-Accounting-Close)** — for the concrete dollar-threshold materiality gate pattern and the approach of enforcing segregation of duties at the API boundary rather than as documentation.
- **[OpenClaw Airlock (`tushar5623/OpenClaw_Airlock`)](https://github.com/tushar5623/OpenClaw_Airlock)** — for the GREEN/AMBER/RED/BLOCKED risk tier vocabulary and the per-action decision matrix pattern.
- **COSO 2013 Internal Control — Integrated Framework** — for the five-component structure every control maps to.

Where prior-art patterns have been adopted, this is explicit. Where FinAgent OS extends them — specifically in applying governance-first architecture to crypto-native financial infrastructure — this is also explicit. See `docs/ADR.md` for decision records explaining each architectural choice.

---

## Change Control

This document is versioned in git. **In v1**, changes route through a git pull request with named sign-off from the Process Owner of any control whose row is touched, plus a separate sign-off from the document's author. Approval is recorded in the PR's review log; the merge commit is the durable record. **In v1.1**, changes additionally route through the Rubric Refinement Gate (FAO-GOV-012): the weekly audit job aggregates outcomes, flags drift between AI advisory and human decisions, and proposes rubric changes which are then subject to the same PR + sign-off workflow. Historical versions in git provide the audit trail of how the control framework has evolved.

**v1.0 — April 2026** — Initial publication.
