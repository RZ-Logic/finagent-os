# Fixtures — Reserve Reconciliation Agent

Test fixtures for `fao_reserve_recon_v1`. Two paired files form a single
reconciliation snapshot:

- `wallet_data.json` — simulated on-chain wallet holdings (Fireblocks proxy)
- `ledger_data.json` — simulated internal client-liability ledger (NetSuite proxy)

In production these come from Fireblocks REST API and NetSuite General
Ledger saved searches respectively. Inline JSON for the smoke test isolates
the policy logic from data-source plumbing. The workflow does not read these
files: `Init Execution` uses inline constants equal to them. Since round 5
ADA's wallet balance is 47,293,847 in both (`wallet_data.json` used to say
47,293,847.92; the inline value, which the recorded runs used, was kept).
`test/node/fixtures.test.mjs` runs `Init Execution` and fails unless its
wallet, ledger and provenance values equal these two files and the table
below, then runs `Check Thresholds` and `Per-Asset Reconcile` on that
output with the `policy_branches.json` thresholds (checked equal to seed
0006) and asserts each row's outcome, ratio and control, and the five band
statuses named below. `policy_branches.json` drives every other branch
(`test/node/recon.test.mjs`).

## Design principle

Fixtures aren't a snapshot of Kraken's actual reserves. They are test data
designed to exercise four of the seven rules in the Policy Outcome Decision
Matrix in a single execution (five before the owner decision of 2026-11-08
on stablecoin USD materiality, below). Three assets are calibrated to Kraken's published
December 2025 Proof of Reserves so the agent has real-world anchors; four
are synthetic scenarios constructed to demonstrate specific controls.

| Asset | Provenance                        | Wallet         | Ledger         | Ratio    | Expected Outcome              | Control       |
|-------|-----------------------------------|----------------|----------------|----------|-------------------------------|---------------|
| BTC   | Kraken Dec 2025 PoR anchor        | 167,690.25     | 167,188.68     | 1.003    | ALLOW_WITH_OBLIGATIONS        | FAO-REC-006   |
| ETH   | Kraken Dec 2025 PoR anchor        | 2,884,112      | 2,847,100      | 1.013    | ALLOW                         | FAO-REC-006   |
| USDC  | Synthetic clean baseline          | 891,723,456    | 891,723,456    | 1.000    | ALLOW                         | FAO-REC-006   |
| USDT  | Synthetic anomaly                 | 1,234,567,890.50 | 1,234,500,000 | 1.0000549| ALLOW                         | FAO-REC-002   |
| SOL   | Synthetic anomaly                 | 8,740,000      | 9,200,000      | 0.950    | REQUIRE_HUMAN (CRITICAL)      | FAO-REC-004   |
| XRP   | Kraken Dec 2025 PoR anchor        | 128,265,000    | 127,500,000    | 1.006    | ALLOW                         | FAO-REC-006   |
| ADA   | Synthetic anomaly                 | 47,293,847     | -150,000       | undefined| REQUIRE_HUMAN (CRITICAL)      | FAO-REC-007   |

A single execution exercises three distinct outcome categories: ALLOW,
ALLOW_WITH_OBLIGATIONS and REQUIRE_HUMAN CRITICAL (twice, for two different
control violations). These are three `policy_outcome` values and one
sub-tier. In decision-matrix terms the run reaches four band statuses:
IN_BAND, BELOW_BAND_LOWER, BELOW_FLOOR and NEGATIVE_LEDGER. It does not
exercise ZERO_LEDGER (rule 2), ABOVE_BAND_UPPER (rule 4),
IN_BAND_USD_MATERIAL (rule 5), REQUIRE_HUMAN STANDARD, or the NO_THRESHOLD
pre-check that marks an asset BLOCKED; `policy_branches.json` covers each of
them offline. No rule produces DENY. Execution rollup is REQUIRE_HUMAN
CRITICAL (worst-asset rule).

USDT is a $67,890.50 surplus at ratio 1.0000549, inside the stablecoin band
and above the $10,000 materiality. Until the owner decision of 2026-11-08 it
escalated as IN_BAND_USD_MATERIAL (REQUIRE_HUMAN STANDARD). Since then the
stablecoin USD materiality rule (rule 5, FAO-REC-002) tests a shortfall
only, ledger minus wallet above `materiality_usd`; a surplus inside the band
is governed by the band upper (1.05) alone, so USDT now ALLOWs. Its
rationale still names FAO-REC-002 and records that the surplus exceeded
materiality. The provenance label stays `synthetic_anomaly` (the e2e S20
provenance check reads it).

## Why the STARTED row says ALLOW

The STARTED row of every run carries `policy_outcome` ALLOW, `status`
SUCCESS and `hitl_status` NOT_REQUIRED. That is a database rule, not a
policy result: `fao_ledger_append_batch` (migration 0014) refuses any other
STARTED item with `STARTED must be ALLOW and SUCCESS`. STARTED records that
the claimed run began and fixes its asset scope; no asset has been
reconciled yet, so there is nothing to deny or escalate. The run's outcome
is the worst ASSET_RECONCILED outcome, which `fao_run_finalize` rolls up
from the stored events (REQUIRE_HUMAN CRITICAL for this snapshot). The
fixture test asserts the STARTED fields and the 0014 rule.

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

Stablecoins: the seeded USDC and USDT `ratio_band_upper` is 1.05
(`supabase/seeds/0006_materiality_thresholds_seed.sql`, IC-38), following
the owner's decision of 2026-11-07 that stablecoin reserves are held near
105%. The floor and band lower stay at 1.00. A stablecoin ratio up to and
including 1.05 is in band; above 1.05 it hits rule 4, ABOVE_BAND_UPPER, and
escalates to REQUIRE_HUMAN STANDARD. Inside the band the USD materiality
rule (rule 5) applies to a shortfall only (owner decision 2026-11-08): a
surplus up to 1.05 ALLOWs whatever its USD size. With the seeded floor and
band lower of 1.00, a stablecoin shortfall is BELOW_FLOOR (rule 3, CRITICAL)
before rule 5 is tested, so rule 5 fires only for a stablecoin threshold
whose floor is below 1.00; `policy_branches.json` covers it with a
per-case `thresholds_override` (floor 0.98, band lower 0.99). The v1 seed held 1.0050; the live table keeps
that value until the cutover runbook step applies 1.05 through
`fao_admin_set_threshold`. `policy_branches.json` carries the 1.05 band and
these stablecoin cases: `stablecoin_in_band_near_105` (ratio 1.04, ALLOW,
which the old 1.005 band escalated), `stablecoin_above_band_upper` (ratio
1.051), `stablecoin_surplus_in_band_above_materiality` (the flagship USDT,
renamed from `in_band_usd_material`, now ALLOW),
`stablecoin_kraken_scale_surplus` (USDC ledger 10,000,000 at ratio 1.04, a
$400,000 surplus, ALLOW), `stablecoin_shortfall_seeded_floor` (a $50,000
shortfall under the seeds, BELOW_FLOOR), and, under the override,
`stablecoin_shortfall_in_band_usd_material` (a $50,000 shortfall at ratio
0.995, IN_BAND_USD_MATERIAL) and
`stablecoin_shortfall_in_band_below_materiality` (a $5,000 shortfall,
ALLOW). Kraken's snapshot also covers more than Spot, so its ratios
are not directly comparable with the Spot-only seeds.

## Real-world anchor: krakendb (2014)

ADA's negative-ledger anomaly is patterned on Kraken's 2014 reference
implementation, where a "large negative value at a Merkle leaf" was
explicitly flagged as a condition requiring investigation. FAO-REC-007
operationalizes this as a deterministic policy rule: any negative client
liability routes to CRITICAL HITL regardless of wallet state, because the
reserve ratio is mathematically undefined when liability is negative.

## Why fixtures are intentionally mixed

A naive "all real Dec 2025 numbers" fixture, under the seeded thresholds,
would produce four ALLOWs (ETH, SOL, XRP, ADA) and one ALLOW_WITH_OBLIGATIONS
(BTC). USDC and USDT at 105%+ would be ALLOW at exactly 1.05 (a surplus
inside the band does not escalate on USD materiality, owner decision
2026-11-08) and REQUIRE_HUMAN STANDARD (ABOVE_BAND_UPPER) above it. The
under-reservation and negative-liability paths would never fire and would
have zero evidence of working. The mixed fixture design exercises those two
paths and a stablecoin surplus above materiality that ALLOWs (USDT, ratio
1.0000549) in evidence; it does not exercise every rule (see the gaps listed
above).

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
step as well as new nodes. The reconcile logic already fails closed on
its inputs: the asset scope is the union of wallet and ledger keys, an
asset present on one side only is BLOCKED (`ONE_SIDED`), a missing,
non-numeric, NaN or infinite balance is BLOCKED (`INVALID_INPUT`), and an
asset with no usable threshold is BLOCKED (`NO_THRESHOLD`); each routes
the run to human review.