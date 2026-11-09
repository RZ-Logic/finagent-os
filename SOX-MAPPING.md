# SOX Control Mapping

**Purpose:** Map every architectural pattern in FinAgent OS to its corresponding SOX control type, COSO framework component, and explicit AI authority level.

**Scope:** This document is the source of truth for how FinAgent OS maintains control integrity in a SOX-regulated financial environment. It is referenced by the Agent Registry (`sox_control_ids`) and the agent workflows. A separate Risk Matrix document is planned.

**Author:** Rizwan Ahmed, ACCA · Velocyt Consulting
**Status:** v1.0, April 2026; statuses updated November 2026 for the November 2026 release, live since 2026-11-09

**Live since 2026-11-09.** The statuses and implementation text below describe the November 2026 release, including dual approval: session identity, run start with a run token, decisions through one database function, the refusal journal, the admin audit, the error workflow and the sweep. They were deployed to the hosted Supabase project and the n8n instance in a cutover that finished on 2026-11-09 (UTC), at commit `c9c2fc0`. Before that the live system ran v1, which had the gaps recorded in this document's git history (the November 2026 correction). Wallet and ledger data are still fixtures inside the flagship (no live connectors). Evidence: a summary of the owner's cutover log is in [docs/evidence/cutover-2026-11-09.md](docs/evidence/cutover-2026-11-09.md); the full log, which holds internal identifiers, is kept outside this repository. Both are self-reported by the single author.

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
| HITL Routing Decision | ❌ None. Run rollup in the database → deterministic route. `approval_threshold` is copied to each request as its configured approval count; it is enforced for CRITICAL review and one approval for STANDARD (see ADR-0004). | N/A |
| Reserve Ratio Computation | ❌ None. Deterministic arithmetic. | N/A |
| Policy Outcome (ALLOW / ALLOW_WITH_OBLIGATIONS / REQUIRE_HUMAN / DENY / BLOCKED) | ❌ None. Deterministic policy rules. | N/A |
| Discrepancy Classification (CLEAN / BENIGN_TIMING / ANOMALY / MATERIAL) | ⚠️ AI advisory | Advisory only. Final classification is validated by deterministic rules before policy engine consumes it. |
| Human Approval Brief (summary presented to human reviewer at HITL gate) | ⚠️ AI advisory | Advisory only. Does not alter the policy outcome or bypass the approval requirement. |
| Weekly Rubric Refinement Proposals | ⚠️ AI advisory | Advisory only. All proposed changes require human approval before deployment. |
| Journal Entry Draft Generation (stub: Close Orchestrator) | ⚠️ AI advisory | Advisory only. Planned: every drafted entry will pass through materiality gates, segregation-of-duties checks, and human review before posting. |

**Key property:** no component calls an LLM, so FinAgent OS runs fully deterministically: every comparison, threshold, and policy rule fires without AI input. The four AI-advisory rows above are planned. The runtime switch `FAO_AI_ASSIST_ENABLED` is not built yet: nothing reads it, and `agent_registry.ai_advisory_enabled` defaults to FALSE but is not checked at runtime. The ledger append function refuses any event that carries AI advisory fields. AI is designed to be additive to human judgment, not a replacement for deterministic controls.

**AI advisory is off.** The deterministic backbone (wallet-ledger comparison with fail-closed inputs, per-asset materiality and ratio evaluation, the policy outcome engine, a database rollup that routes any escalated asset to review, decisions bound to the signed-in approver, append-only evidence tables, correlation threading, registry checks at run start, and the MCP read surface) is built. **Of the 24 controls in this document, 11 are live, 7 are partial and 6 are planned.** "Live" here means built, passing its tests in this repository and running on the live system since 2026-11-09 (see the note at the top). For the FAO-REC controls, running means running on fixture balances: no real wallet or ledger data flows. FAO-REC-002 is counted as Live but is inactive under the seeded thresholds. Partial means part of the stated control is implemented and the rest is not; each row says which part. The 6 planned controls (`Planned`) cover AI-advisory features (FAO-REC-005, FAO-REC-009, FAO-GOV-010, FAO-GOV-011, FAO-GOV-012) and the rollback engine (FAO-GOV-005). The AI-advisory controls activate only after the AI switch is built and turned on, and that happens only after the AI threat model ships as its own ADR. This sequencing (deterministic spine first, AI advisory gated behind a flag and a published threat model) is deliberate. The deterministic ground truth has to be defensibly complete before AI is allowed near it.

---

## Control Type Definitions

For reference, because auditors and engineers use these terms differently.

| Type | Definition | Example in FinAgent OS |
|------|-----------|------------------------|
| **Preventive** | Stops an event from occurring. | HITL gate: a run that needs review is not committed until a signed-in approver, who is not the invoker, records a decision through `fao_hitl_decide`. |
| **Detective** | Identifies an event after it has occurred. | Shadow Ledger: each completed run records STARTED, one ASSET_RECONCILED event per asset, and COMMITTED in an append-only table. |
| **Monitoring** | Evaluates whether other controls are operating. | 5% randomized QA audit sampling agent outputs against their inputs (planned). |
| **Corrective** | Reverses or mitigates the effect of an event. | Rollback Engine: staged changes can be reverted on failure or HITL rejection (planned). |

COSO 2013 components referenced: (1) Control Environment, (2) Risk Assessment, (3) Control Activities, (4) Information & Communication, (5) Monitoring Activities.

Monitoring in COSO 2013 is a component (Monitoring Activities: ongoing and separate evaluations of whether the other controls work), not a transaction-level control type like preventive or detective. It is listed above because some rows use it; every row typed Monitoring is planned. Reconciliations and exception checks (FAO-REC-001, FAO-REC-003, FAO-REC-007) are detective control activities, so they map to Control Activities.

---

## Architectural Pattern → Control Mapping

Every pattern in FinAgent OS has a Control ID in the format `FAO-XXX-NNN` where `XXX` is the governance area:

- `FAO-GOV`: Governance layer (platform-wide controls)
- `FAO-REC`: Reserve Reconciliation Agent
- `FAO-CLS`: Close Orchestrator (stub)
- `FAO-VAR`: Variance Analyzer (stub)
- `FAO-TRE`: Treasury Monitor (stub)

### Platform Governance Controls (FAO-GOV)

| Control | Pattern | Type | COSO | AI | Status | In one line |
|---|---|---|---|---|---|---|
| [FAO-GOV-001](#fao-gov-001-shadow-ledger-immutable-audit-trail) | Shadow Ledger immutable audit trail | Detective | Information & Communication | None | Partial | Ledger rows are appended only by database functions; no application role can change or remove them. |
| [FAO-GOV-002](#fao-gov-002-agent-registry-formalized-control-population) | Agent Registry (formalized control population) | Preventive | Control Activities | None | Live | The registry gates every run: unknown or inactive agents, non-invokers and invokers over the hourly limit are refused. |
| [FAO-GOV-003](#fao-gov-003-risk-tier-classification-greenamberredblocked) | Risk-Tier Classification (GREEN/AMBER/RED/BLOCKED) | Preventive | Risk Assessment | None | Live | Each agent's risk tier is copied from the registry onto its runs and requests; no caller sets it. |
| [FAO-GOV-004](#fao-gov-004-hitl-gateway-with-segregation-of-duties-enforcement) | HITL Gateway with segregation-of-duties enforcement | Preventive | Control Activities | None | Partial | Via `fao_hitl_decide` only; no self-approval; CRITICAL needs the registry count (two on the flagship); no 2FA yet. |
| [FAO-GOV-005](#fao-gov-005-rollback-engine-break--commit--rollback) | Rollback Engine (Break / Commit / Rollback) | Corrective | Control Activities | None | Planned | Staged changes reverted on rejection. Not built: a rejection is only recorded. |
| [FAO-GOV-006](#fao-gov-006-database-first-vault-capture) | Database-First Vault Capture | Preventive | Control Activities | None | Partial | STARTED is written before reconciliation with database-added run context; raw input sets are not yet kept. |
| [FAO-GOV-007](#fao-gov-007-webhook-gated-state-progression) | Webhook-Gated State Progression | Preventive | Control Activities | None | Live | A run starts only with a single-use token; a request leaves PENDING only by a decision or by expiry. |
| [FAO-GOV-008](#fao-gov-008-correlation-id-threading) | Correlation ID threading | Detective | Information & Communication | None | Live | One database-generated correlation id ties the run record, its ledger entries and its review request. |
| [FAO-GOV-009](#fao-gov-009-policy-outcome-vocabulary-allow--allow_with_obligations--require_human--deny--blocked) | Policy Outcome vocabulary (ALLOW / ALLOW_WITH_OBLIGATIONS / REQUIRE_HUMAN / DENY / BLOCKED) | Preventive | Control Activities | None | Live | A fixed outcome vocabulary; the run outcome is computed once, in the database. |
| [FAO-GOV-010](#fao-gov-010-5-randomized-qa-audit-sampling) | 5% Randomized QA Audit sampling | Monitoring | Monitoring Activities | None | Planned | Planned: a weekly 5% sample of runs, each reviewed by the process owner. |
| [FAO-GOV-011](#fao-gov-011-fractional-api-cost-tracking) | Fractional API Cost Tracking | Monitoring | Monitoring Activities | None | Planned | Planned: USD cost per AI call. The cost and AI columns exist and stay NULL while AI is off. |
| [FAO-GOV-012](#fao-gov-012-closed-loop-rubric-refinement-with-hitl-gate) | Closed-Loop Rubric Refinement with HITL Gate | Monitoring + Segregation of Duties | Monitoring Activities | Advisory | Planned | Planned: a weekly audit would propose rubric changes, each approved by a human. |
| [FAO-GOV-013](#fao-gov-013-process-owner-named-on-every-agent) | Process Owner Named on Every Agent | Preventive | Control Environment | None | Live | Every agent names a process owner tied to a sign-in; owners are deactivated, and one in use cannot be deleted. |
| [FAO-GOV-014](#fao-gov-014-ai-disabled-by-default) | AI Disabled by Default | Preventive | Control Environment | None | Partial | AI advisory is off, and the ledger refuses AI fields. |
| [FAO-GOV-015](#fao-gov-015-mcp-tool-surface-read--bounded-invoke-no-governance-mutation) | MCP Tool Surface (Read + Bounded Invoke; No Governance Mutation) | Preventive | Control Activities | None | Live | MCP: six read tools and one bounded run-start tool; no approval or configuration tool. |

#### FAO-GOV-001: Shadow Ledger immutable audit trail

*Detective · Information & Communication · AI authority: None · Status: Partial*

Postgres tables in Supabase. Shadow Ledger rows are appended only by the FinAgent database functions: the Writer's batch call `fao_ledger_append_batch` (STARTED, ASSET_RECONCILED and FAILED; all or none, naming every bad item) and the functions that write the run, HITL, notification, commit and correction events. Timestamps are set by the database, and run context (execution id, agent, risk tier, invoker) is set or checked by it.

No application role holds INSERT, UPDATE, DELETE or TRUNCATE on any FinAgent table. Row triggers refuse UPDATE and DELETE on the ledger and the other evidence tables for every role, and a statement trigger refuses TRUNCATE on every FinAgent table, the owner included unless the owner disables it.

A completed run writes STARTED, one ASSET_RECONCILED record per asset and COMMITTED; a run that needs review also writes HITL_REQUESTED, and the decision writes HITL_RESOLVED and COMMITTED in the same transaction. A run whose chain is incomplete gets COMMIT_BLOCKED instead of COMMITTED.

Failures are recorded: the flagship, the notifier and the sweeper name an error workflow that calls `fao_run_fail`, which writes a FAILED event on the flagship run or, when the failure is not tied to an unfinished flagship run, one row in the append-only `workflow_failures` table; the five-minute sweep fails runs left RUNNING past the agent's `sla_max_execution_seconds`, which the database refuses to set below 900; the flagship's n8n `executionTimeout` of 600 seconds stops a slow execution before that. The Writer has no error workflow of its own: a Writer failure fails the flagship execution, which is recorded.

Refusals returned by the FinAgent functions are written to the append-only `fao_refusal_journal` in the same transaction, with a per-caller cap each minute (past the cap one marker row; refusals continue).

Changes to configuration tables need a change reason and write before and after images to the append-only `fao_admin_audit`.

Corrections are new CORRECTION rows written by the admin-only `fao_ledger_correct`; the original row is never changed.

**Not covered:** refused direct table writes are not journaled (planned), and requests that PostgREST refuses before any function runs appear only in platform logs.

The database owner (`postgres`, `supabase_admin`) and holders of platform admin or secret keys are a separate trust class outside the control: they can disable triggers or change rows. That is by design, because a database cannot protect evidence from its own owner; an independent evidence store is planned and not built.

#### FAO-GOV-002: Agent Registry (formalized control population)

*Preventive · Control Activities · AI authority: None · Status: Live*

Postgres table (`agent_registry`) in Supabase with foreign keys to `process_owners`. The registry gates every run: `fao_run_start` refuses an unknown agent, refuses an agent that is not ACTIVE (and commits a RUN_REFUSED ledger row with the refusal), requires the caller to hold the invoker role for that agent, and enforces the agent's `max_runs_per_hour` per invoker (a replay of an expired run's idempotency key counts toward it). It also refuses an `sla_max_execution_seconds` below 900.

Status is checked again later: a claim for an agent that is no longer ACTIVE is refused and the run expires, and at finalize or on an approval the run gets COMMIT_BLOCKED instead of COMMITTED and ends FAILED. The HITL request timeout comes from the registry SLA. A change to a registry row needs a change reason in the same transaction and writes before and after images to `fao_admin_audit`; `updated_at` is set by a trigger.

Admins change status, the AI flag and the run limit through `fao_admin_set_agent` with a reason.

#### FAO-GOV-003: Risk-Tier Classification (GREEN/AMBER/RED/BLOCKED)

*Preventive · Risk Assessment · AI authority: None · Status: Live*

Every agent has a `risk_tier` on `agent_registry` (Supabase). CHECK constraints forbid BLOCKED as the tier of an agent, a run or a new HITL request, since BLOCKED is reserved for policy outcomes. The tier is copied from the registry into the run record at run start and from the run into the HITL request; no caller supplies it, and a Writer event whose tier differs from the run's is refused.

The agent's `approval_threshold` (two for RED) is recorded on each request as its configured approval count. The configured count is enforced for CRITICAL review and one approval for STANDARD, frozen at request creation (owner decision, [ADR-0004](docs/adr/0004-dual-approval-enforced.md)); requests created before dual approval landed keep one.

#### FAO-GOV-004: HITL Gateway with segregation-of-duties enforcement

*Preventive · Control Activities · AI authority: None · Status: Partial*

Decisions are recorded only by `fao_hitl_decide`, called with the approver's own Supabase Auth session; the approver is taken from `auth.uid()`, never from a payload, and the invoker was recorded the same way at run start. No application role can write `hitl_queue` directly. A row trigger that applies to every role, the owner included, enforces the rules: the approver is the signed-in user, is not the invoker, and holds the approver role for the agent; no decision at or after the deadline; decided requests cannot change and no request can be deleted.

A decision (approve or reject) by the run's invoker is refused with SOD_SELF_APPROVAL (403) and written to the refusal journal; nothing is written to the Shadow Ledger. An approval for a run whose invoker is no longer an active owner holding the invoker role is recorded but not committed (INVOKER_NOT_ACTIVE). The decision and its ledger events commit in one transaction.

The old `fao_hitl_resolve` always raises, and the n8n approval pages are retired.

**Dual approval** ([ADR-0004](docs/adr/0004-dual-approval-enforced.md)): every approval is a row in the append-only `hitl_approvals` table; client roles can write it only through `fao_hitl_decide`, from the approver's own session; an APPROVED decision needs at least `enforced_approvals` counted approvals from different users, the deciding approver among them, enforced in `fao_hitl_decide` and in the `hitl_queue` row guard for every role; any one eligible rejection closes the request.

The guards take the user from the session's `auth.uid()`, so an owner-class session that sets its own JWT claims can record approvals and decide as any eligible approver outside `fao_hitl_decide`; the owner is outside the control (FAO-GOV-001).

**Qualifying approver grants (preventive):** an approval counts, and a user may approve, only through an unrevoked approver grant covering the agent that was made before the request was opened, not by the invoker and not by another approver of the request (a rejection needs such a grant without the last condition); `fao_private.approver_qualifies` states the rule once and is applied in `counted_approvals`, the decide check and both row guards (`hitl_approvals` and `hitl_queue`).

**Limits:** named roles such as Controller and CFO are not modelled, so any two eligible approvers count; two approvals bind two identities but cannot prove two people; no second factor yet (TOTP is planned), so a stored password is enough to approve for any user with the approver role; the database owner and holders of platform admin keys are outside the control (see FAO-GOV-001); and in the public demo one person holds every demo identity, so the control binds actions to identities but cannot prove they are different people.

#### FAO-GOV-005: Rollback Engine (Break / Commit / Rollback)

*Corrective · Control Activities · AI authority: None · Status: Planned*

Staging area pattern. Agents will write intended changes to staging; commit only on successful HITL approval; revert staged changes on failure or rejection. Today a rejected request is logged with ROLLED_BACK as the `execution_status` of the run's COMMITTED event, but nothing is staged or reverted; CORRECTION rows (FAO-GOV-001) correct the record, they do not roll anything back.

The staging-area workflow is planned.

#### FAO-GOV-006: Database-First Vault Capture

*Preventive · Control Activities · AI authority: None · Status: Partial*

The STARTED record is written to Postgres (Supabase) through the Writer before reconciliation runs, and the database adds the invoker, the invocation channel, the reason and the n8n execution id from the run record. A STARTED whose inputs carry any of those four keys (at any depth, in any normalised spelling) is refused and nothing is written (owner decision 2026-11-08); the flagship sends none of them, and `check-exports` rule `started_db_keys` holds that. Each ASSET_RECONCILED record stores that asset's wallet and ledger balances.

No LLM calls are made.

Full upfront raw capture is not achieved: the raw wallet and ledger input sets travel with the STARTED item but the Writer's Validate Batch strips them, so a failure before the per-asset writes leaves the inputs unrecorded (the failure itself is recorded, see FAO-GOV-001).

#### FAO-GOV-007: Webhook-Gated State Progression

*Preventive · Control Activities · AI authority: None · Status: Live*

State transitions wait for authenticated confirmations. A run starts only when the n8n invoke webhook, which requires a header key, receives a single-use run token that `fao_run_start` issued to a signed-in invoker; `fao_run_claim` consumes the token (stored only as a hash, valid for 10 minutes) and refuses a forged, expired or reused one. A HITL request is decided only through `fao_hitl_decide` (FAO-GOV-004), which writes HITL_RESOLVED and COMMITTED in the same transaction; otherwise the sweep expires it at its deadline.

Approvers decide on a static approval page (`approval-app/`), signed in with their own account. Slack notices only link to the page and may be delivered more than once: every attempt whose outcome the notifier sees is recorded (a second SENT for the same request and notice level writes no row), failed sends are retried by the five-minute sweep up to `notify_max_attempts`, and an overdue request expires and escalates once (HITL_EXPIRED is the expiry record, which the escalation and, on an incomplete audit chain, COMMIT_BLOCKED can follow; the sweep never writes COMMITTED for it).

A request with no notice sent within the notice window is escalated once and no longer re-sent; the owner accepted that sweep rule as built on 2026-11-08. Payment webhooks and scheduled cron confirmations are not part of the build.

The page's logic is unit-tested; its sign-in and decision flow is checked by hand once per release (there is no automated browser test); for this build the whole check (steps 1 to 15 of `approval-app/README.md`, with a one-approval and a two-approval request) was done on the local stack on 2026-11-08, in the built-in Chromium browser of the Claude desktop app, driven by Claude Code (an AI agent) rather than by a person, with seed test users.

#### FAO-GOV-008: Correlation ID threading

*Detective · Information & Communication · AI authority: None · Status: Live*

`fao_run_start` creates the run record (`run_invocations`) and the database generates its `correlation_id` and `execution_id`. Every Shadow Ledger entry and HITL request for the run carries the same correlation id, and the run record holds the invoker, reason, state and n8n execution id.

A trigger enforces the run states (REQUESTED, RUNNING, AWAITING_HITL, then COMMITTED, FAILED or EXPIRED; a finished run never changes).

Every client RPC takes one JSON body that the database decodes and validates; an unknown, missing or repeated key, or a value that is not a string, is refused with INVALID_INPUT and journaled. The view `fao_run_summary` gives one row per run. Enables end-to-end audit trace from trigger to outcome.

#### FAO-GOV-009: Policy Outcome vocabulary (ALLOW / ALLOW_WITH_OBLIGATIONS / REQUIRE_HUMAN / DENY / BLOCKED)

*Preventive · Control Activities · AI authority: None · Status: Live*

Every completed run records one rollup policy outcome on its COMMITTED row, and each asset gets one per-asset outcome. Outcomes are deterministic: computed by rules, not generated by an LLM. The rollup is computed once, in the database (`fao_private.run_rollup`), from the stored asset rows.

A run that fails before finalize records a FAILED event and no rollup outcome (see FAO-GOV-001).

#### FAO-GOV-010: 5% Randomized QA Audit sampling

*Monitoring · Monitoring Activities · AI authority: None · Status: Planned*

Sampling job will select 5% of agent executions per week. Process Owner reviews each sample: input, AI advisory (if present), policy outcome, match to expected. Deviations logged and drive rubric refinements.

#### FAO-GOV-011: Fractional API Cost Tracking

*Monitoring · Monitoring Activities · AI authority: None · Status: Planned*

Every AI advisory call will log prompt tokens, completion tokens, and USD cost (6-decimal precision) to Shadow Ledger. Schema columns (`ai_prompt`, `ai_output`, `ai_confidence`, `fractional_cost_usd`) exist and are NULL across all v1 rows; while AI advisory is off, the ledger append function refuses any event that sets them. Population begins when `FAO_AI_ASSIST_ENABLED=true` ships.

#### FAO-GOV-012: Closed-Loop Rubric Refinement with HITL Gate

*Monitoring + Segregation of Duties · Monitoring Activities · AI authority: Advisory · Status: Planned*

Weekly audit job will aggregate outcomes, flag anomalies where AI advisory diverged from human decision, propose rubric changes. All changes require human approval before deployment. AI proposes; human disposes.

#### FAO-GOV-013: Process Owner Named on Every Agent

*Preventive · Control Environment · AI authority: None · Status: Live*

Agent Registry schema requires a foreign key to `process_owners`: an identity record tied to a Supabase Auth user, not a free-text string. Every registry row, and so every agent that writes to the Shadow Ledger, has a named Process Owner.

Owners are deactivated, not deleted: `fao_admin_set_owner_active` sets `active`, and a referenced owner cannot be deleted. Application roles (invoker, approver, admin, reader) are rows in `fao_user_roles`, revoked rather than deleted; an inactive owner's invoker, approver and admin roles stop counting.

This addresses the named-Process-Owner part of the governance requirement *"No build goes to production without a named Process Owner, documented data flows, access controls, and audit logging confirmed."*; access control and audit logging are now enforced in the database, with the limits stated in FAO-GOV-001 and FAO-GOV-004.

#### FAO-GOV-014: AI Disabled by Default

*Preventive · Control Environment · AI authority: None · Status: Partial*

AI advisory is off: no workflow calls an LLM, `agent_registry.ai_advisory_enabled` defaults to FALSE, and the ledger append function refuses events that carry AI advisory fields.

The runtime switch is not built: nothing reads `FAO_AI_ASSIST_ENABLED` or checks `ai_advisory_enabled` at runtime. Changing the flag is a logged configuration change: it needs a change reason and writes before and after images to `fao_admin_audit` (through `fao_admin_set_agent`, or owner SQL with a reason).

#### FAO-GOV-015: MCP Tool Surface (Read + Bounded Invoke; No Governance Mutation)

*Preventive · Control Activities · AI authority: None · Status: Live*

Python FastMCP server ([`mcp/server.py`](mcp/server.py)) exposing 6 read tools and 1 bounded invoke tool. There is deliberately no `approve_hitl`, no `update_threshold`, no `register_agent`.

The database enforces the same asymmetry: the server reads as a dedicated Supabase Auth user that holds only the global `reader` role, and refuses to start if a service or secret key is in its environment or if the reader holds any other role. The database refuses the reader's writes and workflow calls, and the service-role key has no privilege on any FinAgent object.

The invoke tool signs in as a named human invoker and calls `fao_run_start` with that person's session, so the registry, role and rate-limit checks apply; a retry with the same idempotency key replays the same run.

On live the invoker is unset until a second factor ships, so the invoke tool refuses with `NO_USER_CREDENTIAL`; the cutover smoke supplied an invoker password in process memory for its runs only. The grant allow-list is asserted when the migrations run, and the five-minute sweep reports any drift from it.

Read results move text written by users under an `untrusted_text` field.

**History:** the self-audit of Apr 25, 2026 (via Claude Opus, tool discovery only) and the screenshots in [`docs/evidence/mcp/`](docs/evidence/mcp/) cover the v1 server, which held a service key, and mention database layers since replaced; they are kept as a record, not as evidence for this build. See [`mcp/README.md`](mcp/README.md) and the [self-audit transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960).

### Reserve Reconciliation Agent Controls (FAO-REC)

| Control | Pattern | Type | COSO | AI | Status | In one line |
|---|---|---|---|---|---|---|
| [FAO-REC-001](#fao-rec-001-wallet-ledger-balance-comparison) | Wallet-Ledger Balance Comparison | Detective | Control Activities | None | Live | Wallet minus ledger per asset; a one-sided or invalid balance is BLOCKED. |
| [FAO-REC-002](#fao-rec-002-per-asset-materiality-threshold-evaluation) | Per-Asset Materiality Threshold Evaluation | Preventive | Control Activities | None | Live (inactive under the seeded thresholds) | A stablecoin USD shortfall above materiality escalates; inactive under the seeded floor of 1.00. |
| [FAO-REC-003](#fao-rec-003-reserve-ratio-computation) | Reserve Ratio Computation | Detective | Control Activities | None | Partial | Reserve ratio per asset; no aggregate ratio yet. |
| [FAO-REC-004](#fao-rec-004-reserve-ratio-threshold-check) | Reserve Ratio Threshold Check | Preventive | Control Activities | None | Partial | An asset's ratio below its floor goes to CRITICAL review; no aggregate floor check yet. |
| [FAO-REC-005](#fao-rec-005-ai-discrepancy-advisory-classification) | AI Discrepancy Advisory Classification | Detective | Information & Communication | Advisory | Planned | Planned: AI would classify a discrepancy as advisory input only. AI is off. |
| [FAO-REC-006](#fao-rec-006-policy-outcome-engine) | Policy Outcome Engine | Preventive | Control Activities | None | Live | Rules pick one of five outcomes per asset; the worst asset sets the run's review. |
| [FAO-REC-007](#fao-rec-007-negative-balance-anomaly-detection) | Negative-Balance Anomaly Detection | Detective | Control Activities | None | Live | Any negative ledger liability goes to CRITICAL review. |
| [FAO-REC-008](#fao-rec-008-audit-evidence-package-generation) | Audit Evidence Package Generation | Detective | Information & Communication | None | Partial | Correlated records per run; no single evidence package yet. |
| [FAO-REC-009](#fao-rec-009-human-approval-brief-ai-advisory) | Human Approval Brief (AI Advisory) | Monitoring | Monitoring Activities | Advisory | Planned | Planned: AI would write a plain-English brief for approvers, never changing the outcome. |

#### FAO-REC-001: Wallet-Ledger Balance Comparison

*Detective · Control Activities · AI authority: None · Status: Live*

Per-asset deterministic arithmetic: `discrepancy = wallet_balance - ledger_liability`. No AI. Inputs fail closed: an asset present on one side only, or a balance that is not a finite number, is BLOCKED and routed to human review instead of compared.

**Limits:** the run's asset list is the union of the two feeds, so an asset absent from both is not detected; a check against the threshold table is planned (README Limitations).

#### FAO-REC-002: Per-Asset Materiality Threshold Evaluation

*Preventive · Control Activities · AI authority: None · Status: Live (inactive under the seeded thresholds)*

For stablecoin assets: if ledger − wallet > materiality_usd (a shortfall) and the ratio is neither below the floor nor above the band → REQUIRE_HUMAN STANDARD (IN_BAND_USD_MATERIAL). A surplus inside the band is governed by the band upper alone and ALLOWs (owner decision 2026-11-08).

With the seeded floor equal to the band lower (1.0000), every stablecoin shortfall is caught first by the floor rule as BELOW_FLOOR CRITICAL, so this rule fires only under a threshold whose floor is below 1.00. The owner decided on 2026-11-08 to keep the stablecoin floor at 1.00, so any stablecoin under-reserve is CRITICAL and this rule changes no outcome in the shipped configuration; it is tested offline with a threshold override, not end to end. Deterministic rule.

An asset with no usable threshold is BLOCKED and routed to review; a run that finds no threshold rows at all stops with an error, which is recorded. Threshold changes need a reason and are audited (`fao_admin_set_threshold`).

**Limits:** non-stablecoin USD materiality is deferred pending price oracle integration; the FAO-REC-004 ratio check provides primary coverage (see README Limitations).

The seeded USDC and USDT band is [1.0000, 1.0500]: the owner decided on 2026-11-07 that stablecoin reserves are held near 105%, so a ratio up to 1.05 is in band and only a ratio above 1.05 escalates as ABOVE_BAND_UPPER.

On the live system the band upper was raised from 1.0050 to 1.0500 during the cutover, by Marcus through `fao_admin_set_threshold` with a change reason (2026-11-08, cutover step 7).

#### FAO-REC-003: Reserve Ratio Computation

*Detective · Control Activities · AI authority: None · Status: Partial*

`reserve_ratio = wallet_balance / ledger_liability` per asset, stored on each ASSET_RECONCILED row. No AI. No aggregate ratio across assets is computed: the database rollup never sums units across assets and has no ratio field (a pgTAP test checks this).

An aggregate needs a defined scope, a common valuation basis and a floor before it can be built; it is planned.

#### FAO-REC-004: Reserve Ratio Threshold Check

*Preventive · Control Activities · AI authority: None · Status: Partial*

If an asset's `reserve_ratio` is below its configured `ratio_floor` (1.00 for every seeded asset), that asset's policy outcome = REQUIRE_HUMAN CRITICAL and the run goes to human review. Deterministic rule; no AI input. The aggregate floor check is not built: no aggregate floor is configured or evaluated (see FAO-REC-003).

#### FAO-REC-005: AI Discrepancy Advisory Classification

*Detective · Information & Communication · AI authority: Advisory · Status: Planned*

When `FAO_AI_ASSIST_ENABLED=true`, LLM produces advisory classification (CLEAN / BENIGN_TIMING / ANOMALY / MATERIAL) with reasoning. Classification is input to FAO-REC-006, never the output. The switch is not built and AI advisory is off.

`ai_prompt`, `ai_output`, `ai_confidence` columns are NULL across all v1 rows, and the ledger append function refuses events that set them; the deterministic policy engine runs without AI input.

#### FAO-REC-006: Policy Outcome Engine

*Preventive · Control Activities · AI authority: None · Status: Live*

Deterministic function: given materiality check (FAO-REC-002), ratio check (FAO-REC-004), and (when enabled) AI advisory (FAO-REC-005), compute one of: ALLOW (auto-log only), ALLOW_WITH_OBLIGATIONS (logged with a weekly-review obligation; the review itself is not automated), REQUIRE_HUMAN (HITL gate), DENY (rejected with reason), BLOCKED (never auto-proceeds; routed to review).

Per-asset outcomes are computed in the flagship workflow; the run outcome is the worst asset's, computed in the database. Any asset that is REQUIRE_HUMAN, DENY or BLOCKED routes the whole run to one human review request, with review sub-tier CRITICAL when any asset is DENY, BLOCKED or CRITICAL. One-sided or non-finite balances and assets with no threshold are BLOCKED.

A BLOCKED request is decided like any CRITICAL review: the registry count of approvals (two for the RED flagship) commits the run, with BLOCKED as the outcome on the COMMITTED row.

**Limits:** no current rule produces DENY; the database checks that each asset in the run's declared list has exactly one well-formed row, that ALLOW and ALLOW_WITH_OBLIGATIONS rows carry a numeric ratio, and the audit chain. It does not check a row's wallet, ledger and threshold figures against its outcome, or the policy result itself, which the workflow computes.

#### FAO-REC-007: Negative-Balance Anomaly Detection

*Detective · Control Activities · AI authority: None · Status: Live*

Per Kraken's own 2014 PoR reference implementation (`krakendb`), "large negative values" at leaf nodes require investigation. Agent flags any negative ledger liability as REQUIRE_HUMAN CRITICAL. Deterministic rule.

#### FAO-REC-008: Audit Evidence Package Generation

*Detective · Information & Communication · AI authority: None · Status: Partial*

Each run writes correlated, timestamped JSON records to the Shadow Ledger: STARTED, one ASSET_RECONCILED record per asset (balances, ratio, threshold, policy outcome and rationale), and COMMITTED with the per-asset summary, written in the same transaction as the rollup; when the chain is incomplete the run gets COMMIT_BLOCKED, naming the missing, duplicate or unexpected assets measured against the run's declared asset list, instead. The view `fao_run_summary` gives one row per run with its state, request, decision and latest committed outcome. No step assembles these into one self-contained evidence package; that is planned.

The records are retrieved by `correlation_id`. AI advisory fields are NULL.

#### FAO-REC-009: Human Approval Brief (AI Advisory)

*Monitoring · Monitoring Activities · AI authority: Advisory · Status: Planned*

When policy outcome = REQUIRE_HUMAN and `FAO_AI_ASSIST_ENABLED=true`, LLM generates a plain-English brief summarizing the discrepancy, the AI advisory classification, and the reasons for escalation. Brief is attached to the HITL request via `hitl_queue.ai_human_brief`. Does not alter policy outcome or substitute for human judgment.

The column is not set by any code today; the deterministic `policy_rationale` is shown to approvers on the approval page as the authoritative source.

### Stub Module Controls (FAO-CLS, FAO-VAR, FAO-TRE)

These stubs have Agent Registry rows and are designed to inherit the `FAO-GOV-*` controls as they are implemented. Their registry status is not ACTIVE, so run start refuses them (FAO-GOV-002). The stub folders are placeholders; module-specific controls will be documented in a `README.md` per stub (planned) and will populate this table as modules are implemented.

| Module | Risk Tier | Primary Control Types | Production Target |
|--------|-----------|----------------------|-------------------|
| Close Orchestrator (stub) | AMBER | Preventive (materiality gates) + Detective (checklist completion) | NetSuite + BlackLine |
| Variance Analyzer (stub) | AMBER | Monitoring (period-over-period flux) | NetSuite + internal data warehouse |
| Treasury Monitor (stub) | RED | Detective (position monitoring) + Preventive (liquidity threshold alerts) | Kyriba + Fireblocks |

**Reserve Reconciliation Agent (flagship) is RED tier.** Rationale: its outputs inform the quarterly Proof of Reserves attestation, a published regulatory-adjacent artifact. A material discrepancy that escapes the HITL gate would reach publication. RED configures two approvals per request; two are enforced for CRITICAL review and one for STANDARD (ADR-0004), live since 2026-11-09; v1 enforced one. A per-agent risk matrix (`docs/RISK-MATRIX.md`) is planned.

---

## Governance Requirements Crosswalk

The governance requirements typical of an AI-agent platform in a SOX-regulated financial environment fall into seven dimensions. Each maps to one or more controls above.

| Governance Requirement | FinAgent OS Controls |
|-----------------------|---------------------|
| Data classification | FAO-GOV-002 (Agent Registry declares data sources per agent, production targets named: Fireblocks, NetSuite, Kyriba) |
| Auditability | FAO-GOV-001 (Shadow Ledger, refusal journal, admin audit), FAO-GOV-008 (correlation ID threading), FAO-REC-008 (audit evidence records; the package is planned) |
| Human-in-the-loop checkpoints | FAO-GOV-004 (HITL Gateway), FAO-REC-006 (policy outcome engine routing REQUIRE_HUMAN, DENY and BLOCKED to review) |
| Failure detection | FAO-GOV-001 (the error workflow records a FAILED event or a `workflow_failures` row; the sweep fails stale runs; an incomplete audit chain gets COMMIT_BLOCKED), FAO-GOV-005 (Rollback Engine triggered on failure, planned) |
| Rollback mechanisms | FAO-GOV-005 (Break/Commit/Rollback staged changes) |
| Regulatory compliance | Every control above maps to a SOX control type and COSO component |
| Audit-ready design documentation | This document, the root `README.md`, and the decision records in [`docs/adr/`](docs/adr/). `docs/ARCHITECTURE.md` and `docs/AGENT-GUIDE.md` are planned. |

**Risk-tier-before-build requirement.** A common requirement in this domain: *"Classify all automation builds by risk tier before work begins. No build goes to production without a named Process Owner, documented data flows, access controls, and audit logging confirmed."* This is addressed in part by FAO-GOV-002 + FAO-GOV-003 + FAO-GOV-013 + FAO-GOV-001. The registry schema requires a named Process Owner and a risk tier for every agent, and a HITL request cannot be created for an agent without a registry row and SLA. A run cannot start unless the registry row is ACTIVE and the invoker holds the invoker role; the tier comes from the registry, and status is checked again at claim, finalize and approval. This build was deployed to the live system on 2026-11-09 (see the note at the top); its wallet and ledger data are still fixtures.

---

## Testing and Attestation

A control catalog without a testing plan is documentation, not assurance. The plan below names how each class of control is tested, with what cadence, and what evidence is preserved.

`npm test` (`scripts/test-all.mjs`) runs six automated layers against a local Supabase stack and prints one table: `exports` (static checks of the n8n workflow exports), `node` (Node unit tests of the Code-node JavaScript, the approval page's pure functions and the fixtures), `pytest` (the MCP server, offline), `pgtap` (database tests in `supabase/tests/`), `api` (tests with real sign-ins through PostgREST, in `test/api/`) and `e2e` (the exported workflows imported into a local n8n 2.46.6 and run against the local stack, with a fake Slack). The last full run, on 2026-11-08 at 17:29 UTC (after the dual approval doc fixes, on top of `41e11cc`) after a fresh database reset, passed 2313 tests (exports 143, node 176, pytest 344, pgTAP 1563, api 60, e2e 27) with none failed or skipped. Nothing here reaches the hosted project or the live n8n instance.

### Database enforcement

*Covers: FAO-GOV-001 append-only and journal, FAO-GOV-002 registry gate, FAO-GOV-003 tier, FAO-GOV-004 SoD, FAO-GOV-008 run states, the grant allow-list*

- **Test method:** Adversarial pgTAP tests per role: direct INSERT, UPDATE, DELETE and TRUNCATE on every FinAgent table, self-approval, decisions after the deadline, changes to decided requests, forged tiers, reserved ledger keys, the grant allow-list and the refusal journal's cap. API tests repeat the identity, SoD, direct-write and body checks over HTTP with real sign-ins, and show that the service-role key reaches no FinAgent object
- **Cadence:** Every change, through `npm test`; CI on pull requests and on pushes to `main`
- **Evidence preserved:** Test logs and `summary.json` in `.local/reports/` (git-ignored, not committed); CI keeps reports only for a failed job, for 7 days

### Workflows

*Covers: FAO-GOV-001 failure records, FAO-GOV-006 STARTED capture, FAO-GOV-007 invoke and notices, the Writer*

- **Test method:** Export checks (credential names, parameterized queries, error workflow settings, publish order); Code-node unit tests; e2e scenarios S01 to S27, including forged, expired and reused run tokens, a missing invoke header, Slack failure and retry, expiry and escalation, forced failures that reach the error workflow, and the two test harnesses run with `n8n execute` (S17 to S19, Writer negative case included)
- **Cadence:** Every change, through `npm test`; CI
- **Evidence preserved:** As above; the e2e layer also writes `.local/e2e/evidence.json` per scenario

### MCP tool surface

*Covers: FAO-GOV-015*

- **Test method:** pytest: the server refuses to start with a service or secret key, a non-reader identity or a plain-http remote URL; inputs are bounded; user-written text is marked untrusted. API tests: the reader's writes and workflow calls are refused. `mcp/scripts/smoke_local.py` calls each read tool against the local stack (run by hand). The v1 self-audit transcript is history, not a test of this build
- **Cadence:** Every change; smoke script before a release
- **Evidence preserved:** As above; transcript and v1 screenshots in [`docs/evidence/mcp/`](docs/evidence/mcp/)

### Per-asset reconciliation rules

*Covers: FAO-REC-001 through 008*

- **Test method:** Fixture replay: 3 Kraken Dec 2025 PoR anchors, 1 clean baseline and 3 synthetic anomalies. `fixtures.test.mjs` checks the workflow's inline fixtures equal `fixtures/*.json` and that each asset's ratio, outcome and control match the documented values; `recon.test.mjs` drives the other branches; e2e S01, S11, S12 and S20 run them in n8n. Kraken's snapshot covers more than Spot, so its ratios are not directly comparable with the Spot-only seeds
- **Cadence:** Every change, through `npm test`
- **Evidence preserved:** As above

### Approval page

*Covers: FAO-GOV-004, FAO-GOV-007*

- **Test method:** Unit tests of the page's pure functions (`approval-app.test.mjs`). The sign-in and decision flow (no session, the invoker sees no buttons, another approver approves, reload, invalid link, no CSP violation; on a two-approval request, the first approval is recorded but not committed, the approver who approved sees only Reject after a reload, and a second approver decides) is a manual check once per release; there is no automated browser test and the page is not checked in CI
- **Cadence:** Once per release, by hand
- **Evidence preserved:** Recorded for this release in the build's run log (kept outside this repository): 2026-11-08, local stack, built-in Chromium browser of the Claude desktop app, driven by Claude Code (an AI agent) rather than by a person; on live, the page checks at the cutover (Claude Code) and the owner's check in Chrome, Brave and Firefox (2026-11-09); not checked in Safari

### Process Owner accountability

*Covers: FAO-GOV-013*

- **Test method:** Attestation review: each Process Owner signs off on the controls they own
- **Cadence:** Quarterly, per process owner
- **Evidence preserved:** Signed attestation in `docs/attestations/` (planned; none captured: the history is direct commits with no PR review record)

**CI.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs the six layers in four jobs (static: exports and node; mcp: pytest on Python 3.12; db: pgTAP and API on a local Supabase stack; e2e) on pull requests, pushes to `main` and by hand. It first ran on GitHub on 2026-11-09, after the branch was pushed to `main`: all four jobs pass, 2313 of 2313 (run `42559222998`, commit `744ca3a`).

**Run record.** Every change round during the build ended with the full `npm test` from a fresh database reset, and the release candidate passed 2313 of 2313 (2026-11-08); CI on GitHub passes the same 2313 tests (2026-11-09). Two held-out scenario sets, never shown to the agents that built the code, were scored by separate reviewers: a 45-scenario regression set passed 45 of 45 (two of those rely on a sweep rule the owner accepted), and a 26-scenario blind set for dual approval reached 24 of 26 after three rounds; the owner accepted the two remaining minor deviations as built (they follow the written specification). Per-scenario results are kept outside the repository so that builders never see the scenarios.

**Evidence images.** The PNGs in [`docs/evidence/`](docs/evidence/) were captured by hand against v1 (the SQL editor and n8n). They show v1 behaviour, including functions and pages this build retires, and the honest path more than the adversarial one. They are kept as history; the tests above are the evidence for this build. New screenshots for this build are not made yet.

**External attestation roadmap.** There is no external attestation: the testing posture above is internal to the build. SOC 2 Type 1 (point-in-time) is a later step: this build is live since 2026-11-09, but it also needs an OAuth-bound MCP transport, which is not built. SOC 2 Type 2 (operating effectiveness over a period) requires 3 to 6 months of operational evidence and is feasible once live connector data flows through the pipeline. SOC 2 reports against the trust services criteria (such as security); it is not an ICFR report. A SOC 1 report would be the ICFR-relevant one if FinAgent OS is offered as a service to entities that rely on it for financial reporting.

---

## Prior Art and Acknowledgements

FinAgent OS does not exist in a vacuum. The governance-first design is informed by publicly available prior art in the agentic AI and financial controls space:

- **[ATLAS (`quantumlayer-atlas/atlas`)](https://github.com/quantumlayer-atlas/atlas)**: the first principle that AI should be optional and non-authoritative in policy decisions. The "Where is the AI?" table format at the top of this document is adapted from their approach.
- **[Kraken's own `krakendb` (Payward, 2014)](https://github.com/krakenfx/krakendb)**: the PoR hash scheme reference, the canonical operational concern about negative-balance leaves, and the principle that external verification is necessary for trust.
- **[Kraken's `kraken-cli`](https://github.com/krakenfx/kraken-cli)**: the *AI-native* framing applied to a Kraken-shipped trading system, the convention of dedicated agent-facing root documentation alongside the human README, the structured-JSON output discipline at workflow boundaries, and the MCP-server-as-first-class-component design pattern. The discovery of OpenClaw as prior art happened through their documentation.
- **[Dewale-A's `Agentic-Accounting-Close`](https://github.com/Dewale-A/Agentic-Accounting-Close)**: the concrete dollar-threshold materiality gate pattern and the approach of enforcing segregation of duties at the API boundary rather than as documentation.
- **[OpenClaw Airlock (`tushar5623/OpenClaw_Airlock`)](https://github.com/tushar5623/OpenClaw_Airlock)**: the GREEN/AMBER/RED/BLOCKED risk tier vocabulary and the per-action decision matrix pattern.
- **COSO 2013 Internal Control: Integrated Framework**: the five-component structure every control maps to.

Adopted prior-art patterns are cited above. FinAgent OS extends them by applying governance-first architecture to crypto-native financial infrastructure. Decision records are in [`docs/adr/`](docs/adr/).

---

## Change Control

This document is versioned in git. **In v1 and through the November 2026 release**, changes are direct commits by the single author; the November 2026 release commits were co-written with an AI coding assistant (recorded in `Co-Authored-By` lines). The history has no pull requests and no PR review record. The intended process, planned for when a second reviewer is in place, routes changes through a git pull request with named sign-off from the Process Owner of any control whose row is touched, plus a separate sign-off from the document's author, recorded in the PR's review log. **Once the AI advisory layer ships**, changes additionally route through the Rubric Refinement Gate (FAO-GOV-012): the weekly audit job aggregates outcomes, flags drift between AI advisory and human decisions, and proposes rubric changes which are then subject to the same PR + sign-off workflow. Historical versions in git provide the audit trail of how this document has evolved. Database configuration is separate from this document: since the November 2026 release (live since 2026-11-09), a change to process owners, the registry, thresholds, roles or settings needs a change reason and writes before and after images to `fao_admin_audit`, and a trigger sets `updated_at` where the table has one. In v1, which ran live until the cutover finished on 2026-11-09, those tables had no change log.

**v1.0, April 2026.** Initial publication.

**November 2026.** Control statuses and implementation text corrected to match the v1 code after two external reviews.

**November 2026, new release.** Statuses and implementation text updated to match the November 2026 release (11 live, 7 partial, 6 planned), before it was deployed. The test plan now describes the six automated test layers, CI and the manual page check. Framework wording: the Monitoring note added, reconciliation controls mapped to Control Activities, and the Preventive example updated.

**November 2026, go-live.** The November 2026 release, including dual approval, was deployed to the live system in a cutover that finished on 2026-11-09 (UTC). Deployment wording updated; no status changed (11 live, 7 partial, 6 planned). Evidence: [cutover summary](docs/evidence/cutover-2026-11-09.md).
