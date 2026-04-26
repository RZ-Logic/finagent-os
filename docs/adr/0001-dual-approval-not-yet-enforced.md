# ADR-0001: Dual-Approval Enforcement Is Documented But Not Yet Wired

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-04-25 |
| **Discovered by** | Claude Opus, via MCP self-audit ([transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)) |
| **Author** | Rizwan Ahmed, ACCA · Velocyt Consulting |
| **Reviewed by** | External review pending. v1 ships with author-as-process-owner; FAO-GOV-013 separation activates when a second authenticated identity is added to `process_owners`. |
| **Supersedes** | — |
| **Superseded by** | (planned) ADR for v1.1 dual-approval state machine |

> *This is an **Architecture Decision Record** — a short document capturing an engineering choice, the situation that drove it, and the trade-offs that follow. Each ADR in this repo is numbered, dated, and supersedes or is superseded by other ADRs as the system evolves.*

---

## Context

### The shape of the gap

`agent_registry.approval_threshold` is declared in [Migration 0003](../../supabase/migrations/20260420_0003_agent_registry.sql) as:

```sql
approval_threshold INT NOT NULL DEFAULT 1 CHECK (approval_threshold >= 1)
```

The accompanying seed file ([0003_agent_registry_seed.sql](../../supabase/seeds/0003_agent_registry_seed.sql)) sets `approval_threshold = 2` for the two RED-tier agents (`fao_reserve_recon_v1` and `fao_treasury_monitor_v1`). The seed file's design notes say plainly:

> *approval_threshold follows risk tier: GREEN/AMBER = 1 approver, RED = 2 approvers.*

The flagship's policy engine, when an asset escalates to CRITICAL sub-tier, writes a `policy_rationale` string that explicitly references dual approval — for example:

> *"FAO-REC-007 ADA negative liability detected. Routed to CRITICAL HITL — Controller + CFO review required (RED tier, 2 approvers)."*

**The gap:** no code path in v1 reads `approval_threshold`. Not the [`fao_hitl_resolve` function](../../supabase/migrations/20260425_0008_fao_hitl_resolve_function.sql), not any n8n node, not any trigger. The column exists; the HITL queue inserts a row; the SoD trigger (Migration 0005b) enforces `approver_id ≠ agent_invoker_id`; the `fao_hitl_resolve` function then sets `decision = 'APPROVED'` and the workflow proceeds to write the `COMMITTED` event.

A single approver passes the SoD check and the row resolves. The `approval_threshold = 2` value is structurally inert — stored, displayed, but never queried as a gate.

### The empirical evidence

The self-audit on Apr 25, 2026 surfaced this on the most recent execution at the time. Correlation `6b57616d-57fb-4cd8-a76c-e4e17967db5b`:

| Field | Value |
|---|---|
| `agent_id` | `fao_reserve_recon_v1` |
| `risk_tier` | RED |
| `policy_outcome` (rollup) | REQUIRE_HUMAN |
| `policy_sub_tier` | CRITICAL |
| Escalated assets | USDT, SOL, ADA |
| `policy_rationale` | "...RED tier, 2 approvers... Controller + CFO review required..." |
| `agent_invoker` | Aisha Okonkwo (FP&A Lead) |
| `approver_id` (final) | Sarah Chen (Controller) — **single approval** |
| `decision` | APPROVED |
| Status | COMMITTED |

> *All named individuals in this document — Sarah Chen, Aisha Okonkwo, Marcus Patel — are seeded demo identities in the `process_owners` table (`@finagent-os.demo` email domain). They are not real Velocyt or Kraken employees. See [README §Honest Limitations — Demo identities, not production auth](../../README.md#-honest-limitations).*

The audit trail is honest. The Shadow Ledger correctly records that Sarah Chen alone approved an execution that was *named* dual-approval in its rationale text. The append-only constraint preserves the discrepancy as a permanent record. There is nothing to "fix" in the historical row — it accurately reflects what happened. The fix is in the enforcement of future rows.

### How the gap was discovered

The discovery vector matters and is preserved as evidence.

After the MCP server shipped on Apr 25, 2026, Claude Opus was given access to the FinAgent OS audit trail through the MCP read surface and asked to narrate the most recent execution in plain English. While walking through the per-asset outcomes, Claude observed the discrepancy unprompted:

> *"The policy_rationale on both SOL and ADA explicitly states 'RED tier, 2 approvers' and ADA specifically says 'Controller + CFO review required'. But this was resolved with just Sarah Chen's single approval. No CFO sign-off was collected before commit."*

Two possibilities were named: (1) the *"2 approvers"* string is documentation that the SoD guard never enforced beyond `approver_id ≠ agent_invoker_id`; or (2) the HITL queue isn't enforcing dual-approval at CRITICAL sub-tier despite policy rationale claims it should. Possibility 1 was confirmed by direct inspection of [Migration 0005b](../../supabase/migrations/20260420_0005b_hitl_queue_sod_trigger.sql) (the SoD trigger), [Migration 0008](../../supabase/migrations/20260425_0008_fao_hitl_resolve_function.sql) (the resolve function), and [the agent registry seed](../../supabase/seeds/0003_agent_registry_seed.sql). The discrepancy was real; the cause was the inert `approval_threshold` column.

> *AI surfaced the discrepancy. A human verified the cause by reading the migrations and confirming no code path queries `approval_threshold`. This is the AI-as-advisory pattern from FinAgent OS's core principle working as designed: AI is non-authoritative even in the discovery loop. The finding is not authoritative until a human verifies it against source.*

Full transcript: [claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960). Screenshot evidence preserved at [`docs/evidence/mcp/mcp_03_dual_approval_gap_surfaced.png`](../evidence/mcp/mcp_03_dual_approval_gap_surfaced.png).

### Why this is published as an ADR rather than fixed silently

The dual-approval state machine is not a one-line fix. It requires:

1. Schema changes to `hitl_queue` (`required_approvals`, `approvals_received`, plus a separate `hitl_approvals` table for individual approvals).
2. A function that increments `approvals_received` per approval and only marks `decision = 'APPROVED'` when count reaches `required_approvals`.
3. Updated `fao_hitl_resolve` semantics — first approval transitions to `IN_PROGRESS`, second approval transitions to `APPROVED`. A new `IN_PROGRESS` value is added to the `hitl_status` enum.
4. Updated Slack message UX to render *"1 of 2 approvals received"* state and pre-fill the second approver from the escalation chain.
5. Backfill of the existing `hitl_queue` rows to populate the new columns from `agent_registry.approval_threshold`.

The implementation is already in flight and lands in v1.1. The ADR exists so that no reader of this repo can mistake the v1 enforcement posture for what the policy rationale strings imply.

---

## Decision

**For v1, accept that dual-approval is named but not wired.** Specifically:

1. The `approval_threshold` column remains in `agent_registry` with `2` seeded for RED-tier agents. The value is correct as a *declaration of intent*; v1.1 will make it operative.
2. The `fao_hitl_resolve` function and the `hitl_queue_sod_guard` trigger continue to enforce only `approver_id ≠ agent_invoker_id` — single-approver SoD. This is real enforcement. It is not nothing.
3. The flagship's `policy_rationale` text continues to reference *"Controller + CFO review required"* for CRITICAL sub-tier. The text is preserved unchanged. It remains accurate as a description of the *intended* control posture, and the principle below applies to the choice not to weaken it:

> **Tighten code to match documentation, not the other way around.**
> Altering historical workflow code to weaken a control's stated description would itself be a SOX-poor move. The instinct under time pressure is to soften the docs to match what the code currently does. The opposite move — leaving the documented control posture intact and committing to bring code up to it in v1.1 — is the one that preserves audit trail integrity and signals that the gap is a v1 boundary, not a permanent design.

4. The gap is documented in this ADR and surfaced in the README's *Honest Limitations* section.
5. v1.1 will close the gap with a state machine on `hitl_queue` and supersede this ADR.

---

## Consequences

### For v1 governance posture

1. RED-tier executions at CRITICAL sub-tier are gated by **single-approver SoD only**. The first approver who is not the invoker resolves the queue.
2. The SoD enforcement is real. An invoker cannot self-approve; the trigger raises a named `FAO-GOV-004` exception. This control is genuinely active.
3. Dual-approval as a control is **named in documentation, not enforced in code**. Any external claim that v1 enforces dual-approval would be incorrect.
4. **The residual risk surface is human, not technical.** The system does what its enforcement code says it does. The gap is in the human-trust-in-documentation layer: an approver reading the rationale text *"Controller + CFO review required"* might rationally believe their single approval is insufficient, when in v1 it actually is. A reviewer relying on the rationale string as a description of what the system enforces would form an incorrect model of the control posture. Closing that mismatch — making the rationale text and the code agree — is what v1.1 enforces.

### For the audit trail

1. All 56 existing `shadow_ledger` rows accurately record what happened. No retroactive correction is needed; the append-only constraint forbids it anyway.
2. Future RED-tier CRITICAL executions in the v1 window (between this ADR and v1.1 shipping) will continue to resolve on single approval. This is documented behaviour, not regression.
3. The four pending HITL rows in the queue at time of writing will resolve under v1 single-approver semantics if approved before v1.1 lands. No action required.

### For v1.1 — the migration plan

A new migration `<TBD>_0009_dual_approval_state_machine.sql` will:

```sql
-- Add the count-tracking columns
ALTER TABLE public.hitl_queue
  ADD COLUMN required_approvals  INT NOT NULL DEFAULT 1
    CHECK (required_approvals >= 1),
  ADD COLUMN approvals_received  INT NOT NULL DEFAULT 0
    CHECK (approvals_received >= 0
      AND approvals_received <= required_approvals);

-- New table for individual approval records
CREATE TABLE public.hitl_approvals (
  approval_id     BIGSERIAL PRIMARY KEY,
  hitl_id         BIGINT      NOT NULL REFERENCES public.hitl_queue(hitl_id),
  approver_id     UUID        NOT NULL REFERENCES public.process_owners(id),
  approved_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  decision_notes  TEXT,
  UNIQUE (hitl_id, approver_id)  -- one approver, one approval per HITL row
);

-- Backfill required_approvals from agent_registry on existing PENDING rows
UPDATE public.hitl_queue h
   SET required_approvals = ar.approval_threshold
  FROM public.agent_registry ar
 WHERE h.agent_id = ar.agent_id
   AND h.decision = 'PENDING';
```

The `fao_hitl_resolve` function will be replaced with `fao_hitl_record_approval` which (a) writes a row to `hitl_approvals`, (b) increments `hitl_queue.approvals_received`, (c) only sets `decision = 'APPROVED'` when `approvals_received = required_approvals`, and (d) only writes the `HITL_RESOLVED` shadow_ledger event at full-approval. The intermediate state is `IN_PROGRESS` — a new value to be added to the `hitl_status` enum.

The Slack message UX will surface *"Approval 1 of 2 received — awaiting CFO sign-off"* in the body, with the second approver's name pre-filled if escalation chain navigation resolves cleanly.

---

## References

- [MCP self-audit transcript (Apr 25, 2026)](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960) — Claude Opus discovering the gap
- [`docs/evidence/mcp/mcp_03_dual_approval_gap_surfaced.png`](../evidence/mcp/mcp_03_dual_approval_gap_surfaced.png) — screenshot of the surfacing turn
- [Migration 0003 — `agent_registry`](../../supabase/migrations/20260420_0003_agent_registry.sql) — declares `approval_threshold`
- [Migration 0005b — `hitl_queue` SoD trigger](../../supabase/migrations/20260420_0005b_hitl_queue_sod_trigger.sql) — current single-approver enforcement
- [Migration 0008 — `fao_hitl_resolve` function](../../supabase/migrations/20260425_0008_fao_hitl_resolve_function.sql) — current resolution logic, single approval
- [Agent registry seed](../../supabase/seeds/0003_agent_registry_seed.sql) — sets `approval_threshold = 2` for RED-tier agents
- Root [README.md](../../README.md) — *Honest Limitations* section references this ADR
