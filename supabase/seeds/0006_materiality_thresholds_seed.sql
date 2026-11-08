-- ============================================================================
-- FinAgent OS — Seed 0006: materiality_thresholds (7 assets, Spot scope)
-- ============================================================================
-- Populates the 7 in-scope assets for Kraken's Dec 2025 attestation:
-- BTC, ETH, USDC, USDT, SOL, XRP, ADA (Spot scope only).
--
-- Band design rationale:
--   - BTC:       1.05-1.25  Kraken published 114.9% in a prior reporting
--                           period; band accommodates their documented
--                           over-reservation posture.
--   - ETH:       1.00-1.10  Major asset, moderate band.
--   - USDC/USDT: 1.00-1.05  Stablecoins. Floor and lower band stay at 1:1;
--                           the upper band follows the owner's decision
--                           (2026-11-07, F-24 / REG-A24, IC-38) that
--                           stablecoin reserves are held near 105%, so a
--                           surplus up to 1.05 is in band and only a ratio
--                           above 1.05 is ABOVE_BAND_UPPER. Before patch
--                           round 6 the upper band was 1.005. The live
--                           table still holds 1.0050 from the v1 seed; the
--                           cutover runbook applies 1.0500 through
--                           fao_admin_set_threshold with a change reason.
--   - SOL:       1.00-1.15  Mid-cap; wider band reflects volatility.
--   - XRP/ADA:   1.00-1.10  Majors with moderate bands.
--
-- Materiality USD values are illustrative calibration points, not
-- Kraken-published figures. They scale with typical trading volume
-- and risk appetite per asset.
--
-- last_reviewed_by is initially NULL. Thresholds will be formally
-- reviewed by the Controller in the first quarterly governance cycle.
--
-- Phase 2-5: the first statement sets fao.change_reason, which every change
-- to materiality_thresholds now needs (FAO-GOV-002).
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

-- FAO-GOV-002: change reason for this session (required by the
-- materiality_thresholds triggers).
SELECT set_config('fao.change_reason', 'seed 0006', false);

INSERT INTO public.materiality_thresholds
  (asset_symbol, scope, asset_class, materiality_usd,
   ratio_floor, ratio_band_lower, ratio_band_upper, notes)
VALUES
  ('BTC',  'Spot', 'Major',      500000.00, 1.0000, 1.0500, 1.2500,
   'Kraken published BTC reserve ratio of 114.9% in a prior reporting period. Band accommodates documented over-reservation posture; below 1.05 investigate under-reserve drift, above 1.25 investigate unexpected surplus.'),

  ('ETH',  'Spot', 'Major',      250000.00, 1.0000, 1.0000, 1.1000,
   'Major asset with moderate over-reservation tolerance.'),

  ('USDC', 'Spot', 'Stablecoin', 10000.00,  1.0000, 1.0000, 1.0500,
   'Stablecoin. 1:1 redemption is the peg and the floor; the upper band of 1.05 follows the owner decision (2026-11-07) that stablecoin reserves are held near 105%. Below 1.00 investigate under-reserve; above 1.05 investigate unexpected surplus. USD materiality still applies inside the band.'),

  ('USDT', 'Spot', 'Stablecoin', 10000.00,  1.0000, 1.0000, 1.0500,
   'Stablecoin. 1:1 redemption is the peg and the floor; the upper band of 1.05 follows the owner decision (2026-11-07) that stablecoin reserves are held near 105%. Below 1.00 investigate under-reserve; above 1.05 investigate unexpected surplus. USD materiality still applies inside the band.'),

  ('SOL',  'Spot', 'Mid_cap',    100000.00, 1.0000, 1.0000, 1.1500,
   'Mid-cap with wider band reflecting price volatility and settlement timing.'),

  ('XRP',  'Spot', 'Major',      100000.00, 1.0000, 1.0000, 1.1000,
   'Major asset with moderate over-reservation tolerance.'),

  ('ADA',  'Spot', 'Major',      100000.00, 1.0000, 1.0000, 1.1000,
   'Major asset with moderate over-reservation tolerance.');
