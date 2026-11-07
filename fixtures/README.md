# Fixtures — Reserve Reconciliation Agent

Test fixtures for `fao_reserve_recon_v1`. Two paired files form a single
reconciliation snapshot:

- `wallet_data.json` — simulated on-chain wallet holdings (Fireblocks proxy)
- `ledger_data.json` — simulated internal client-liability ledger (NetSuite proxy)

In production these come from Fireblocks REST API and NetSuite General
Ledger saved searches respectively. Inline JSON for the smoke test isolates
the policy logic from data-source plumbing. The workflow does not read these
files: `Init Execution` uses inline constants that match them except for
ADA's wallet balance (47,293,847 inline, 47,293,847.92 in `wallet_data.json`).

## Design principle

Fixtures aren't a snapshot of Kraken's actual reserves. They are test data
designed to exercise five of the seven rules in the Policy Outcome Decision
Matrix in a single execution. Three assets are calibrated to Kraken's published
December 2025 Proof of Reserves so the agent has real-world anchors; four
are synthetic scenarios constructed to demonstrate specific controls.

| Asset | Provenance                        | Wallet         | Ledger         | Ratio    | Expected Outcome              | Control       |
|-------|-----------------------------------|----------------|----------------|----------|-------------------------------|---------------|
| BTC   | Kraken Dec 2025 PoR anchor        | 167,690.25     | 167,188.68     | 1.003    | ALLOW_WITH_OBLIGATIONS        | FAO-REC-006   |
| ETH   | Kraken Dec 2025 PoR anchor        | 2,884,112      | 2,847,100      | 1.013    | ALLOW                         | FAO-REC-006   |
| USDC  | Synthetic clean baseline          | 891,723,456    | 891,723,456    | 1.000    | ALLOW                         | FAO-REC-006   |
| USDT  | Synthetic anomaly                 | 1,234,567,890.50 | 1,234,500,000 | 1.0000549| REQUIRE_HUMAN (STANDARD)      | FAO-REC-002   |
| SOL   | Synthetic anomaly                 | 8,740,000      | 9,200,000      | 0.950    | REQUIRE_HUMAN (CRITICAL)      | FAO-REC-004   |
| XRP   | Kraken Dec 2025 PoR anchor        | 128,265,000    | 127,500,000    | 1.006    | ALLOW                         | FAO-REC-006   |
| ADA   | Synthetic anomaly                 | 47,293,847     | -150,000       | undefined| REQUIRE_HUMAN (CRITICAL)      | FAO-REC-007   |

A single execution exercises four distinct outcome categories: ALLOW,
ALLOW_WITH_OBLIGATIONS, REQUIRE_HUMAN STANDARD, and REQUIRE_HUMAN CRITICAL
(twice, for two different control violations). These are three
`policy_outcome` values plus two sub-tiers. In decision-matrix terms the run
reaches five band statuses: IN_BAND, BELOW_BAND_LOWER, IN_BAND_USD_MATERIAL,
BELOW_FLOOR and NEGATIVE_LEDGER. It does not exercise ZERO_LEDGER (rule 2),
ABOVE_BAND_UPPER (rule 4), or the NO_THRESHOLD pre-check that marks an asset
BLOCKED. No rule produces DENY. Execution rollup is REQUIRE_HUMAN CRITICAL
(worst-asset rule).

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

Stablecoins: the seeded USDC and USDT `ratio_band_upper` is 1.005
(`supabase/seeds/0006_materiality_thresholds_seed.sql`), below Kraken's
published 105%+. A stablecoin reconciled at that posture (ratio about 1.05)
would hit rule 4, ABOVE_BAND_UPPER, and escalate to REQUIRE_HUMAN STANDARD.
Whether surplus at that level should escalate is a policy choice. Kraken's
snapshot also covers more than Spot, so its ratios are not directly
comparable with the Spot-only seeds.

## Real-world anchor: krakendb (2014)

ADA's negative-ledger anomaly is patterned on Kraken's 2014 reference
implementation, where a "large negative value at a Merkle leaf" was
explicitly flagged as a condition requiring investigation. FAO-REC-007
operationalizes this as a deterministic policy rule: any negative client
liability routes to CRITICAL HITL regardless of wallet state, because the
reserve ratio is mathematically undefined when liability is negative.

## Why fixtures are intentionally mixed

A naive "all real Dec 2025 numbers" fixture, under the seeded thresholds,
would produce four ALLOWs (ETH, SOL, XRP, ADA), one ALLOW_WITH_OBLIGATIONS
(BTC), and two REQUIRE_HUMAN STANDARD escalations (USDC and USDT above their
1.005 band upper). The under-reservation, USD-materiality and
negative-liability paths would never fire and would have zero evidence of
working. The mixed fixture design exercises those three paths in evidence;
it does not exercise every rule (see the gaps listed above).

## Provenance threading

Each fixture file entry carries a `_provenance` field. The workflow's inline
equivalent is the per-asset `fixture_metadata` map in `Init Execution`
(`source`, plus `control` for anomalies and `reference_url` for Kraken
anchors). It is recorded once per run, on the STARTED row, under
`shadow_ledger.inputs.fixture_provenance`. ASSET_RECONCILED rows do not
carry provenance, so the auditor query joins each asset row to its run's
STARTED row by `correlation_id`:

```sql
SELECT
  a.correlation_id,
  a.inputs->>'asset' AS asset,
  s.inputs->'fixture_provenance'->(a.inputs->>'asset')->>'source' AS provenance,
  a.policy_outcome,
  a.policy_sub_tier
FROM shadow_ledger a
JOIN shadow_ledger s
  ON s.correlation_id = a.correlation_id
 AND s.inputs->>'event_type' = 'STARTED'
WHERE a.inputs->>'event_type' = 'ASSET_RECONCILED'
ORDER BY a.ledger_id;
```

Each run's STARTED row identifies every asset as PoR-anchored, clean
baseline or synthetic anomaly, so test data is labeled in the audit trail
rather than concealed. This labeling is not a numbered control in
`SOX-MAPPING.md`, where FAO-GOV-014 is AI Disabled by Default.

## Production transition

Post-launch, the Init Execution node's inline `wallet_data` and
`ledger_data` constants will be replaced with calls to `Read/Write
Files from Disk` reading these JSON files, then later by HTTP Request
nodes against Fireblocks and NetSuite. The fixture files hold per-asset
object arrays (under `wallets` and `ledger`, with `wallet_balance` and
`client_liabilities`), while
`Per-Asset Reconcile` reads asset-keyed maps, so the swap needs a mapping
step as well as new nodes. Before live feeds, the reconcile logic also
needs input completeness checks: it iterates wallet assets only and does
not reject a missing or non-numeric balance.