# `test/e2e/`: n8n end-to-end layer

Real n8n executions of the exported workflows against the local Supabase stack. Local only: every URL and host is checked before anything is sent (`guard.mjs`), Slack is a fake, and nothing here can reach live Supabase, live n8n or Slack.

## Run it

```
node scripts/test-all.mjs --no-reset --layer e2e   # strict pass rules, report in .local/reports/e2e.log
npm run test:e2e                                   # the same layer without the summary table
npm run e2e:up                                     # rebuild and start the instance only
node scripts/e2e-n8n.mjs test                      # rerun the tests against the running instance
npm run e2e:down                                   # remove the containers and the volume
```

`npm test` includes the layer (it runs after `api`). It needs Docker and the local stack (`npm run sb:start`, `npm run db:reset` once). One run takes about 55 seconds: about 35 to build, import, publish and start n8n, about 20 for the twelve tests.

## What `scripts/e2e-n8n.mjs up` builds

| Piece | Detail |
|---|---|
| n8n | `n8nio/n8n` at the exact version in `test/env/versions.json` (2.46.6), container `finagent-e2e-n8n`, on docker network `supabase_network_finagent-os-local`, port `127.0.0.1:5679` |
| fake Slack | `fake-slack.mjs` in container `finagent-e2e-slack`, sharing n8n's network namespace, so the local setting `slack_api_base_url = http://127.0.0.1:8099/api` reaches it with no database change; control API on `127.0.0.1:58099` (`/_e2e/requests`, `/_e2e/mode`, `/_e2e/reset`) |
| state | a new docker volume `finagent-e2e-n8n-data` every run; a new `N8N_ENCRYPTION_KEY`, invoke header key and fake Slack token every run, in `.local/e2e/secrets.json` (git-ignored) |
| credentials | the three the exports name, with their exact ids and names: `FAO Postgres (fao_workflow)` (host `supabase_db_finagent-os-local:5432`, user `fao_workflow`, password from `.local/test-users.json`, SSL off), `FAO Invoke Header Auth` (`X-FAO-Invoke-Key`), `FAO Slack Bot` (fake token) |
| import | `n8n import:credentials`, `n8n import:workflow --separate`, then `n8n publish:workflow --id=...` for each workflow, in a one-shot container with no network, before the server starts |

Settings are in `docker/n8n/e2e.env`, one comment per group: UTC timezone, telemetry, version checks, templates and community packages off, no editor and no public API (so no n8n user is ever created), Code nodes on the built-in JavaScript task runner with environment access blocked (the exports read no variables and load no modules), every execution kept so the tests can read it.

## What is imported

The five production exports in `workflows/` are imported unchanged. `variants.mjs` adds e2e-only copies, built at import time and never written back:

- **Flagship fixture variants** (`inband`, `blocked`, `badinput`, `markup`, `failnode`). The flagship keeps its fixtures as literals in the Init Execution Code node, so other balances need another copy. Each variant replaces exactly the `wallet_data`, `ledger_data` and `fixture_metadata` blocks and gets its own id, name and webhook path; every other node and setting, `errorWorkflow` included, is the export's, except that the `markup` copy's Claim Run names the local-only agent `fao_e2e_markup_v1` instead of the flagship's, because a claim must name the agent its workflow serves (fix round 2 R08). Review scenarios (S02 to S04, S07, S08) use the unchanged flagship and its own fixtures.
- **On-demand sweeper.** The production sweeper is imported but not published: its five-minute schedule would sweep the shared local stack under other test runs, and `n8n execute` cannot start a schedule-triggered workflow. The copy swaps only the Schedule Trigger for a header-auth Webhook (`responseMode: lastNode`).
- Execution ids are not moved: each fresh instance numbers its executions from 1, so a rerun without a reset reuses ids that earlier runs on the stack hold. Since fix round 2 R09 the database allows that (finding 1), so every rerun exercises the fix; `.local/e2e/state.json` records the highest id already claimed (`execution_ids_already_claimed_up_to`).

## Scenarios (`n8n.e2e.test.mjs`)

Each run starts with `fao_run_start` as the signed-in invoker through PostgREST, and only the token is POSTed to the production webhook, as the MCP invoke tool does. A is Aisha, B is Sarah, C is Marcus. Assertions read the ledger, run, request and notification rows as the owner, the fake Slack record, and n8n's own execution records (`n8n-executions.cjs`, read-only). Every test closes the request it opens. Evidence per scenario goes to `.local/e2e/evidence.json`.

| Id | Scenario |
|---|---|
| S01 | all-in-band run commits SUCCESS: 7 ALLOW asset rows, COMMITTED, no request, no Slack message |
| S02 | review run: one request, one Slack message (token, channel, approvers without the invoker, link); B approves through `fao_hitl_decide`; HITL_RESOLVED and COMMITTED SUCCESS |
| S03 | C rejects; COMMITTED ROLLED_BACK |
| S04 | the invoker's own APPROVED and REJECTED are refused SOD_SELF_APPROVAL, journaled, no ledger row |
| S05 | forged (401), expired (410, run EXPIRED), reused (409) and missing or malformed (400, no database call) tokens; no ledger rows; the token is never journaled |
| S06 | no header, a wrong key, or another header name: 403, no execution, the token stays unused and later runs |
| S07 | fake Slack answers 500: NOTIFICATION_FAILED; one sweep re-sends and records SENT, attempt 2 |
| S08 | the owner-only test clock moves past the deadline for one sweep: EXPIRED, one TIMEOUT escalation to Marcus, COMMITTED FAILURE, one escalation notice; a second sweep adds nothing |
| S09 | Init Execution throws after the claim: the error workflow runs `fao_run_fail`, FAILED event (source `error_workflow`), run FAILED |
| S10 | markup and SQL-shaped reason, fixture notes and decision note stored verbatim; the agent name escaped in the Slack text; only the one approval link uses angle brackets |
| S11 | BLOCKED (one-sided) plus two CRITICAL assets route to review, sub-tier CRITICAL |
| S12 | a NaN wallet balance and a missing ledger balance are BLOCKED; the run waits for review and never commits on its own |

## Shared-stack effects

The layer resets nothing it does not own. It never runs `db:reset` or local-setup, never deletes or updates rows other than its own (S05 expires only its own run token), and removes only its own containers (`finagent-e2e-n8n`, `finagent-e2e-slack`) and volume (`finagent-e2e-n8n-data`); the fake Slack reset clears only the fake's own record.

What it does leave or touch on the shared stack:

- It commits its own runs, requests, ledger rows, notifications and journal rows, and one local-only agent row, `fao_e2e_markup_v1` (display name with markup, for S10), kept until the next `db:reset`.
- S07's sweep re-sends any failed notification on the stack, not only its own.
- **S08 test clock sweep.** S08 sets the owner-only test clock (`fao_private.test_clock`, offset past its request's deadline) for one sweep. It refuses to start if a clock row is already set, so it never overwrites someone else's clock, and its `finally` deletes only its own row (matched by reason), as soon as the sweep has committed the expiry. While the row is set, every sweep on the stack sees the moved clock, and S08's own sweep expires every overdue request and fails every stale run on the stack, as a real sweep would. Do not run other sweeping tests at the same time.

## Findings from the first runs

1. **Execution ids are unique per n8n instance, not forever.** `run_invocations.n8n_execution_id` was UNIQUE and `fao_run_claim` refused a duplicate with ALREADY_CLAIMED. A fresh n8n instance numbers executions from 1 again, so its first runs were refused 409 (journal rows ALREADY_CLAIMED with `n8n_execution_id` 24, 30 and 39 on 2026-11-07 17:40 UTC). Fixed in fix round 2 (R09, migrations 0010 and 0014): an id is unique only among RUNNING runs, and `fao_run_fail` resolves an id to the unfinished run that claimed it most recently. The harness workaround (`n8n-exec-seq.cjs`, which started each instance above the highest claimed id) is removed.
2. **Slack HTTP errors lose their status.** In n8n 2.46 the HTTP Request node's error-output item carries `error: {message, name: "NodeApiError", description, cause}` and no `httpCode`, so Classify Slack Result stores `http error: The service was not able to process your request`; the status (500) and Slack's error code are dropped. The outcome is still FAILED and re-sent. Fixed in fix round 2: Classify Slack Result reads the status from `httpCode`, `status` or `statusCode`, then from `cause`, then from a `500 - ` message prefix, and adds Slack's error code, so S07 now stores `http error 500: ... (e2e_forced_failure)` and asserts it exactly.
3. **NaN does not reach Per-Asset Reconcile as NaN.** Items cross the task runner as JSON, so a NaN set in Init Execution arrives as null and the asset is BLOCKED with `wallet value is null`, not `nan`. Fail-closed holds; only the label differs. Fixed in fix round 2: Init Execution sends NaN and +/-Infinity as the strings `NaN`, `Infinity` and `-Infinity`, so S12 now asserts `wallet value is nan` (still BLOCKED).
