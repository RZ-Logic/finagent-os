# ADR-0004: Dual Approval Enforced for CRITICAL Review

| | |
|---|---|
| **Status** | Accepted pending owner sign-off. Built and tested locally on branch `phase2-5-core-2026-11-07` (dual approval run 0, 2026-11-08; run again after fix rounds 1 and 2, fix round 2 at 2026-11-08T06:04:54Z with 2313 of 2313 passing, and again after the doc fixes at 2026-11-08T17:29:49Z, 2313 of 2313); deployed 2026-11-09 inside the core cutover. |
| **Date** | 2026-11-08 |
| **Author** | Rizwan Ahmed, ACCA · Velocyt Consulting |
| **Supersedes** | [ADR-0001](0001-dual-approval-not-yet-enforced.md) |
| **Superseded by** | None |

## Context

ADR-0001 recorded that `agent_registry.approval_threshold = 2` for RED-tier agents and the rationale text "Controller + CFO review required" were stored, but one approval decided every request. The phases 2 to 5 core bound the invoker and the approver to their own Supabase Auth sessions and left hooks for dual approval: every request freezes `configured_approvals`, `enforced_approvals` and `sub_tier`, HITL_RESOLVED carries an `approvers` list, and `fao_hitl_decide` has a single update step. This ADR records how dual approval was built on those hooks.

## Decision

The owner made four decisions on 2026-11-08 (final):

1. **DA-1, which requests need two approvals.** A request needs the configured count (the registry `approval_threshold` at request time: two for the RED flagship) only when its review sub-tier is CRITICAL. STANDARD review keeps one approval. The count is frozen at request creation. Requests still PENDING when the change lands keep one.
2. **DA-2, rejection.** Any one eligible approver's REJECT closes the request as REJECTED at once, even after an earlier APPROVE.
3. **DA-3, who counts.** Any distinct users who hold the approver role for the agent, never the invoker; one user counts once. Named roles (Controller, CFO) are not modelled.
4. **DA-4, qualifying grants.** An approval counts only through an approver grant that is unrevoked, covers the agent, was made strictly before the request was opened, and was not made by the invoker. A user's approval counts only if at least one such grant was not made by another approver of the same request. A user with no qualifying grant can neither approve nor reject; the co-approver rule applies to approving and counting, not to rejecting.

How it is built (DUAL-APPROVAL.md, migrations `0018` to `0020`):

- A new append-only table `public.hitl_approvals` holds one row per approver per request. Client roles can write it only through `fao_hitl_decide`, from the approver's own session, and its guard applies to every role, the owner included. The guards take the user from the session's `auth.uid()`, so an owner-class session that sets its own JWT claims can insert approvals and decide as any eligible approver; the owner is outside the control (FAO-GOV-001).
- `fao_private.approver_qualifies` states the DA-4 test once. `fao_private.counted_approvals` applies the role check, the invoker exclusion and DA-4 to every row on every call. The decide check at step 10, `viewer_can_decide` in `fao_hitl_get` and both row guards use the same helper.
- `fao_hitl_decide` returns `AWAITING_FURTHER_APPROVAL` (and writes HITL_APPROVAL_RECORDED) while the counted approvals stay below the enforced count, and decides at the approval that reaches it. A repeat APPROVE is `ALREADY_APPROVED` unless the counted approvals are already complete.

Design choices C1 to C18 (DUAL-APPROVAL.md 1.3), in short:

- **C1, C2:** every APPROVE writes one approval row (single-approval requests included); no new decision state, the request stays PENDING until the count is reached.
- **C3:** an approval counts only while its approver is eligible, checked when the count is taken and under share locks at a decision.
- **C4, C5:** an approver may reject after approving; a second APPROVE writes no row and is refused, except in the restore case where it decides.
- **C6, C7, C8:** a partial approval commits nothing, so the agent, invoker and chain gates run only at the deciding call; every core envelope and the HITL_RESOLVED key set stay as they were, with a rationale suffix only when more than one approval is enforced.
- **C9, C10:** new ledger rows use only already reserved keys, so the run path does not change; three new migrations replace functions with `CREATE OR REPLACE` and leave `0009` to `0017` as built.
- **C11, C12:** the `hitl_queue` row guard requires the counted approvals for APPROVED and the DA-1 count at INSERT; decided views keep their short form.
- **C13, C14:** no new notification kind (the REQUESTED and ESCALATED notices gain fixed lines); the sweep is unchanged and a partially approved request expires like any other.
- **C15:** the run summary and the MCP report recorded approvals, never an eligibility count.
- **C16:** `rollback_dual_approval.sql` refuses while a pending request needs more than one approval.
- **C17:** `counted_approvals` is PL/pgSQL, so the role helpers accept its calls about other users.
- **C18:** the locks taken before any write wait at most 2 seconds; a timeout returns `BUSY`.

## Consequences

- The flagship's CRITICAL review now needs two approvals from two signed-in identities, neither of them the invoker, each holding a grant made before the request by someone other than the invoker and other than the co-approver. Any one rejection closes it. The live smoke run on 2026-11-09 decided a CRITICAL request with two approvals (Sarah, Marcus) and refused the invoker's own approval (`SOD_SELF_APPROVAL`). The owner entered both approvals and the rejection, signed in as each demo identity in turn, so the smoke proves two distinct identities on live, not two people (DL-8).
- An admin who approves can no longer supply the second approval by granting the approver role to another identity directly, before or during the request. An indirect chain still works: if, before the request, the admin makes a second identity an admin and that identity grants the approver role to a third, the third identity's approval counts, because its granter did not approve the request (DL-8). Every grant records who made it and when.
- STANDARD review and requests created before dual approval landed keep one approval.
- Each landing path (inside the core cutover, or after the core is live) is a runbook the owner approves step by step (BUILD-CORE 9.10). DA-4 applies at decision time, so on the later path a holder of a grant made after a pending request opened, or made by its invoker, can no longer decide that request; the pre-flight lists those grants.

## Known limits

From KNOWN-LIMITS section 6 (wording in that file):

- **DL-1** Named roles (Controller, CFO) are not modelled; any two eligible approvers count.
- **DL-2** STANDARD review keeps one approval, also for a RED agent configured for two.
- **DL-3** Requests created before dual approval landed keep one enforced approval.
- **DL-4** Nothing refuses a request that needs more approvals than there are eligible approvers; it can only be rejected or expire, and the notice warns. The warning counts approver-role holders, not DA-4 qualifying grants, so it can miss a shortfall.
- **DL-5** No notice is sent when a partial approval is recorded.
- **DL-6** An approval counts only while its approver is eligible; a reactivated owner counts again, a grant made again while the request is pending does not.
- **DL-7** An approver can reject after approving.
- **DL-8** Two identities, not proven two people: there is no second factor, and in the public demo one person holds every demo identity.
- **DL-9** The MCP sees recorded approvals, not counted ones.
- **DL-10** Rollback waits for pending two-approval requests, and the approval rows are not restored after it.
- **DL-11 (closed by DA-4)** The grant-timing and grant-author gap is closed. What remains is DL-8, and the rule trusts `granted_at`, `granted_by` and `created_at` as FinAgent writes them; an owner-class SQL session can write other values, as it can on every guarded table.
