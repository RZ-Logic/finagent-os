# ADR-0001: Dual-Approval Enforcement Is Documented But Not Yet Wired

| | |
|---|---|
| **Status** | Superseded by ADR-0004 (2026-11-08): dual approval was built and tested on branch `phase2-5-core-2026-11-07` and deployed 2026-11-09. Kept as the record. |
| **Date** | 2026-04-25 (decision); 2026-11 (update) |
| **Discovered by** | Claude Opus, via MCP self-audit ([transcript](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960)) |
| **Author** | Rizwan Ahmed, ACCA · Velocyt Consulting |
| **Reviewed by** | External review pending. Two external reviews of v1 (November 2026) corrected parts of this ADR; see the addendum. |
| **Supersedes** | None |
| **Superseded by** | [ADR-0004](0004-dual-approval-enforced.md) |

> *This is an **Architecture Decision Record**: a short document capturing an engineering choice, the situation that drove it, and the trade-offs that follow. Each ADR in this repo is numbered, dated, and supersedes or is superseded by other ADRs as the system evolves.*

---

## Where things stand (2026-11)

- **Live** ran v1 until the cutover finished on 2026-11-09. Everything in v1's description below is what the live system did until then.
- **The phases 2 to 5 core** was built and tested on the branch `phase2-5-core-2026-11-07` (local Supabase and a local n8n) and deployed to live on 2026-11-09. It binds the invoker and the approver to their own Supabase Auth sessions. At the time of the core build (2026-11-07) it did not enforce dual approval.
- **At the time of the core build, dual approval was excluded from the core.** It was the last planned edit. The core left the hooks for it (see "How dual approval plugs in later"); no part of it was built then.
- **Dual approval was built on the branch (2026-11-08, [ADR-0004](0004-dual-approval-enforced.md)) and deployed with the core on 2026-11-09.** CRITICAL review needs the configured count (two for the RED flagship) from different approvers, never the invoker, each through an approver grant made before the request, not by the invoker and not by another approver of it; one rejection closes the request.

The 2026-04-25 context and decision are kept below as the record. The v1.1 implementation sketch that used to follow them has been removed, because its design no longer fits the schema (see the addendum). The earlier text is in git history.

---

## Context (2026-04-25, v1)

### The shape of the gap

`agent_registry.approval_threshold` is declared in [Migration 0003](../../supabase/migrations/20260420_0003_agent_registry.sql) as:

```sql
approval_threshold INT NOT NULL DEFAULT 1 CHECK (approval_threshold >= 1)
```

The accompanying seed file ([0003_agent_registry_seed.sql](../../supabase/seeds/0003_agent_registry_seed.sql)) sets `approval_threshold = 2` for the two RED-tier agents (`fao_reserve_recon_v1` and `fao_treasury_monitor_v1`). The seed file's design notes say plainly:

> *approval_threshold follows risk tier: GREEN/AMBER = 1 approver, RED = 2 approvers.*

The flagship's policy engine, when an asset escalates to CRITICAL sub-tier, writes a `policy_rationale` string that explicitly references dual approval, for example:

> *"FAO-REC-007 ADA negative liability detected. Routed to CRITICAL HITL — Controller + CFO review required (RED tier, 2 approvers)."*

**The gap:** no code path in v1 reads `approval_threshold`. Not the [`fao_hitl_resolve` function](../../supabase/migrations/20260425_0008_fao_hitl_resolve_function.sql), not any n8n node, not any trigger. The column exists; the HITL queue inserts a row; the SoD trigger (Migration 0005b) enforces `approver_id ≠ agent_invoker_id`; the `fao_hitl_resolve` function then sets `decision = 'APPROVED'` and the workflow proceeds to write the `COMMITTED` event.

A single approver passes the SoD check and the row resolves. The `approval_threshold = 2` value is structurally inert: stored, displayed, but never queried as a gate.

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
| `approver_id` (final) | Sarah Chen (Controller), **single approval** |
| `decision` | APPROVED |
| Status | COMMITTED |

> *All named individuals in this document (Sarah Chen, Aisha Okonkwo, Marcus Patel) are seeded demo identities in the `process_owners` table (`@finagent-os.demo` email domain). They are not real Velocyt or Kraken employees. See [README §Known Limitations](../../README.md#-known-limitations).*

The audit trail is honest. The Shadow Ledger correctly records that Sarah Chen alone approved an execution that was *named* dual-approval in its rationale text. The append-only constraint preserves the discrepancy as a permanent record. There is nothing to "fix" in the historical row; it accurately reflects what happened. The fix is in the enforcement of future rows. (Addendum item 2 narrows this paragraph.)

### How the gap was discovered

The discovery vector matters and is preserved as evidence.

After the MCP server shipped on Apr 25, 2026, Claude Opus was given access to the FinAgent OS audit trail through the MCP read surface and asked to narrate the most recent execution in plain English. While walking through the per-asset outcomes, Claude observed the discrepancy unprompted:

> *"The policy_rationale on both SOL and ADA explicitly states 'RED tier, 2 approvers' and ADA specifically says 'Controller + CFO review required'. But this was resolved with just Sarah Chen's single approval. No CFO sign-off was collected before commit."*

Two possibilities were named: (1) the *"2 approvers"* string is documentation that the SoD guard never enforced beyond `approver_id ≠ agent_invoker_id`; or (2) the HITL queue isn't enforcing dual-approval at CRITICAL sub-tier despite policy rationale claims it should. Possibility 1 was confirmed by direct inspection of [Migration 0005b](../../supabase/migrations/20260420_0005b_hitl_queue_sod_trigger.sql) (the SoD trigger), [Migration 0008](../../supabase/migrations/20260425_0008_fao_hitl_resolve_function.sql) (the resolve function), and [the agent registry seed](../../supabase/seeds/0003_agent_registry_seed.sql). The discrepancy was real; the cause was the inert `approval_threshold` column.

> *AI surfaced the discrepancy. A human verified the cause by reading the migrations and confirming no code path queries `approval_threshold`. This is the AI-as-advisory pattern from FinAgent OS's core principle working as designed: AI is non-authoritative even in the discovery loop. The finding is not authoritative until a human verifies it against source.*

Full transcript: [claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960). Screenshot evidence preserved at [`docs/evidence/mcp/mcp_03_dual_approval_gap_surfaced.png`](../evidence/mcp/mcp_03_dual_approval_gap_surfaced.png).

### Why this is published as an ADR rather than fixed silently

Dual approval is not a one-line fix. It needs a record of each approval, a count checked before the request is decided, an approval page and notice that show partial progress, and a rule for requests already pending when it lands. The ADR exists so that no reader of this repo can mistake the v1 enforcement posture for what the policy rationale strings imply.

---

## Decision (2026-04-25)

**For v1, accept that dual-approval is named but not wired.** Specifically:

1. The `approval_threshold` column remains in `agent_registry` with `2` seeded for RED-tier agents. The value is correct as a *declaration of intent*.
2. In v1, the `fao_hitl_resolve` function and the `hitl_queue_sod_guard` trigger enforce only `approver_id ≠ agent_invoker_id`: single-approver SoD on recorded identities (see addendum items 3 and 4).
3. The flagship's `policy_rationale` text continues to reference *"Controller + CFO review required"* for CRITICAL sub-tier. The text is preserved unchanged. It remains accurate as a description of the *intended* control posture, and the principle below applies to the choice not to weaken it:

> **Tighten code to match documentation, not the other way around.**
> Altering historical workflow code to weaken a control's stated description would itself be a SOX-poor move. The instinct under time pressure is to soften the docs to match what the code currently does. The opposite move, leaving the documented control posture intact and committing to bring code up to it, is the one that preserves audit trail integrity and signals that the gap is a boundary, not a permanent design.

4. The gap is documented in this ADR and surfaced in the README's [Known Limitations](../../README.md#-known-limitations) section.
5. A later release closes the gap and supersedes this ADR. As of 2026-11, that release is the last planned edit, after the identity work below.

---

## Consequences

### For v1 (live until the cutover on 2026-11-09)

1. RED-tier executions at CRITICAL sub-tier are gated by **single-approver SoD only**. The first approver who is not the recorded invoker resolves the queue.
2. Same-identity self-approval through `fao_hitl_resolve` raises a named `FAO-GOV-004` exception. Neither identity is authenticated in v1 (addendum items 3 and 4).
3. Dual-approval as a control is **named in documentation, not enforced in code**. Any external claim that v1 enforces dual-approval would be incorrect.
4. An approver reading *"Controller + CFO review required"* might believe their single approval is insufficient, when in v1 it is enough. A reviewer relying on the rationale string would form an incorrect model of the control posture. The residual risk is also technical (addendum item 5).

### For the audit trail

1. The existing `shadow_ledger` rows record what the system was told: the approver named in each approval request. No retroactive correction is made; the append-only constraint forbids it anyway (addendum item 2).
2. RED-tier CRITICAL executions continued to resolve on a single approval until dual approval was deployed on 2026-11-09. This was documented behaviour, not a regression.
3. At the cutover, migration 0013 closed the 4 requests still PENDING from v1 as EXPIRED; none was decided under the new rules.

---

## Identity and segregation of duties in the phases 2 to 5 core

This is what the core does. It was tested locally (pgTAP, API, MCP, unit and n8n end-to-end layers) and deployed on 2026-11-09 together with dual approval, which changes the approval counts below ([ADR-0004](0004-dual-approval-enforced.md)).

### Invoker

- A run starts through `fao_run_start`. The invoker is the signed-in Supabase Auth user (`auth.uid()`); no identity is taken from a payload. The caller must be an active process owner holding the `invoker` role for the agent.
- The risk tier is copied from the registry; the registry status, tier and per-hour rate limit are checked at run start. A replay of an idempotency key whose run expired is refused EXPIRED and counts toward the same per-hour limit; over the limit it is refused RATE_LIMITED (patch round 6, P5).
- The start returns a single-use run token, stored only as its hash. The n8n flagship claims the run with that token (`fao_run_claim`), so a run cannot start in n8n without a database run record.
- The invoker fields on the STARTED ledger row are set by the database from the run record. A STARTED event whose inputs carry `invoker_id`, `invoked_via`, `reason` or `n8n_execution_id` (at any depth, under any normalised spelling) is refused `INVALID_INPUT` and nothing is written; the flagship sends none of them (owner decision 2026-11-08, patch round 7, O3).

### Approver

- A decision is recorded only through `fao_hitl_decide`. The approver is the signed-in user (`auth.uid()`), who must hold the `approver` role for the agent.
- The invoker is refused (`SOD_SELF_APPROVAL`, 403). The row guard on `hitl_queue` re-checks this for every role, the database owner included, and the CHECK `hitl_no_self_approval` keeps `approver_id <> agent_invoker_id` on new rows (it is `NOT VALID`, so v1 history rows are not rechecked).
- A decision at or after the deadline is refused. A decided request cannot be changed by any role. A request left undecided past its deadline is expired by the sweep: HITL_EXPIRED is its expiry record (a HITL_ESCALATED row, or COMMIT_BLOCKED on a broken chain, can follow it) and no COMMITTED row is written (patch round 6, P3).
- The decision, its HITL_RESOLVED ledger row and the COMMITTED (or COMMIT_BLOCKED) row are written in one transaction. Refusals the function returns are recorded in the refusal journal (above a per-minute cap, one marker row per minute).
- An APPROVED decision is not committed when the agent is no longer ACTIVE (`AGENT_NOT_ACTIVE`) or the run's invoker is no longer an active owner holding the invoker grant (`INVOKER_NOT_ACTIVE`). The decision stands, COMMIT_BLOCKED is written and the run is FAILED. The same invoker check runs at finalize.
- The v1 path is retired: `fao_hitl_resolve` now raises `FAO-GOV-004 fao_hitl_resolve is superseded by fao_hitl_decide`, and the v1 trigger `hitl_queue_sod_guard` is dropped in favour of the guards above.

### Approval counts at the core build (2026-11-07, before ADR-0004)

- Each request freezes `configured_approvals` (the registry's `approval_threshold` at request time: 2 for the flagship) and `enforced_approvals` (always 1 at the time).
- HITL_RESOLVED carries `approvers[]` (one element at the time) and both counts, and its rationale reads `approvals enforced 1 of configured 2` for the flagship. The gap was visible on every request decided before ADR-0004.

### Still outside the control

- The database owner, holders of the `postgres` password and holders of platform admin or secret keys can change identities or disable triggers.
- There is no evidence store independent of the database owner, so the ledger is not administrator-proof. Independent evidence storage is planned.
- There is no second factor yet. A stored password is enough to approve for any user who holds the approver role. A TOTP second factor is planned.
- In the public demo one person holds every demo identity. The controls bind actions to identities; they cannot prove those identities are different people.
- Approver authority beyond role membership (rank, limits per amount) is not modelled. It is a prerequisite for dual approval.

---

## How dual approval plugs in later

Not built in the core (2026-11-07); [ADR-0004](0004-dual-approval-enforced.md) records how it was built on these hooks. The core leaves these hooks so dual approval adds code without reworking it:

- **Identity:** every decision is keyed by the approver's own session, so two approvals are two distinct user ids.
- **Counts:** `configured_approvals` and `sub_tier` are already frozen on every request. The dual-approval migration sets `enforced_approvals` from its rule for new requests; requests still PENDING when it lands keep 1.
- **Approvals table:** a new append-only `hitl_approvals` table, one row per approver per request (unique on request and approver), with the same guards as `hitl_queue`.
- **Decide:** `fao_hitl_decide` has a single update step where the approvals table plugs in. The session, role, deadline and self-approval checks before it already apply to every approver, so the invoker can never supply either approval and one user cannot count twice.
- **No new decision state:** the request stays PENDING until the count is met. The `IN_PROGRESS` value from the 2026-04-25 sketch is not needed.
- **Page and notices:** the approval page and the notifier gain a partial-progress view; the approval link, sign-in and RPC names stay.

---

## References

- [MCP self-audit transcript (Apr 25, 2026)](https://claude.ai/share/5f0eb294-e658-42b5-a876-8164a0049960): Claude Opus discovering the gap
- [`docs/evidence/mcp/mcp_03_dual_approval_gap_surfaced.png`](../evidence/mcp/mcp_03_dual_approval_gap_surfaced.png): screenshot of the surfacing turn
- [Migration 0003, `agent_registry`](../../supabase/migrations/20260420_0003_agent_registry.sql): declares `approval_threshold`
- [Migration 0005b, `hitl_queue` SoD trigger](../../supabase/migrations/20260420_0005b_hitl_queue_sod_trigger.sql): v1 single-approver check (dropped by 0013, deployed 2026-11-09)
- [Migration 0008, `fao_hitl_resolve` function](../../supabase/migrations/20260425_0008_fao_hitl_resolve_function.sql): v1 resolution logic (superseded by 0015, deployed 2026-11-09)
- [Migration 0013, guards and policies](../../supabase/migrations/20261107_0013_guards_and_policies.sql): row guard, retired v1 trigger, closing of v1 PENDING requests
- [Migration 0014, run RPCs](../../supabase/migrations/20261107_0014_run_rpcs.sql): `fao_run_start`, `fao_run_claim`, `fao_run_finalize`
- [Migration 0015, HITL RPCs](../../supabase/migrations/20261107_0015_hitl_rpcs.sql): `fao_hitl_decide`, `fao_hitl_get`
- [Agent registry seed](../../supabase/seeds/0003_agent_registry_seed.sql): sets `approval_threshold = 2` for RED-tier agents
- Root [README.md](../../README.md): Known Limitations section references this ADR

---

## Addendum (2026-11): review corrections

Two external reviews of v1 (November 2026) found that several statements in this ADR describe a stronger control than the v1 code provides. The corrections below apply to v1, which was live until the cutover on 2026-11-09. Line numbers in the review findings referred to the 2026-04-25 text; the items below name the statements instead.

### Statements that are not accurate as of v1

The root cause is the same for each: in v1, approver identity comes from the approval request, and the invoker is a fixed demo identity set by the flagship workflow. Neither is bound to an authenticated session, so the v1 control compares recorded identities; it does not bind identities to people. The v1 approval endpoints were demo only: unauthenticated and not hardened for production. The phases 2 to 5 core binds both identities to sessions (section above); live kept the v1 behaviour until the cutover on 2026-11-09, when the v1 approval handler was archived (its webhooks return 404).

1. **Reviewed by**, the former text *"FAO-GOV-013 separation activates when a second authenticated identity is added to `process_owners`"*. The seed already contains three demo identities. Adding identities does not activate separation; what is missing in v1 is binding the approver and invoker to authenticated sessions, and change review by someone other than the author.
2. **"The audit trail is honest"** (and *"accurately record what happened"*). The v1 ledger accurately records the approver identity named in the approval request. It does not show that the named person made the approval.
3. The former Decision text *"This is real enforcement. It is not nothing."* For approvals made through `fao_hitl_resolve`, the trigger does block an approval where the recorded approver equals the recorded invoker. Because neither identity is authenticated in v1, that check does not establish who invoked or who approved.
4. The former Consequences text *"This control is genuinely active."* Accurate only in the narrow sense of item 3: same-identity self-approval is blocked. It is not an identity-bound segregation-of-duties control in v1.
5. The former Consequences text *"The residual risk surface is human, not technical. The system does what its enforcement code says it does."* In v1 the residual risk is also technical: the unbound identities and the unauthenticated approval endpoints described above.

### The 2026-04-25 v1.1 sketch

The removed sketch proposed `required_approvals` and `approvals_received` columns, a `hitl_approvals` table, a replacement for `fao_hitl_resolve`, and a new `IN_PROGRESS` value. The reviews found two problems, which is why it was removed:

- A `hitl_approvals` table with `UNIQUE (hitl_id, approver_id)` alone would not stop one person supplying two approvals while approver identity is not authenticated. Dual approval depends on identity binding landing first. The core does that (deployed 2026-11-09).
- The `IN_PROGRESS` state does not fit the schema. The `hitl_queue` column is `decision`, of enum `hitl_decision`, not `hitl_status`; `hitl_status` is the Shadow Ledger enum. The coherence CHECK allows only defined pairs of decision, approver and decided time. The plan above keeps the request PENDING until the count is met, so no new value is needed.

The core also does not add `required_approvals` or `approvals_received` columns; requests record `configured_approvals` and `enforced_approvals` instead.

### Link correction

The README section this ADR cites is titled **Known Limitations**: [README §Known Limitations](../../README.md#-known-limitations). The earlier references to *Honest Limitations* meant the same section and now use its title.

### Migration comments

Some v1 SQL migration comments describe stronger guarantees than the v1 code provides. Examples: Migration 0004 says the append-only trigger has *"no bypass"*; it rejects row-level UPDATE and DELETE but is not an administrator-proof boundary. The Migration 0005 table and column comments still say SoD is *"enforced at RLS layer"* after Migration 0005c moved enforcement to the trigger, and the 0005b comments describe the trigger as complementary to that RLS policy. The Migration 0008 header says the trigger fires correctly *"regardless of who claims to be approving"*, which holds only for the same-identity case in item 3. These migration files are applied history and are left unchanged. Migration 0013 (deployed 2026-11-09) replaces the `hitl_queue`, `approver_id` and `agent_invoker_id` comments with ones that describe the current controls; this addendum and [SOX-MAPPING.md](../../SOX-MAPPING.md) carry the corrected v1 statements.
