# ADR-0003: Resolution in One Transaction; Refusals Journaled Where They Happen

| | |
|---|---|
| **Status** | Accepted (owner sign-off 2026-11-09, with the cutover). Deployed 2026-11-09. |
| **Date** | 2026-11-07 |
| **Author** | Rizwan Ahmed, ACCA · Velocyt Consulting |
| **Supersedes** | None |
| **Superseded by** | None |

## Context

In v1 a human decision and the ledger entries that follow it were separate writes from n8n. A failure between them could leave a decided request with no commit record, or a commit with no decision. The rollup that chose the run outcome existed in more than one place. Refused calls left no trace, so an auditor could not see attempts that the controls stopped.

## Decision

1. **Decide in one transaction.** `fao_hitl_decide` writes the decision, HITL_RESOLVED, the rollup and COMMITTED (or COMMIT_BLOCKED when the agent or invoker is no longer active) in one transaction. Either all of it is stored or none of it. A decision at or after the deadline is refused 410 `EXPIRED`.
2. **Create the request in one transaction.** `fao_run_finalize` writes the rollup, the HITL request, HITL_REQUESTED and the run state change together.
3. **One rollup, in SQL.** The run outcome is the worst asset's, computed by one database function; the workflow computes per-asset outcomes only.
4. **Expiry is not a commit.** The five-minute sweep expires an overdue request and closes the run EXPIRED with HITL_EXPIRED as the expiry record (status FAILURE, `run_state` EXPIRED, `committed` false), together with one TIMEOUT escalation unless the request already has one. It never writes COMMITTED for it (COMMIT_BLOCKED only when the audit chain is incomplete), and the run summary view never counts such a row as committed.
5. **Refusals journaled in the same transaction.** Every refusal a FinAgent function returns writes a `fao_refusal_journal` row in the transaction that refuses, with the actor from the session, the database role, the target, the code and a fixed message. A cap per actor and database role (`journal_cap_per_minute`, default 20) writes one JOURNAL_SUPPRESSED row for the rest of that minute instead of flooding; every attempt is still refused. The sweep's GRANTS_DRIFT and TEST_CLOCK_SET rows are exempt.
6. **Ledger writes only through functions.** `fao_ledger_append_batch` stores a batch all or none with database-set timestamps and context; direct INSERT, UPDATE, DELETE and TRUNCATE are refused for every application role.

## Why the direct-write journal is deferred

A direct table write that a role is not allowed to make is stopped by a missing privilege or by a trigger that raises, and the error rolls back its transaction, so a journal row written in it would roll back too. Recording those refusals needs a write outside the transaction (for example dblink), which adds a connection, a credential and a failure mode. It is planned for a later release. Until then only refusals returned by FinAgent functions are journaled ([known limits](../known-limits.md#refusal-journal-coverage)); Postgres and PostgREST logs still record the refused statements.

## The test clock

Deadlines use `fao_private.clock()`: `now()` plus an offset stored in the owner-only table `fao_private.test_clock`. Tests move the offset to cross deadlines without waiting. No client or workflow role can write it, and the sweep journals a non-zero offset as TEST_CLOCK_SET (at most once per 24 hours for the same offset), so a clock left set on a live project is visible.

## Consequences

- An n8n failure can no longer split a decision from its commit; the worst case is a refused or failed call that changes nothing and is journaled.
- Requests PostgREST refuses before a function runs (empty or invalid JSON, wrong method) are not journaled ([known limits](../known-limits.md#refusal-journal-coverage)).
- The database owner can still disable triggers or edit rows; there is no independent or write-once evidence store yet.
