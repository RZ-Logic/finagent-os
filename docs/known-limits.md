# Known limits: engineering notes

These are edge cases and operating rules found while building and testing FinAgent OS. They matter to someone running, testing or changing the system. The reader-facing limits are in the [README](../README.md#-known-limitations).

## Refusal journal coverage

The refusal journal (`fao_refusal_journal`) records refusals returned by the FinAgent database functions. It does not see everything. See [ADR-0003](adr/0003-atomic-resolution-and-journal.md).

- **Failed sign-in tokens.** A request whose sign-in token fails verification is refused by the API layer (PostgREST) before any FinAgent function runs. It shows up only in platform logs.
- **Journal cap.** The journal is capped per caller per minute. Past the cap, one marker row (`JOURNAL_SUPPRESSED`) is written per minute and refusals continue.
- **Refused direct table writes.** Every application role is refused direct writes to FinAgent tables. The refused write rolls back, so it cannot be journaled from inside its own transaction. Postgres and PostgREST logs still record it. Recording these is planned.
- **Requests refused before a function runs.** PostgREST refuses an empty body, invalid JSON, GET and form-encoded calls before any function runs, and these are not journaled. None of them changes anything. This was measured on the local PostgREST only, pinned to 14.5, the live version.

## Runs, claims and timeouts

- A new n8n execution that reuses the execution id of a run still RUNNING inside its SLA window is refused at claim. If that execution then fails at any node before Respond 202 (the refused branch included), the error handler records it as pre-claim and leaves the older run alone. Past the window, the claim first fails the stale run.
- A claim that committed and then errored inside Claim Run leaves its run RUNNING until the sweep fails it as stale.
- The database cannot tell apart two executions with the same id.
- **Operating requirement.** The stale-run rule relies on n8n stopping the flagship at its 600-second `executionTimeout`, before the 900-second floor of `sla_max_execution_seconds`. That holds only if n8n's `EXECUTIONS_TIMEOUT_MAX` is at least 600. Live n8n is set to 3600, checked at the cutover.

## Notifier, sweeper and Writer

- A database error inside the notifier, or an unpublished notifier, fails the sweeper run visibly but does not count toward the notification retry limit.
- If a notice target is deactivated between an escalation and its first send, no operator alert goes out unless the notice is listed again.
- The wording of an expired escalation uses the n8n host clock.
- The sweeper's last check relies on n8n's documented branch order. `check-exports` holds the layout, and a reversed order would fail loudly, not silently.
- There is only one escalation level, and nobody is notified after a request is decided.
- **A notice may be delivered more than once.** If Slack accepts a message but the notifier's request times out, or the database write after a send fails, the attempt is recorded as failed (or not at all) and the sweep sends the notice again, up to `notify_max_attempts` + 1 sends (4 at the default of 3). Approvers can then see more than one notice for a request. Every notice links to the same page, and a decision cannot be made twice (`ALREADY_DECIDED`, `ALREADY_APPROVED`). A second SENT for the same request and notice level writes no row, so the ledger can under-count deliveries, and a resent notice adds ledger rows to the run. Repeated timeouts also count toward `notify_max_attempts` and can escalate a request whose notices did arrive.
- The Writer has no error workflow of its own. A failed Writer call fails the flagship execution, and that failure is recorded.

## Run asset list

- The flagship builds a run's asset list (`inputs.asset_scope` on STARTED) from the union of the wallet and ledger feed keys, before it reads the thresholds. The database validates the list's shape, freezes it on the run, and measures missing, duplicate and unexpected assets against it. No step compares it with the threshold table, so an asset absent from both feeds produces no record and the run can commit. Today the feeds are fixtures inside the workflow, so only a workflow edit can drop an asset; with live connectors a partial read could.

## Roles and approvals

- A role grant created at the same moment as a decision or a finalize is not waited for. This can only turn a refusal into an allow on a later decision, never the reverse.
- The role helpers refuse a client's question about another user by reading the database call stack. Any new `fao_*` function that passes a caller-chosen user id to them needs review.

## MCP

- Ids that the database checks only by pattern (asset symbols, `agent_id`) can still spell words. The MCP server marks free text as untrusted. See [`mcp/README.md`](../mcp/README.md).

## Tooling and tests

- There is no command-line tool for starting runs or for admin changes. Runs start through the MCP invoke tool. Admin changes go through the `fao_admin_*` functions with the admin's own session, or through the documented SQL recipe with a change reason.
- CI runs on the pinned Node 22 and Python 3.12. Local runs use newer versions (Node 25, Python 3.14).
- Some api and e2e tests briefly change shared demo users, roles or the test clock and then restore them. Run those layers with nothing else on the stack. See [`test/e2e/README.md`](../test/e2e/README.md).
- Approval page checks: the full flow was checked against the local stack in the built-in Chromium browser of the Claude desktop app, driven by Claude Code (an AI agent), not by a person. On live at the cutover, Claude Code did the page checks and the owner made the smoke decisions. The owner checked the live page in Chrome, Brave and Firefox on 2026-11-09. Safari (WebKit) has not been checked.

## Hosting

- n8n's own database runs postgres:16, which n8n supports for compatibility only. The owner left it as is.

## Decisions

These are owner decisions, recorded so that nobody mistakes the behaviour for a bug. The owner signed off the cutover on 2026-11-09, which accepted the build's interface changes and ADRs 0002 to 0004.

- **STANDARD review keeps one approval.** A request whose review sub-tier is STANDARD needs one approval, even for a RED agent whose registry count is two. Its ledger row says "approvals enforced 1 of configured 2". See [ADR-0004](adr/0004-dual-approval-enforced.md).
- **Stablecoin band and floor.** Stablecoin reserves are held near 105%, so the seeded USDC and USDT upper band is 1.05 (decided 2026-11-07). On live, Marcus applied it on 2026-11-08 through `fao_admin_set_threshold` with a change reason. The floor and lower band stay at 1.0000 (decided 2026-11-08), so any stablecoin under-reserve is CRITICAL, and FAO-REC-002 is inactive under the seeded thresholds.
- **Stablecoin USD materiality, shortfall only (2026-11-08).** A surplus inside the band passes however large it is. A shortfall escalates as IN_BAND_USD_MATERIAL only when ledger minus wallet exceeds `materiality_usd`. Because the seeded floor equals the band lower (1.00), BELOW_FLOOR catches any shortfall first. The rule therefore fires only under a threshold whose floor is below 1.00, which was tested offline with a threshold override, not end to end.
- **USD materiality for other assets.** BTC, ETH, SOL, XRP and ADA need a price feed to convert unit differences to USD. Until one exists, ratio checks (FAO-REC-004) cover them, and an in-band but large dollar difference on these assets is not escalated.
- **Notice window.** A request with no sent notice after 5 minutes x (`notify_max_attempts` + 1) is escalated once as NOTIFICATION_FAILED, even with no recorded attempt, and is no longer retried. That is 20 minutes at the default of 3.
- **STARTED keys set by the database.** A STARTED item whose inputs carry `invoker_id`, `invoked_via`, `reason` or `n8n_execution_id` (at any depth, in any normalised spelling) is refused and nothing is written. The database sets those four values itself from the run record. The flagship sends none of them, and `check-exports` rule `started_db_keys` holds that.
