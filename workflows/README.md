# `workflows/` — n8n Workflow Index

> **For navigation only.** This directory contains exported n8n workflow JSON files. They are machine-generated artifacts (node positions, internal UUIDs, wire references) and are not intended to be read top-to-bottom. This index points you at the parts that contain real engineering — typically the `jsCode` blocks inside `code` nodes — and away from the n8n plumbing.

If you're scanning code, the policy logic lives in the `code` nodes. The deterministic decision matrices, payload validators, and audit-row composers are all written in commented JavaScript inside those nodes. Open the JSON, search for `"jsCode"`, and the interesting work is there.

For the platform-level architecture and the SOX control mapping, see [`../SOX-MAPPING.md`](../SOX-MAPPING.md). For build-decision context (why these workflows are shaped this way), see the *Build Decisions & Lessons Learned* section in the [root README](../README.md).

---

## Production workflows

| File | Workflow Name | Role | Trigger | Where the interesting code lives |
|---|---|---|---|---|
| [`fao_reserve_recon_v1.json`](./fao_reserve_recon_v1.json) | `fao_reserve_recon_v1` | **Flagship.** Reserve Reconciliation Agent. RED-tier. | Manual Trigger (the committed export has no webhook trigger) | `Per-Asset Reconcile` node: the deterministic policy decision matrix |
| [`fao_hitl_gateway_v1.json`](./fao_hitl_gateway_v1.json) | `fao_hitl_gateway_v1` | HITL gate. Inserts queue rows; sends Slack notification. | `executeWorkflowTrigger` (called by flagship) | `Validate Payload` node — required-field contract |
| [`fao_hitl_approval_handler_v2.json`](./fao_hitl_approval_handler_v2.json) | `fao_hitl_approval_handler_v2` | Slack-link approval endpoint. **GET shows form, POST mutates.** Demo only: unauthenticated and not hardened for production. | Two webhooks: GET `/webhook/fao-hitl-confirm`, POST `/webhook/fao-hitl-resolve` | `Compose Confirmation HTML` (GET) + `Call fao_hitl_resolve` (POST) |
| [`writer.json`](./writer.json) | `Writer` (Shadow Ledger Writer) | Plumbing. Validates and inserts `shadow_ledger` rows. Known issue: the committed export processes only the first item of a batch. | `executeWorkflowTrigger` (called by every other workflow) | `Validate Payload` node: 7 required fields, 17-field normalized payload |

## Test harnesses

| File | Purpose |
|---|---|
| [`test_writer_harness_multi_item.json`](./test_writer_harness_multi_item.json) | Sends a two-item batch to the Writer. Used during writer development. The committed Writer export processes only the first item, so a run currently inserts one row. Its comment says item 1 omits `policy_rationale`, but both items include it, so it is not a negative test. |
| [`test_hitl_gateway_harness.json`](./test_hitl_gateway_harness.json) | Drives the HITL Gateway with a synthetic payload. Used to validate gateway behaviour without invoking the full flagship chain. |

These are not part of the production execution path. They exist to verify sub-workflows work standalone. They are not isolated: they call the same Writer and HITL Gateway workflows as the flagship, so a run writes persistent `shadow_ledger` and `hitl_queue` rows and the Gateway harness posts to Slack. Point them at a test environment.

---

## Per-workflow notes

### `fao_reserve_recon_v1` — the flagship (12 nodes)

```
Manual Trigger
  └─ Init Execution                  [code: correlation_id, fixtures, agent metadata]
       └─ Writer: STARTED            [executeWorkflow → Writer]
            └─ Get Materiality Thresholds   [postgres → materiality_thresholds]
                 └─ Per-Asset Reconcile     [code: THE POLICY ENGINE]
                      └─ Writer: ASSET_RECONCILED   [executeWorkflow → Writer, 7 items sent; committed Writer export persists only the first]
                           └─ Aggregate Rollup     [code: worst-asset-wins]
                                └─ Any HITL Required?   [if branch]
                                     ├─ true (rollup not REQUIRE_HUMAN, including BLOCKED/DENY) → Writer: COMMITTED
                                     └─ false (REQUIRE_HUMAN)
                                          └─ Compose HITL Gateway Payload
                                               └─ HITL Gateway  [executeWorkflow]
```

**Where to look first if you're reviewing the engineering quality:**

- `Per-Asset Reconcile` node, `jsCode` block. ~190 lines. This is the deterministic decision matrix: 7 rules evaluated top-down, first match wins, after a pre-check that marks an asset with no configured threshold BLOCKED. Each rule's rationale string names its FAO-REC control ID. No LLM in the policy path.
- `Init Execution` node, `jsCode` block. The fixture data is embedded inline with provenance metadata per asset (3 Kraken Dec 2025 PoR anchors + 1 clean baseline + 3 synthetic anomalies). The provenance is recorded once per run, on the STARTED row under `inputs.fixture_provenance`; ASSET_RECONCILED rows do not carry it.
- `Aggregate Rollup` node. Implements the worst-asset-wins rollup rule and the rationale string composition.
- `Architecture Note` sticky note. Renders inside n8n with a one-paragraph summary; safe to ignore in the JSON view.

**Controls implemented:** FAO-REC-001, 002, 004 (per-asset floor only), 006, 007 + FAO-GOV-001 (via Writer), FAO-GOV-008, FAO-GOV-013 (via the `agent_registry` foreign key on `shadow_ledger.agent_id`). Not implemented in this workflow: an aggregate reserve ratio or aggregate floor (FAO-REC-003/004) and a dedicated evidence package node (FAO-REC-008).

---

### `fao_hitl_gateway_v1` — the HITL gate (8 nodes)

Sub-workflow. Called by the flagship when the rollup outcome is `REQUIRE_HUMAN`. Validates the gateway payload, inserts a row into `hitl_queue`, sends a Slack notification with the approval link, and records the `HITL_REQUESTED` event in `shadow_ledger`.

```
executeWorkflowTrigger
  └─ Validate Payload                [code: required-field check]
       └─ Insert HITL Row            [postgres → hitl_queue (calls fao_hitl_create function)]
            └─ Validate Insert + Compose      [code: defensive zero-row check]
                 └─ Slack: HITL Notification  [slack node]
                      └─ Compose Writer Payload   [code]
                           └─ Writer: HITL_REQUESTED   [executeWorkflow → Writer]
```

**Why the validation pattern:** the original implementation used inline `INSERT...SELECT` against `process_owners` for invoker resolution. When the email lookup found no match, it silently inserted zero rows and the workflow continued as if nothing was wrong. Migration 0007 introduced the `fao_hitl_create` Postgres function which raises a named exception on lookup failure. The `Validate Insert + Compose` node is the in-workflow defensive layer that complements the database-layer enforcement.

**Controls implemented:** FAO-GOV-004 (HITL gate), FAO-GOV-008 (correlation threading).

---

### `fao_hitl_approval_handler_v2` — the Slack approval endpoint (18 nodes)

The HTTP server that handles approval link clicks. Demo only: unauthenticated and not hardened for production. Identity binding of approver and invoker is a known gap planned for a later release. **Two webhooks, deliberately separated:**

- `GET /webhook/fao-hitl-confirm`: renders an HTML confirmation page. Read-only; no state mutation. This is what Slack's link-unfurling bot hits when previewing the message.
- `POST /webhook/fao-hitl-resolve`: records the decision. Calls the `fao_hitl_resolve` Postgres function (Migration 0008), which checks that the approver email exists in `process_owners` and that the decision is APPROVED or REJECTED, then updates `hitl_queue.decision` from PENDING; the `hitl_queue_sod_guard` trigger fires on that UPDATE and aborts it if the approver matches the recorded invoker. The function does not write to `shadow_ledger`. The `HITL_RESOLVED` and `COMMITTED` events are written afterwards by two separate Writer calls, so the decision and its ledger events are not atomic: a failure after the function returns can leave a decided queue row without one or both events.

The split exists because of an empirical observation: a single GET endpoint that mutated state was being walked by Slack's link previewer the moment the message was posted, auto-resolving every queued HITL within seconds. The fix is HTTP semantics: GET reads, POST mutates. The split stops link previewers and prefetchers from resolving requests; it does not authorize the POST. CSRF tokens are not implemented; the handler's own architecture note lists this as a production gap. See *Build Decisions § 1* in the root README for the full story.

```
GET branch:
  Webhook (GET) Confirm
    └─ Validate Query Params
         └─ Lookup HITL Context [postgres]
              └─ Compose Confirmation HTML
                   └─ Respond Confirmation [HTML form]

POST branch:
  Webhook (POST) Resolve
    └─ Validate Body Params
         └─ Call fao_hitl_resolve [postgres function: queue UPDATE, SoD trigger fires]
              ├─ success → Read Shadow Ledger Events
              │              └─ Compose HITL_RESOLVED Payload
              │                   └─ Writer: HITL_RESOLVED
              │                        └─ Compose COMMITTED Payload
              │                             └─ Writer: COMMITTED
              │                                  └─ Respond Success [HTML]
              └─ error → Compose Error HTML → Respond Error
```

**Controls implemented:** FAO-GOV-004 (SoD trigger fires on the resolve function's UPDATE; identity binding is the known gap noted above), FAO-GOV-007 (approval-webhook progression from PENDING to a terminal decision), FAO-GOV-008 (correlation threading).

---

### `Writer` — the Shadow Ledger Writer (3 nodes)

Sub-workflow. Every workflow that writes to `shadow_ledger` routes through this one — the flagship, the HITL Gateway, the Approval Handler. There is no other path to insert ledger rows from n8n.

```
executeWorkflowTrigger
  └─ Validate Payload      [code: 7 required fields, 17-field normalized payload]
       └─ Insert Ledger Row [postgres → shadow_ledger]
```

**The 17-field payload** (normalized by `Validate Payload`; 7 fields required):

```
correlation_id · execution_id · agent_id · risk_tier · inputs · ai_prompt
ai_output · ai_confidence · fractional_cost_usd · policy_outcome
policy_sub_tier · policy_rationale · obligations · hitl_status
hitl_approver_id · status · error_details
```

The 7 required fields are `correlation_id`, `execution_id`, `agent_id`, `risk_tier`, `policy_outcome`, `policy_rationale` and `status`; a missing one throws a named error. `risk_tier`, `policy_outcome` and `status` are checked against their enums, and the two IDs against a UUID pattern. The other 10 fields are optional and default to `null`, `{}`, `[]` or `NOT_REQUIRED`. The Writer does not interpret values; that's the caller's job.

**Known issue in the committed export:** `Validate Payload` reads only `$input.first()` and returns one item, so the flagship's 7-item ASSET_RECONCILED batch persists only the first row (BTC). The evidence screenshot `docs/evidence/FAO-REC-001_flagship_full_execution_audit_trail.png` shows all 7 rows, so this export differs from the version that produced that evidence.

**Why this is plumbing, not an agent:** The Writer makes no policy decisions; it persists them. Putting it in the agent registry would be miscategorization. Centralizing the insert path means n8n writes ledger rows only by INSERT through one validated node, and at the database boundary the `shadow_ledger_append_only_guard` trigger rejects row-level UPDATE and DELETE (FAO-GOV-001). Defense in depth at different layers: see *Build Decisions § 4* in the root README.

**Controls implemented:** FAO-GOV-001 (single n8n insert path with structural checks; append-only is enforced by the database trigger).

---

## How to import

These JSON files were exported from n8n's *Workflow → Download* option. To import:

1. Open n8n.
2. Click *Workflows → Import from File*.
3. Select the JSON.
4. Reconnect the Postgres and Slack credentials (n8n redacts credential references on export).
5. Activate the workflow if it has a webhook or scheduled trigger.

**Import order matters** if you want a working chain end-to-end:

1. `writer.json` first (every other workflow calls into it).
2. `fao_hitl_gateway_v1.json` (calls Writer).
3. `fao_hitl_approval_handler_v2.json` (calls Writer).
4. `fao_reserve_recon_v1.json` (calls both Writer and HITL Gateway).

The test harnesses call the Writer and the HITL Gateway, so import them after those two and point them at a test environment.

---

## Conventions

- **Naming:** Production workflows use `fao_<area>_<purpose>_v<N>` slugs. The `Writer` is exported as `writer.json` historically; its workflow name inside n8n is `Writer`. Future versions will rename the file to `fao_shadow_ledger_writer_v1.json` for consistency.
- **Architecture Notes:** every production workflow except the Writer has a sticky note named `Architecture Note` summarizing the workflow's role and control IDs. Renders only inside n8n.
- **Sub-workflow triggers:** all sub-workflows start with `executeWorkflowTrigger` — they cannot be run standalone.
- **Code commenting:** the policy, validation and payload-composition `code` nodes have a top comment describing the node's role, the controls they implement and design notes; the approval handler's response and payload composers have a title banner only, and the Writer's `Validate Payload` has none. Read the comments first.

---

For the SOX control mapping, see [`../SOX-MAPPING.md`](../SOX-MAPPING.md).
For the per-control evidence and the Apr 25, 2026 self-audit, see [`../docs/evidence/`](../docs/evidence/).
For the architectural rationale behind these workflow shapes, see *Build Decisions & Lessons Learned* in the [root README](../README.md).
