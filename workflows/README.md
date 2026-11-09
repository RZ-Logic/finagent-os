# `workflows/`: n8n workflow index

This directory holds the exported n8n workflow JSON files. They are machine-generated artifacts (node positions, internal ids, wiring), so this index points at the parts worth reading: the `jsCode` blocks inside `code` nodes and the SQL calls inside `postgres` nodes. Every Code node starts with a comment block naming its control IDs. The JSON is the only copy of that code; the Node unit tests extract it from these files at test time, so what is tested is what is imported.

For the SOX control mapping, see [`../SOX-MAPPING.md`](../SOX-MAPPING.md).

**Status:** live. The five production exports (commit `c9c2fc0` of the branch `phase2-5-core-2026-11-07`) were imported with their ids into the self-hosted n8n 2.46.6 on 2026-11-08 and published on 2026-11-09 (UTC) in the order under [How to import](#how-to-import), with only the credential references pointed at the three live credentials. A re-export of the five live workflows equals these files (no logic difference). They are also checked offline and run end to end against a local n8n 2.46.6 and a local Supabase stack (`test/e2e`). The v1 workflows are retired: `fao_hitl_approval_handler_v2` is archived and its webhooks return 404; the invoke webhook refuses a call without the key with 403.

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
| [`fao_error_handler_v1.json`](./fao_error_handler_v1.json) | `fao_error_handler_v1` (`FaoErrHandlerV01`) | Records every failed flagship, notifier or sweeper execution through `fao_run_fail` | Error Trigger (set as `errorWorkflow` on the flagship, the notifier and the sweeper) |
| [`test_writer_harness_multi_item.json`](./test_writer_harness_multi_item.json) | `Test Writer Harness (Multi-Item)` (`OV7ukqcVKYfNXKHa`) | Writer positive and negative batch | Manual, test instances only |
| [`test_hitl_gateway_harness.json`](./test_hitl_gateway_harness.json) | `Test HITL Gateway Harness` (`V87nEh6HALqINIDz`) | Starts a real run through the invoke webhook | Manual, test instances only |

**Retired:** `fao_hitl_approval_handler_v2` is deleted from this directory. Its jobs moved: the decision and its ledger events to the database function `fao_hitl_decide`, the page to `approval-app/`, follow-up notifications to the sweeper. The live copy was archived in n8n at the cutover (2026-11-09); its webhooks return 404.

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
  -> Check Finalize Result            [code: ok:false fails the execution (FAO-GOV-008)]
  -> Human Review Required?  -- no -->  Run Complete (COMMITTED or COMMIT_BLOCKED already written)
  -> Notify Input                     [code: exactly {hitl_id, kind:'REQUESTED', level:0}]
  -> HITL Gateway                     [execute workflow: notifier, once]
```

Where to look first:

- **Per-Asset Reconcile.** Fail-closed input rules, then the deterministic 7-rule matrix (first match wins). An asset present on one side only is BLOCKED with `band_status: ONE_SIDED`; a balance that is undefined, null, empty, non-numeric, NaN or infinite is BLOCKED with `band_status: INVALID_INPUT` and an `input_problem` naming the side and the value class; an asset with no usable threshold is BLOCKED with `NO_THRESHOLD`. Every BLOCKED item carries `hitl_status: PENDING` and `ratio: null`, so it routes the run to human review. Each rule's rationale names its FAO-REC control. Rule 5 (stablecoin USD materiality, IN_BAND_USD_MATERIAL) fires on a shortfall only, ledger minus wallet above `materiality_usd` (owner decision 2026-11-08, IC-46); a stablecoin surplus inside the band ALLOWs, and its rationale notes when the surplus is above materiality. No LLM in the policy path.
- **Init Execution.** `correlation_id`, `execution_id`, `agent_id` and `risk_tier` come from the claim result. The asset scope is the sorted union of wallet and ledger keys. Inline fixtures (3 Kraken Dec 2025 PoR anchors, 1 clean baseline, 3 synthetic scenarios) with per-asset provenance on the STARTED row. The STARTED event carries none of `invoker_id`, `invoked_via`, `reason` or `n8n_execution_id`: the database sets them from the run record and refuses a STARTED that carries any of them (IC-48, which supersedes the IC-11 overwrite; owner decision 2026-11-08); `check-exports` rule `started_db_keys` holds this. Items cross the n8n task runner as JSON, which turns NaN and infinities into null, so Init Execution passes them to Per-Asset Reconcile as the strings `NaN`, `Infinity` and `-Infinity`; the asset is still BLOCKED and its `input_problem` says `nan` or `infinite`.
- **Finalize Run.** The rollup (worst-asset rule, counts, escalated assets, review sub-tier) and the request are computed in SQL from the stored events, not by n8n. A run is never AWAITING_HITL without its request and its HITL_REQUESTED event.
- **Check Finalize Result.** `fao_run_finalize` can refuse with `ok:false` after its own writes commit: when the agent is no longer ACTIVE at commit (`inputs.code` AGENT_NOT_ACTIVE, IC-24), or the run's invoker is no longer an active owner holding the invoker grant for the agent (`inputs.code` INVOKER_NOT_ACTIVE, IC-30; the agent check comes first), it writes COMMIT_BLOCKED and moves the run to FAILED in the same transaction. Any result other than one item with `r.ok === true` fails the execution here with one fixed message, `FAO-GOV-008 recon: fao_run_finalize refused with <code> for run <correlation_id>; the run was not committed` (a code or id outside its format reads `UNKNOWN` / `unknown`), so the error workflow and n8n failure alerting run. The error workflow's `fao_run_fail` then finds the run already FAILED and answers ALREADY_TERMINAL, writing nothing, so the ledger keeps exactly one COMMIT_BLOCKED and no FAILED row. `check-exports` (`checkFinalizeGate`) refuses a layout in which a finalize result can reach Human Review Required? any other way, an error output or continue-on-fail on either node, or a check that does not throw on `r.ok !== true`. An `ok:true` result fails it too unless its `state` is COMMITTED or AWAITING_HITL (`PASS_STATES`): AUDIT_CHAIN_MISMATCH answers `ok:true` with `state` FAILED after writing COMMIT_BLOCKED, and now fails the execution with the same message (red team round 4 item 2; `checkFinalizeGate` requires the state check).

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
- **Dual approval (FAO-GOV-004).** `fao_notification_context` also returns `enforced_approvals` (the request's frozen count), `approvals_received` (the approvals that count now) and `approved_by` (their names in approval order, never the invoker). When `enforced_approvals` is more than 1, a REQUESTED notice adds, right after `*Eligible approvers:*`, the line `*Approvals needed:* <e> from different approvers`; then, when some have been received, `*Approvals received:* <n> of <e> (<names>)`; then, when fewer approvers are listed than are needed, `*Warning:* fewer eligible approvers than approvals needed; this request can only be rejected or expire`. An ESCALATED notice adds `*Approvals received:* <n> of <e>` right after `*Escalation target:*`, with ` (<names>)` when n is more than 0, also after the deadline. The closing line of a notice that has not expired becomes `_Sign in on the approval page to approve or reject. The person who started the run cannot decide it. Each approver counts once; one rejection closes the request._`; the expired closing line is unchanged. A missing, null or non-integer `enforced_approvals` reads as 1, and with one enforced approval (every STANDARD request) the text is exactly as before. Names pass `slackEscape`, the counts are integers, and the notice still carries exactly one URL. The eligible-approver list and the warning do not apply the qualifying-grant rule (DA-4), so they can name someone who cannot decide this request; the notice is an alert, and the database decides. The flagship's Architecture Note states the RED rule: two approvals from different approvers for CRITICAL review, one for STANDARD; a CRITICAL request is decided by its second approval or by any one rejection.
- **Escalation wording.** An escalation sent after the deadline (a TIMEOUT escalation: the sweep has already expired the request and closed the run EXPIRED, with HITL_EXPIRED as the expiry record and no COMMITTED row; the escalation's HITL_ESCALATED, and COMMIT_BLOCKED when the audit chain is incomplete, can follow it) says the request expired without a decision, shows "Deadline passed" and asks for no decision; the link opens the request read-only, and `fao_hitl_decide` refuses a decision with EXPIRED. The deadline is compared with the n8n host's clock, which equals the database clock outside local tests (the local test clock moves only the database). The database never names the invoker or an inactive owner as a notice or escalation target; a target deactivated after the escalation is replaced by the next eligible owner (IC-13, IC-35). When no target is eligible, the notice says "none eligible (operator alerted)"; the sweep raises FAO-GOV-008 for the operator.

### 5. Sweeper: `fao_hitl_sweeper_v1`

```
Schedule Trigger (every 5 minutes)
  -> Run Sweep                 [postgres: fao_maintenance_sweep()]
       -> Expand Notifications [code: one notifier input per escalation and re-notify entry]
            -> HITL Gateway    [execute workflow: notifier, each item, continue on error]
                 -> Check Notifier Results [code: lists each failed notifier call; never stops the execution]
       -> Check Sweep Errors   [code: runs last; fails the execution once for notifier failures and item_errors]
```

The sweep (in SQL) expires unclaimed tokens, fails stale runs, expires overdue requests (HITL_EXPIRED, status FAILURE with `committed` false, is the expiry record, not necessarily the run's last row: HITL_ESCALATED follows it when the sweep escalates, and COMMIT_BLOCKED only when the audit chain is incomplete; no COMMITTED row is written), escalates once, and lists failed notifications for retry up to `notify_max_attempts`. A pending request with no SENT approval notice 5 minutes x (`notify_max_attempts` + 1) after it was created (20 minutes at the default of 3), however many attempts were recorded, is escalated once as NOTIFICATION_FAILED and its approval notice is not re-sent after that (R12; the owner accepted this rule as built on 2026-11-08). Deadlines do not depend on the schedule: `fao_hitl_decide` refuses a decision at or after the deadline on its own.

HITL Gateway keeps going when one notifier call fails, so every listed notice is attempted. Check Notifier Results lists each failed call (a database error in the notifier, or an unpublished notifier) as `hitl_id:kind:level (message)` and does not throw. Check Sweep Errors is the only node that fails the sweeper execution. With execution order v1, Run Sweep's two branches run one after the other, topmost on the canvas first; Check Sweep Errors sits below Expand Notifications, so it runs last, on every sweep, after every notice was attempted. It throws once, naming both kinds of failure, each part only when it applies:

```
FAO-GOV-007 sweep: <n> notifier failures: <hitl_id:kind:level (message)>, ...; FAO-GOV-008 sweep: <n> item errors: <step:id:sqlstate>, ...
```

It fails closed: when the sweep listed notices but no notifier results can be read, or fewer calls than were listed, that counts as a notifier failure (`missing (...)`). `scripts/check-exports.mjs` holds the order (execution order v1, the positions, the two Run Sweep branches, no other sweeper Code node throws). Failures the notifier records itself (Slack errors and unusable settings) are not errors here; the sweep retries and escalates them.

### 6. Error handler: `fao_error_handler_v1`

```
Error Trigger
  -> Extract Failure           [code: execution id, last node (200), message (500), source from a fixed map]
  -> Record Run Failure        [postgres: fao_run_fail($1, $2, $3, $4)]
```

Set as `errorWorkflow` on the flagship, the notifier (gateway) and the sweeper (F-20), and published before all three (n8n 2.x skips an unpublished error workflow). Every call of `fao_run_fail` writes exactly one durable record in one transaction: the FAILED ledger row on the run it attaches to, or one row in the append-only `workflow_failures` table (K1).

**Extract Failure** chooses the `source` (`$4`) from fixed facts, never from the error text:

| Failed workflow (payload `workflow.id`) | Last node | `source` | What `fao_run_fail` records |
|---|---|---|---|
| flagship `uhB2KjEaJDuviM4D` | Webhook: Invoke, Validate Invoke Body, Body Valid?, Respond 400, Claim Run, Claim OK? or Respond Claim Refused (every node that is not Respond 202 and not downstream of it) | `flagship_pre_claim` | one `workflow_failures` row, outcome PRE_CLAIM; no run is looked up, so an older run that holds the same execution id is never touched |
| flagship `uhB2KjEaJDuviM4D` | Respond 202 or any node downstream of it | `flagship` | the newest run (by claim time) holding the execution id: FAILED row and run FAILED (RUNNING) or the request left for the sweep (AWAITING_HITL), outcome ATTACHED; if that newest run is already terminal, one `workflow_failures` row ALREADY_TERMINAL with its correlation id (never an older run); no run at all, one UNKNOWN_EXECUTION row |
| notifier `mUAC9qIMkVzlV5qw` | any | `gateway` | one `workflow_failures` row, outcome NOT_FLAGSHIP |
| sweeper `FaoSweeperV1x001` | any | `sweeper` | one `workflow_failures` row, outcome NOT_FLAGSHIP |
| anything else | any | none | Extract Failure throws `FAO-GOV-008 error handler: workflow <id> is not in the error handler source map; nothing was recorded`; the error handler's own execution fails and n8n keeps it |

A failing Writer or notifier call (a database error, or an unpublished sub-workflow) fails the flagship's Execute Workflow node, so the flagship's execution id reaches the handler with source `flagship`; a failing notifier execution is also recorded on its own as `gateway`. A failure raised by Check Finalize Result reaches a run that the database already moved to FAILED, so `fao_run_fail` answers ALREADY_TERMINAL and adds one `workflow_failures` row, never a ledger row. The node name and message are stored with control characters turned into spaces and cut to 200 and 500 characters. The output of Record Run Failure is the `fao_run_fail` envelope, which carries `outcome`.

The map in Extract Failure is written one entry per line (`'<id>': '<source>',`) so that `test/e2e/variants.mjs` can add the e2e copies of the flagship and the sweeper next to their entries. `check-exports` rule `error_handler_map` holds the map equal to the exports that name this handler, each entry exactly once, the pre-claim list equal to the flagship nodes that are not Respond 202 and not downstream of it (computed from the flagship's nodes and connections; round 6, P1), and Record Run Failure as the last node with the 4-argument call; rule `error_workflow` holds `errorWorkflow` set on exactly the flagship, the notifier and the sweeper.

Not covered: the Writer sets no `errorWorkflow` (a failed Writer call fails the flagship, which is recorded). A claim that committed inside Claim Run and then errored there, or at Claim OK?, is sent as `flagship_pre_claim` and records only a `workflow_failures` row; that run stays RUNNING until the sweep's stale-run rule fails it (`sla_max_execution_seconds`). An execution that passed Respond 202 holds its own claim, and `fao_run_fail` attaches only to the newest holder of its execution id; with the execution limits below, an older holder is never newer than a live execution's own claim.

**Execution limits (round 6, P4).** The flagship sets `settings.executionTimeout` 600 seconds, the notifier 120 and the sweeper 300, so n8n ends a slow flagship execution before `sla_max_execution_seconds` (900 at the least; the database refuses a lower value) lets the sweep or a later claim call its run stale. A killed execution therefore cannot write to a run that was already failed and whose execution id was reused by another instance. n8n caps every workflow limit at `EXECUTIONS_TIMEOUT_MAX` (default 3600): set it to at least 600 on every instance that runs these workflows, or the flagship's limit is cut below what it states. Rule `execution_timeout` in `check-exports` holds the three values and the flagship's limit below 900.

---

## Rules every export follows

- Every Postgres node uses `executeQuery` with a constant SQL string and `$1..$n` placeholders; values go in `options.queryReplacement` as one array expression. No `{{` appears inside any query.
- Every Code node sets `mode` explicitly and starts with a comment block naming its control IDs.
- Every Execute Workflow node sets `mode` (`once` or `each`) and targets an exported workflow id.
- Exactly the flagship, the notifier and the sweeper set `errorWorkflow`, to `fao_error_handler_v1` (`FaoErrHandlerV01`).
- The flagship, the notifier and the sweeper set `executionTimeout` to 600, 120 and 300 seconds; the flagship's stays below the 900-second floor of `sla_max_execution_seconds`.
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

The Postgres credential connects through the Supabase session pooler with SSL Require and certificate verification on (Ignore SSL Issues off). Supabase pooler certificates chain to the Supabase Root 2021 CA, which Node does not trust by default, so the n8n host must trust that CA: download the root certificate from the Supabase dashboard, mount it read-only into the n8n container and set `NODE_EXTRA_CA_CERTS` to its path. Without it the connection test fails with "self-signed certificate in certificate chain". Live does this (cutover step 10, 2026-11-08).

## How to import

These steps are for n8n 2.x; the exports and the e2e layer are checked against n8n 2.46.6 (`test/env/versions.json`). In n8n 2.x "Activate" became **Publish**, and every one of the five production workflows must be published, not only the two with a webhook or schedule trigger:

- A production (webhook or schedule) execution runs only the **published** version of a sub-workflow. An unpublished Writer or notifier fails the call with "Workflow is not active and cannot be executed."; a manual editor run would still use the draft, so it does not show the problem.
- An error workflow runs only when it is published. An unpublished `fao_error_handler_v1` is skipped with only a log line, `fao_run_fail` is never called, and a failed run waits for the sweep's stale-run timeout instead.
- `n8n import:workflow` imports every workflow unpublished (`--activeState=fromJson` works only in queue mode), and the editor refuses to publish a workflow while a sub-workflow it calls is unpublished.

1. Create the three credentials above in n8n with exactly these names (the Postgres one connects as `fao_workflow`, with SSL verified against the Supabase Root 2021 CA as described under Credentials; the header auth one uses header name `X-FAO-Invoke-Key` and a new random value; the Slack one holds the bot token).
2. Import every production export, keeping ids: `n8n import:workflow --separate --input=<directory with the five production files>` (or *Workflows, Import from File* for each). Import order when importing one at a time: `writer.json`, `fao_error_handler_v1.json`, `fao_hitl_gateway_v1.json`, `fao_hitl_sweeper_v1.json`, `fao_reserve_recon_v1.json`.
3. Open each Postgres, webhook and Slack node and select the credential by name (the placeholder ids do not exist on a new instance).
4. Check the settings of the flagship, `fao_hitl_gateway_v1` and `fao_hitl_sweeper_v1` each show `fao_error_handler_v1` as the error workflow and a timeout of 600, 120 and 300 seconds (10 min, 2 min, 5 min). Check the instance's `EXECUTIONS_TIMEOUT_MAX` is at least 600 (n8n's default is 3600).
5. Publish all five production workflows, one at a time, in this order (each after everything it calls or names as its error workflow; the sweeper starts sweeping and the flagship starts accepting runs as soon as each is published, so they come last). From the CLI, with the n8n server stopped (there is no `--all` flag):

   ```
   n8n publish:workflow --id=dQslIEVwF3WqMliT    # 1 Writer
   n8n publish:workflow --id=FaoErrHandlerV01    # 2 fao_error_handler_v1
   n8n publish:workflow --id=mUAC9qIMkVzlV5qw    # 3 fao_hitl_gateway_v1 (notifier)
   n8n publish:workflow --id=FaoSweeperV1x001    # 4 fao_hitl_sweeper_v1
   n8n publish:workflow --id=uhB2KjEaJDuviM4D    # 5 fao_reserve_recon_v1 (flagship)
   ```

   Or use **Publish** in the editor in the same order. Each production workflow's sticky note states its step.
6. Check: `n8n list:workflow --active=true --onlyId` lists exactly these five ids (the harness ids never appear). Then drive one run through the invoke webhook and confirm the ledger shows STARTED and then COMMITTED or HITL_REQUESTED for its correlation id; a run that sits in RUNNING with no ledger rows means the Writer is not published.
7. Do not import the harnesses on a shared instance, and never publish them.

`npm run check:exports` rule `publish_order` checks that this order puts every workflow after its sub-workflows and error workflow and that each sticky note names its step; the global check `publish_docs` checks that the list above matches it.

## Test harnesses

Both harnesses start with **Assert Test Environment**, which throws unless the n8n environment variable `FAO_ENV` is `test` (the test container also sets `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` so Code nodes can read it) and every URL the harness calls is http or https, with no user info, to a local host (`localhost`, `127.0.0.1`, `[::1]`, a name ending in `.localhost` or `.test`, or a single-label Docker service name). On any other instance, or against a hosted project, they stop before making a request, so they cannot write to a shared ledger. The Writer harness's Postgres credential host is not checked by that node. They read their URLs, public key and test user from `FAO_TEST_*` variables and contain no credentials.

- **Writer harness**: signs in as the test invoker, starts a run (`p_invoked_via: 'test'`), claims it as n8n would, sends STARTED plus 7 ASSET_RECONCILED (must store 8 events, 7 asset rows), sends a batch whose item 2 has no `policy_rationale` (must fail with the named Writer error), then closes the run through `fao_run_fail`.
- **Notifier harness**: signs in, starts a run, posts the token to the invoke webhook with the header key, and asserts HTTP 202.

Each harness run uses a fresh idempotency key (`harness-<kind>-<execution id>-<milliseconds>`), because a fresh n8n reuses execution ids. The Writer harness closes its run with the 4-argument `fao_run_fail` (source `flagship`). The e2e layer imports and executes both harnesses against the local stack (S17, S18) and checks that Assert Test Environment refuses a run outside a test instance and a non-local target (S19); offline, the export rules check them statically.

---

## Conventions

- **Naming:** production workflows use `fao_<area>_<purpose>_v<N>`. The Writer is exported as `writer.json`; its name inside n8n is `Writer`.
- **Notes:** each workflow has a sticky note (`Architecture Note`, `Writer Note` or `Harness Note`) summarizing its role and control IDs. They render only inside n8n.
- **Sub-workflow triggers:** the Writer and the notifier start with an Execute Workflow Trigger whose input schema is a JSON example; fields outside the schema are dropped before the first node runs. Every caller maps each trigger field explicitly by expression (`={{ $json.<field> }}`) with a matching schema, never by pass-through; `scripts/check-exports.mjs` rule `execute_workflow_inputs` enforces it.
