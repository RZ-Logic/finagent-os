# `workflows/` — n8n Workflow Index

> **For navigation only.** This directory contains exported n8n workflow JSON files. They are machine-generated artifacts (node positions, internal UUIDs, wire references) and are not intended to be read top-to-bottom. This index points you at the parts that contain real engineering — typically the `jsCode` blocks inside `code` nodes — and away from the n8n plumbing.

If you're scanning code, the policy logic lives in the `code` nodes. The deterministic decision matrices, payload validators, and audit-row composers are all written in commented JavaScript inside those nodes. Open the JSON, search for `"jsCode"`, and the interesting work is there.

For the platform-level architecture and the SOX control mapping, see [`../SOX-MAPPING.md`](../SOX-MAPPING.md). For build-decision context (why these workflows are shaped this way), see the *Build Decisions & Lessons Learned* section in the [root README](../README.md).

---

## Production workflows

| File | Workflow Name | Role | Trigger | Where the interesting code lives |
|---|---|---|---|---|
| [`fao_reserve_recon_v1.json`](./fao_reserve_recon_v1.json) | `fao_reserve_recon_v1` | **Flagship.** Reserve Reconciliation Agent. RED-tier. | Manual + (production) webhook | `Per-Asset Reconcile` node — the deterministic policy decision matrix |
| [`fao_hitl_gateway_v1.json`](./fao_hitl_gateway_v1.json) | `fao_hitl_gateway_v1` | HITL gate. Inserts queue rows; sends Slack notification. | `executeWorkflowTrigger` (called by flagship) | `Validate Payload` node — required-field contract |
| [`fao_hitl_approval_handler_v2.json`](./fao_hitl_approval_handler_v2.json) | `fao_hitl_approval_handler_v2` | Slack-link approval endpoint. **GET shows form, POST mutates.** | Two webhooks: GET `/hitl/confirm`, POST `/hitl/resolve` | `Compose Confirmation HTML` (GET) + `Call fao_hitl_resolve` (POST) |
| [`writer.json`](./writer.json) | `Writer` (Shadow Ledger Writer) | Plumbing. Validates and inserts every `shadow_ledger` row. | `executeWorkflowTrigger` (called by every other workflow) | `Validate Payload` node — the 17-field contract |

## Test harnesses

| File | Purpose |
|---|---|
| [`Test_Writer_Harness__Multi-Item_.json`](./Test_Writer_Harness__Multi-Item_.json) | Verifies the Writer accepts a multi-item input and inserts each as a separate row. Used during writer development. |
| [`test_hitl_gateway_harness.json`](./test_hitl_gateway_harness.json) | Drives the HITL Gateway with a synthetic payload. Used to validate gateway behaviour without invoking the full flagship chain. |

These are not part of the production execution path. They exist to verify sub-workflows work standalone.

---

## Per-workflow notes

### `fao_reserve_recon_v1` — the flagship (12 nodes)

```
Manual Trigger
  └─ Init Execution                  [code: correlation_id, fixtures, agent metadata]
       └─ Writer: STARTED            [executeWorkflow → Writer]
            └─ Get Materiality Thresholds   [postgres → materiality_thresholds]
                 └─ Per-Asset Reconcile     [code: THE POLICY ENGINE]
                      └─ Writer: ASSET_RECONCILED   [executeWorkflow → Writer, 7 items]
                           └─ Aggregate Rollup     [code: worst-asset-wins]
                                └─ Any HITL Required?   [if branch]
                                     ├─ true (NOT_REQUIRED) → Writer: COMMITTED
                                     └─ false (REQUIRE_HUMAN)
                                          └─ Compose HITL Gateway Payload
                                               └─ HITL Gateway  [executeWorkflow]
```

**Where to look first if you're reviewing the engineering quality:**

- `Per-Asset Reconcile` node, `jsCode` block. ~120 lines. This is the deterministic decision matrix — 7 rules evaluated top-down, first match wins. Each rule is commented with its FAO-REC control ID. No LLM in the policy path.
- `Init Execution` node, `jsCode` block. The fixture data is embedded inline with provenance metadata per asset (3 Kraken Dec 2025 PoR anchors + 1 clean baseline + 3 synthetic anomalies). The provenance is threaded into every Shadow Ledger row's `inputs.fixture_metadata` for audit reproducibility.
- `Aggregate Rollup` node. Implements the worst-asset-wins rollup rule and the rationale string composition.
- `Architecture Note` sticky note. Renders inside n8n with a one-paragraph summary; safe to ignore in the JSON view.

**Controls implemented:** FAO-REC-001, 002, 004, 006, 007 + FAO-GOV-001 (via Writer), FAO-GOV-008, FAO-GOV-013.

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

The HTTP server that handles approval link clicks. **Two webhooks, deliberately separated:**

- `GET /hitl/confirm` — renders an HTML confirmation page. Idempotent; no state mutation. This is what Slack's link-unfurling bot hits when previewing the message.
- `POST /hitl/resolve` — performs the approval. Calls the `fao_hitl_resolve` Postgres function (Migration 0008), which atomically validates SoD, updates `hitl_queue.decision`, writes the `HITL_RESOLVED` and `COMMITTED` events to `shadow_ledger`, and returns the resulting state.

The split exists because of an empirical observation: a single GET endpoint that mutated state was being walked by Slack's link previewer the moment the message was posted, auto-resolving every queued HITL within seconds. The fix is HTTP semantics, not a CSRF token — though CSRF tokens are added on top as a second layer. See *Build Decisions § 1* in the root README for the full story.

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
         └─ Call fao_hitl_resolve [postgres function — atomic SoD + update]
              ├─ success → Read Shadow Ledger Events
              │              └─ Compose HITL_RESOLVED Payload
              │                   └─ Writer: HITL_RESOLVED
              │                        └─ Compose COMMITTED Payload
              │                             └─ Writer: COMMITTED
              │                                  └─ Respond Success [HTML]
              └─ error → Compose Error HTML → Respond Error
```

**Controls implemented:** FAO-GOV-004 (SoD enforcement at function call boundary), FAO-GOV-008 (correlation threading).

---

### `Writer` — the Shadow Ledger Writer (3 nodes)

Sub-workflow. Every workflow that writes to `shadow_ledger` routes through this one — the flagship, the HITL Gateway, the Approval Handler. There is no other path to insert ledger rows from n8n.

```
executeWorkflowTrigger
  └─ Validate Payload      [code: 17-field structural contract]
       └─ Insert Ledger Row [postgres → shadow_ledger]
```

**The 17-field contract** (validated by `Validate Payload`):

```
correlation_id · execution_id · agent_id · risk_tier · inputs · ai_prompt
ai_output · ai_confidence · fractional_cost_usd · policy_outcome
policy_sub_tier · policy_rationale · obligations · hitl_status
hitl_approver_id · status · error_details
```

Required fields throw a named error. Optional AI fields can be `null`. The Writer does not interpret values — that's the caller's job. It only validates that all required fields are present and structurally correct.

**Why this is plumbing, not an agent:** The Writer makes no policy decisions; it persists them. Putting it in the agent registry would be miscategorization. Centralizing the insert path means FAO-GOV-001 (append-only) is enforced at the application boundary by the Writer's structural validation, *and* at the database boundary by the `shadow_ledger_append_only_guard` trigger. Defense in depth at different layers — see *Build Decisions § 4* in the root README.

**Controls implemented:** FAO-GOV-001 (application-layer enforcement boundary).

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

The test harnesses are independent and can be imported any time.

---

## Conventions

- **Naming:** Production workflows use `fao_<area>_<purpose>_v<N>` slugs. The `Writer` is exported as `writer.json` historically; its workflow name inside n8n is `Writer`. Future versions will rename the file to `fao_shadow_ledger_writer_v1.json` for consistency.
- **Architecture Notes:** every production workflow has a sticky note named `Architecture Note` summarizing the workflow's role, control IDs, and rollback posture. Renders only inside n8n.
- **Sub-workflow triggers:** all sub-workflows start with `executeWorkflowTrigger` — they cannot be run standalone.
- **Code commenting:** every `code` node's `jsCode` block has a top comment describing the node's role, the controls it implements, and design notes. Read the comments first.

---

For the SOX control mapping, see [`../SOX-MAPPING.md`](../SOX-MAPPING.md).
For the per-control evidence and the Apr 25, 2026 self-audit, see [`../docs/evidence/`](../docs/evidence/).
For the architectural rationale behind these workflow shapes, see *Build Decisions & Lessons Learned* in the [root README](../README.md).
