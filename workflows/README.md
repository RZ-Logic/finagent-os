# `workflows/`: n8n workflow index

This directory holds the exported n8n workflow JSON files. They are machine-generated artifacts (node positions, internal ids, wiring), so this index points at the parts worth reading: the `jsCode` blocks inside `code` nodes and the SQL calls inside `postgres` nodes. Every Code node starts with a comment block naming its control IDs. The JSON is the only copy of that code; the Node unit tests extract it from these files at test time, so what is tested is what is imported.

For the SOX control mapping, see [`../SOX-MAPPING.md`](../SOX-MAPPING.md).

---

## Design in one paragraph

n8n never supplies identity and never decides. A run starts when a signed-in human calls the database function `fao_run_start` with their own Supabase session; the database records the invoker and returns a single-use run token. The caller posts only that token to the flagship's invoke webhook. The flagship claims the run (`fao_run_claim`), reconciles, appends its events through the Writer (`fao_ledger_append_batch`), and asks the database to finalize (`fao_run_finalize`), which rolls the run up in SQL and either commits it or opens an approval request in one transaction. Approvers decide on the approval page (`approval-app/`) through `fao_hitl_decide` with their own session; n8n is not in the decision path. n8n only notifies, sweeps on a schedule and records failures.

## Workflows

| File | Workflow name (id) | Role | Trigger |
|---|---|---|---|
| [`fao_reserve_recon_v1.json`](./fao_reserve_recon_v1.json) | `fao_reserve_recon_v1` (`uhB2KjEaJDuviM4D`) | **Flagship.** Reserve Reconciliation Agent, RED tier | Webhook `POST /webhook/fao-recon-invoke`, header auth |
| [`writer.json`](./writer.json) | `Writer` (`dQslIEVwF3WqMliT`) | Validates a batch of events and appends it through `fao_ledger_append_batch`, all or none | Execute Workflow Trigger |
| [`fao_hitl_gateway_v1.json`](./fao_hitl_gateway_v1.json) | `fao_hitl_gateway_v1` (`mUAC9qIMkVzlV5qw`) | **Notifier.** Posts one Slack message for a request and records the attempt | Execute Workflow Trigger |
| [`fao_hitl_sweeper_v1.json`](./fao_hitl_sweeper_v1.json) | `fao_hitl_sweeper_v1` (`FaoSweeperV1x001`) | Runs `fao_maintenance_sweep` and sends the notifications it lists | Schedule, every 5 minutes |
| [`fao_error_handler_v1.json`](./fao_error_handler_v1.json) | `fao_error_handler_v1` (`FaoErrHandlerV01`) | Records a failed flagship execution through `fao_run_fail` | Error Trigger (set as `errorWorkflow` on the flagship only) |
| [`test_writer_harness_multi_item.json`](./test_writer_harness_multi_item.json) | `Test Writer Harness (Multi-Item)` (`OV7ukqcVKYfNXKHa`) | Writer positive and negative batch | Manual, test instances only |
| [`test_hitl_gateway_harness.json`](./test_hitl_gateway_harness.json) | `Test HITL Gateway Harness` (`V87nEh6HALqINIDz`) | Starts a real run through the invoke webhook | Manual, test instances only |

**Retired:** `fao_hitl_approval_handler_v2` is deleted from this directory. Its jobs moved: the decision and its ledger events to the database function `fao_hitl_decide`, the page to `approval-app/`, follow-up notifications to the sweeper. The live copy is archived at cutover and kept in the backup export.

---

## Run flow

### 1. Run start (outside n8n)

The MCP invoke tool signs the human in with their own credentials and calls `fao_run_start` (agent, reason, idempotency key). The database checks the owner row, the invoker role, registry status, tier and the hourly rate limit, records `invoker_id = auth.uid()`, and returns `correlation_id` and a 43-character run token valid for 10 minutes (stored hashed). The caller then posts:

```
POST /webhook/fao-recon-invoke
X-FAO-Invoke-Key: <shared key>
{"run_token": "<43 characters>"}
```

**Runs start only through this webhook.** The flagship has no Manual Trigger: an editor click has no authenticated invoker, and n8n does not run error workflows for manual executions. Test runs use the same webhook as a seeded test user.

### 2. Flagship: `fao_reserve_recon_v1`

```
Webhook: Invoke                       [header auth: FAO Invoke Header Auth]
  -> Validate Invoke Body             [code: reads body.run_token only]
  -> Body Valid?  -- no -->  Respond 400 {accepted:false, code:INVALID_INPUT}
  -> Claim Run                        [postgres: fao_run_claim($1, $2, $3), agent fao_reserve_recon_v1]
  -> Claim OK?    -- no -->  Respond Claim Refused (401, 403, 409 or 410, {accepted:false, code})
  -> Respond 202 {accepted:true, correlation_id}   (the run continues)
  -> Init Execution                   [code: ids and tier from the claim; STARTED event]
  -> Writer: STARTED                  [execute workflow: Writer, once]
  -> Get Materiality Thresholds       [postgres: scope = $1]
  -> Check Thresholds                 [code: no rows is a hard error]
  -> Per-Asset Reconcile              [code: THE POLICY ENGINE]
  -> Writer: ASSET_RECONCILED         [execute workflow: Writer, once, all assets in one batch]
  -> Check Writer Count               [code: stored count must equal asset count]
  -> Finalize Run                     [postgres: fao_run_finalize($1::uuid)]
  -> Human Review Required?  -- no -->  Run Complete (COMMITTED or COMMIT_BLOCKED already written)
  -> Notify Input                     [code: exactly {hitl_id, kind:'REQUESTED', level:0}]
  -> HITL Gateway                     [execute workflow: notifier, once]
```

Where to look first:

- **Per-Asset Reconcile.** Fail-closed input rules, then the deterministic 7-rule matrix (first match wins). An asset present on one side only is BLOCKED with `band_status: ONE_SIDED`; a balance that is undefined, null, empty, non-numeric, NaN or infinite is BLOCKED with `band_status: INVALID_INPUT` and an `input_problem` naming the side and the value class; an asset with no usable threshold is BLOCKED with `NO_THRESHOLD`. Every BLOCKED item carries `hitl_status: PENDING` and `ratio: null`, so it routes the run to human review. Each rule's rationale names its FAO-REC control. No LLM in the policy path.
- **Init Execution.** `correlation_id`, `execution_id`, `agent_id` and `risk_tier` come from the claim result. The asset scope is the sorted union of wallet and ledger keys. Inline fixtures (3 Kraken Dec 2025 PoR anchors, 1 clean baseline, 3 synthetic anomalies) with per-asset provenance on the STARTED row. Items cross the n8n task runner as JSON, which turns NaN and infinities into null, so Init Execution passes them to Per-Asset Reconcile as the strings `NaN`, `Infinity` and `-Infinity`; the asset is still BLOCKED and its `input_problem` says `nan` or `infinite`.
- **Finalize Run.** The rollup (worst-asset rule, counts, escalated assets, review sub-tier) and the request are computed in SQL from the stored events, not by n8n. A run is never AWAITING_HITL without its request and its HITL_REQUESTED event.

**Controls:** FAO-REC-001, 002, 004 (per-asset floor), 006, 007; FAO-GOV-001 (through the Writer), FAO-GOV-004, FAO-GOV-007, FAO-GOV-008, FAO-GOV-013.

### 3. Writer

```
Trigger input schema         [one Writer event per item]
  -> Validate Batch          [code: all items, strip _ keys, collect every problem]
  -> Append Ledger Batch     [postgres: fao_ledger_append_batch($1::jsonb)]
  -> Check Inserted          [code: stored count must equal events sent]
```

Input: one n8n item per event, `{correlation_id, event_type, inputs, policy_outcome, policy_sub_tier?, policy_rationale, obligations?, status, error_details?, ai_prompt?, ai_output?, ai_confidence?, fractional_cost_usd?, hitl_status?, execution_id?, agent_id?, risk_tier?}`. The Writer may append only STARTED, ASSET_RECONCILED and FAILED; HITL, notification, COMMITTED, COMMIT_BLOCKED, RUN_REFUSED and CORRECTION events are written only by database functions. `event_timestamp`, `hitl_approver_id`, `ledger_id` and `corrects_ledger_id` must be absent; the database sets them. `hitl_status` is NOT_REQUIRED, or PENDING only on an ASSET_RECONCILED whose outcome is REQUIRE_HUMAN, DENY or BLOCKED.

Validate Batch throws one named error listing every bad item, `FAO-GOV-001 writer: item <i>: <reason>; ...` with 0-based item numbers (the same numbering the database uses), so nothing is silently dropped. The database then checks run state, asset scope and duplicates and stores the whole batch or nothing. Output: one item `{count, inserted[]}`.

### 4. Notifier: `fao_hitl_gateway_v1`

```
Trigger input schema           [exactly {hitl_id, kind, level}]
  -> Validate Payload          [code: REQUESTED/0 or ESCALATED/1]
  -> Get Notification Context  [postgres: fao_notification_context($1::bigint, $2, $3::int)]
  -> Should Send?  -- no -->  Nothing To Send (not pending, or already sent)
  -> Compose Slack Message     [code: one link, every dynamic value escaped]
  -> Compose OK?   -- no -->  Classify Slack Result (a setting is unusable)
  -> Slack: Post Message       [HTTP chat.postMessage, FAO Slack Bot, 10 s timeout, error output]
  -> Classify Slack Result     [code: SENT only for HTTP 200 with ok:true]
  -> Record Notification       [postgres: fao_notification_record(...)]
```

Everything posted comes from the database: the approval link (`<approval_app_base_url>/?hitl_id=<id>`), the eligible approvers (holders of the approver role, never the invoker) or the escalation target, and the Slack API base URL and channel from `fao_settings`. The same export posts to Slack live and to a local mock in tests. Every attempt is recorded with a NOTIFICATION_SENT or NOTIFICATION_FAILED ledger event; a duplicate SENT is refused by the database.

- **Unusable settings are recorded attempts.** When the approval link, the Slack API base URL or the channel id is unusable, Compose Slack Message emits `compose_ok: false` and the error instead of throwing; Compose OK? sends it to Classify Slack Result, and Record Notification stores a FAILED attempt (`compose error: FAO-GOV-007 notifier: slack_channel_id invalid`, for example). So the sweep's `notify_max_attempts` count and the NOTIFICATION_FAILED escalation see a bad setting exactly like a Slack failure.
- **Error text keeps the status.** For an HTTP error, Classify Slack Result stores `http error <status>: <message> (<Slack error code>)`; n8n 2.x carries the status only in `error.cause.message` (`500 - <body>`) and the Slack error code in `error.description`.
- **Escalation wording.** An escalation sent after the deadline (a TIMEOUT escalation: the sweep has already expired the request and closed the run with status FAILURE) says the request expired without a decision, shows "Deadline passed" and asks for no decision; the link opens the request read-only, and `fao_hitl_decide` refuses a decision with EXPIRED. The deadline is compared with the n8n host's clock, which equals the database clock outside local tests (the local test clock moves only the database). When no escalation target is eligible (IC-13), the notice says "none eligible (operator alerted)"; the sweep raises FAO-GOV-008 for the operator.

### 5. Sweeper: `fao_hitl_sweeper_v1`

```
Schedule Trigger (every 5 minutes)
  -> Run Sweep                 [postgres: fao_maintenance_sweep()]
       -> Expand Notifications [code: one notifier input per escalation and re-notify entry]
            -> HITL Gateway    [execute workflow: notifier, each item, continue on error]
                 -> Check Notifier Results [code: fails the execution when any notifier call failed]
       -> Check Sweep Errors   [code: fails the execution when item_errors is not empty]
```

The sweep (in SQL) expires unclaimed tokens, fails stale runs, expires overdue requests and writes their final COMMITTED (status FAILURE), escalates once, and lists failed notifications for retry up to `notify_max_attempts`. Deadlines do not depend on the schedule: `fao_hitl_decide` refuses a decision at or after the deadline on its own.

HITL Gateway keeps going when one notifier call fails, so every listed notice is attempted. Check Notifier Results then fails the sweeper execution with `FAO-GOV-007 sweep: <n> notifier failures: <hitl_id:kind:level (message)>, ...` when any call failed (a database error in the notifier, or an unpublished notifier), so the failure shows as a failed sweeper execution, not a green one. Failures the notifier records itself (Slack errors and unusable settings) are not errors here; the sweep retries and escalates them.

### 6. Error handler: `fao_error_handler_v1`

```
Error Trigger
  -> Extract Failure           [code: execution id, last node, message cleaned and cut to 500]
  -> Record Run Failure        [postgres: fao_run_fail($1, $2, $3)]
```

Set as `errorWorkflow` on the flagship only, and published before the flagship (n8n 2.x skips an unpublished error workflow). A failing Writer or notifier call (a database error, or an unpublished sub-workflow) fails the flagship's Execute Workflow node, so the error workflow receives the flagship's execution id, which `fao_run_claim` recorded on the run. The database writes FAILED and moves the run to FAILED; after a request exists, the request stands and the sweep handles it. An execution that matches no run returns `UNKNOWN_EXECUTION` and nothing is written.

---

## Rules every export follows

- Every Postgres node uses `executeQuery` with a constant SQL string and `$1..$n` placeholders; values go in `options.queryReplacement` as one array expression. No `{{` appears inside any query.
- Every Code node sets `mode` explicitly and starts with a comment block naming its control IDs.
- Every Execute Workflow node sets `mode` (`once` or `each`) and targets an exported workflow id.
- Only the flagship sets `errorWorkflow`.
- Every node keeps the typeVersion pinned in `scripts/check-exports.mjs` (`NODE_TYPE_VERSIONS`, checked against n8n 2.46.6), such as Execute Workflow 1.3 and Execute Workflow Trigger 1.1, which the offline mapping model assumes. A node re-added in a newer editor lands at a newer version and fails rule `node_type_versions` until the pins are moved on purpose after a scratch import and the e2e layer.
- No secrets and no URLs beyond the public ones already in the fixtures.

`npm run check:exports` checks these rules; `npm run test:node` runs the Code-node unit tests.

## Credentials

The exports reference three credentials by name, with fixed placeholder ids. Nothing else may be referenced.

| Name | Type | Placeholder id | Used by |
|---|---|---|---|
| `FAO Postgres (fao_workflow)` | `postgres` | `FaoPgWorkflow001` | every Postgres node; connects as the `fao_workflow` role, which can only execute the workflow functions and read thresholds |
| `FAO Invoke Header Auth` | `httpHeaderAuth` | `FaoInvokeHdr0001` | the flagship webhook; header name `X-FAO-Invoke-Key` |
| `FAO Slack Bot` | `slackApi` | `FaoSlackBot00001` | Slack: Post Message |

## How to import

These steps are for n8n 2.x; the exports and the e2e layer are checked against n8n 2.46.6 (`test/env/versions.json`). In n8n 2.x "Activate" became **Publish**, and every one of the five production workflows must be published, not only the two with a webhook or schedule trigger:

- A production (webhook or schedule) execution runs only the **published** version of a sub-workflow. An unpublished Writer or notifier fails the call with "Workflow is not active and cannot be executed."; a manual editor run would still use the draft, so it does not show the problem.
- An error workflow runs only when it is published. An unpublished `fao_error_handler_v1` is skipped with only a log line, `fao_run_fail` is never called, and a failed run waits for the sweep's stale-run timeout instead.
- `n8n import:workflow` imports every workflow unpublished (`--activeState=fromJson` works only in queue mode), and the editor refuses to publish a workflow while a sub-workflow it calls is unpublished.

1. Create the three credentials above in n8n with exactly these names (the Postgres one connects as `fao_workflow`; the header auth one uses header name `X-FAO-Invoke-Key` and a new random value; the Slack one holds the bot token).
2. Import every production export, keeping ids: `n8n import:workflow --separate --input=<directory with the five production files>` (or *Workflows, Import from File* for each). Import order when importing one at a time: `writer.json`, `fao_hitl_gateway_v1.json`, `fao_error_handler_v1.json`, `fao_hitl_sweeper_v1.json`, `fao_reserve_recon_v1.json`.
3. Open each Postgres, webhook and Slack node and select the credential by name (the placeholder ids do not exist on a new instance).
4. Check the flagship's settings show `fao_error_handler_v1` as its error workflow.
5. Publish all five production workflows, one at a time, in this order (each after everything it calls or names as its error workflow; the sweeper starts sweeping and the flagship starts accepting runs as soon as each is published, so they come last). From the CLI, with the n8n server stopped (there is no `--all` flag):

   ```
   n8n publish:workflow --id=dQslIEVwF3WqMliT    # 1 Writer
   n8n publish:workflow --id=mUAC9qIMkVzlV5qw    # 2 fao_hitl_gateway_v1 (notifier)
   n8n publish:workflow --id=FaoErrHandlerV01    # 3 fao_error_handler_v1
   n8n publish:workflow --id=FaoSweeperV1x001    # 4 fao_hitl_sweeper_v1
   n8n publish:workflow --id=uhB2KjEaJDuviM4D    # 5 fao_reserve_recon_v1 (flagship)
   ```

   Or use **Publish** in the editor in the same order. Each production workflow's sticky note states its step.
6. Check: `n8n list:workflow --active=true --onlyId` lists exactly these five ids (the harness ids never appear). Then drive one run through the invoke webhook and confirm the ledger shows STARTED and then COMMITTED or HITL_REQUESTED for its correlation id; a run that sits in RUNNING with no ledger rows means the Writer is not published.
7. Do not import the harnesses on a shared instance, and never publish them.

`npm run check:exports` rule `publish_order` checks that this order puts every workflow after its sub-workflows and error workflow and that each sticky note names its step; the global check `publish_docs` checks that the list above matches it.

## Test harnesses

Both harnesses start with **Assert Test Environment**, which throws unless the n8n environment variable `FAO_ENV` is `test` (the test container also sets `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` so Code nodes can read it). On any other instance they stop before making a request, so they cannot write to a shared ledger. They read their URLs, public key and test user from `FAO_TEST_*` variables and contain no credentials.

- **Writer harness**: signs in as the test invoker, starts a run (`p_invoked_via: 'test'`), claims it as n8n would, sends STARTED plus 7 ASSET_RECONCILED (must store 8 events, 7 asset rows), sends a batch whose item 2 has no `policy_rationale` (must fail with the named Writer error), then closes the run through `fao_run_fail`.
- **Notifier harness**: signs in, starts a run, posts the token to the invoke webhook with the header key, and asserts HTTP 202.

In wave 1 the harnesses are kept valid but are not run; the workflows are checked offline (export rules and Code-node unit tests) and every database call they make is tested directly.

---

## Conventions

- **Naming:** production workflows use `fao_<area>_<purpose>_v<N>`. The Writer is exported as `writer.json`; its name inside n8n is `Writer`.
- **Notes:** each workflow has a sticky note (`Architecture Note`, `Writer Note` or `Harness Note`) summarizing its role and control IDs. They render only inside n8n.
- **Sub-workflow triggers:** the Writer and the notifier start with an Execute Workflow Trigger whose input schema is a JSON example; fields outside the schema are dropped before the first node runs. Every caller maps each trigger field explicitly by expression (`={{ $json.<field> }}`) with a matching schema, never by pass-through; `scripts/check-exports.mjs` rule `execute_workflow_inputs` enforces it.
