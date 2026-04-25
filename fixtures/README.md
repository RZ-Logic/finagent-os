# Fixtures — Reserve Reconciliation Agent

Test fixtures for `fao_reserve_recon_v1`. Two paired files form a single
reconciliation snapshot:

- `wallet_data.json` — simulated on-chain wallet holdings (Fireblocks proxy)
- `ledger_data.json` — simulated internal client-liability ledger (NetSuite proxy)

In production these come from Fireblocks REST API and NetSuite General
Ledger saved searches respectively. Inline JSON for the smoke test isolates
the policy logic from data-source plumbing.

## Design principle

Fixtures aren't a snapshot of Kraken's actual reserves — they're test data
designed to exercise every branch of the Policy Outcome Decision Matrix in
a single execution. Three assets are calibrated to Kraken's published
December 2025 Proof of Reserves so the agent has real-world anchors; four
are synthetic scenarios constructed to demonstrate specific controls.

| Asset | Provenance                        | Wallet         | Ledger         | Ratio    | Expected Outcome              | Control       |
|-------|-----------------------------------|----------------|----------------|----------|-------------------------------|---------------|
| BTC   | Kraken Dec 2025 PoR anchor        | 167,690.25     | 167,188.68     | 1.003    | ALLOW_WITH_OBLIGATIONS        | FAO-REC-006   |
| ETH   | Kraken Dec 2025 PoR anchor        | 2,884,112      | 2,847,100      | 1.013    | ALLOW                         | FAO-REC-006   |
| USDC  | Synthetic clean baseline          | 891,723,456    | 891,723,456    | 1.000    | ALLOW                         | FAO-REC-006   |
| USDT  | Synthetic anomaly                 | 1,234,567,890  | 1,234,500,000  | 1.0000549| REQUIRE_HUMAN (STANDARD)      | FAO-REC-002   |
| SOL   | Synthetic anomaly                 | 8,740,000      | 9,200,000      | 0.950    | REQUIRE_HUMAN (CRITICAL)      | FAO-REC-004   |
| XRP   | Kraken Dec 2025 PoR anchor        | 128,265,000    | 127,500,000    | 1.006    | ALLOW                         | FAO-REC-006   |
| ADA   | Synthetic anomaly                 | 47,293,847     | -150,000       | undefined| REQUIRE_HUMAN (CRITICAL)      | FAO-REC-007   |

A single execution exercises five distinct policy outcomes: ALLOW,
ALLOW_WITH_OBLIGATIONS, REQUIRE_HUMAN STANDARD, and REQUIRE_HUMAN CRITICAL
(twice, for two different control violations). Execution rollup is
REQUIRE_HUMAN CRITICAL — worst-asset rule.

## Real-world anchor: Kraken's December 2025 PoR

Source: https://blog.kraken.com/news/december-2025-proof-of-reserves

| Asset | Dec 31, 2025 Reserve Ratio |
|-------|----------------------------|
| BTC   | 100.3%                     |
| ETH   | 101.3%                     |
| SOL   | 101.1%                     |
| USDC  | 105%+                      |
| USDT  | 105%+                      |
| XRP   | 100.6%                     |
| ADA   | 102.2%                     |

Notable: Kraken's BTC ratio shifted materially from 114.9% (March 2025) to
100.3% (December 2025) — a documented buffer-reserve tightening. The
agent's BTC fixture reflects this current state.

## Real-world anchor: krakendb (2014)

ADA's negative-ledger anomaly is patterned on Kraken's 2014 reference
implementation, where a "large negative value at a Merkle leaf" was
explicitly flagged as a condition requiring investigation. FAO-REC-007
operationalizes this as a deterministic policy rule: any negative client
liability routes to CRITICAL HITL regardless of wallet state, because the
reserve ratio is mathematically undefined when liability is negative.

## Why fixtures are intentionally mixed

A naive "all real Dec 2025 numbers" fixture would produce six clean
ALLOWs and one ALLOW_WITH_OBLIGATIONS. The policy engine's
REQUIRE_HUMAN paths would never fire — under-reservation, USD
materiality, and negative-liability handling would have zero evidence
of working. The mixed fixture design ensures every control surface is
exercised in evidence.

## Provenance threading

Each fixture entry carries a `_provenance` field that the agent threads
into `shadow_ledger.inputs.fixture_metadata` for every ASSET_RECONCILED
row. Auditor query:

```sql
SELECT
  inputs->>'asset' AS asset,
  inputs->'fixture_metadata'->>'source' AS provenance,
  policy_outcome,
  policy_sub_tier
FROM shadow_ledger
WHERE inputs->>'event_type' = 'ASSET_RECONCILED'
ORDER BY ledger_id;
```

Every ledger row self-identifies as PoR-anchored or synthetic-anomaly.
This is FAO-GOV-014 (control evidence transparency): test data is
labeled in production audit trails rather than concealed.

## Production transition

Post-launch, the Init Execution node's inline `wallet_data` and
`ledger_data` constants will be replaced with calls to `Read/Write
Files from Disk` reading these JSON files, then later by HTTP Request
nodes against Fireblocks and NetSuite. The fixture file structure
matches the production schema so the swap is a node-level change, not
a logic change.