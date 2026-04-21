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
--   - USDC/USDT: 1.00-1.005 Stablecoins. Tight band - any deviation from
--                           1:1 reflects operational or ledger error.
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
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

INSERT INTO public.materiality_thresholds
  (asset_symbol, scope, asset_class, materiality_usd,
   ratio_floor, ratio_band_lower, ratio_band_upper, notes)
VALUES
  ('BTC',  'Spot', 'Major',      500000.00, 1.0000, 1.0500, 1.2500,
   'Kraken published BTC reserve ratio of 114.9% in a prior reporting period. Band accommodates documented over-reservation posture; below 1.05 investigate under-reserve drift, above 1.25 investigate unexpected surplus.'),

  ('ETH',  'Spot', 'Major',      250000.00, 1.0000, 1.0000, 1.1000,
   'Major asset with moderate over-reservation tolerance.'),

  ('USDC', 'Spot', 'Stablecoin', 10000.00,  1.0000, 1.0000, 1.0050,
   'Stablecoin. Tight band - 1:1 redemption is the peg; any meaningful deviation reflects operational or ledger error.'),

  ('USDT', 'Spot', 'Stablecoin', 10000.00,  1.0000, 1.0000, 1.0050,
   'Stablecoin. Tight band - 1:1 redemption is the peg; any meaningful deviation reflects operational or ledger error.'),

  ('SOL',  'Spot', 'Mid_cap',    100000.00, 1.0000, 1.0000, 1.1500,
   'Mid-cap with wider band reflecting price volatility and settlement timing.'),

  ('XRP',  'Spot', 'Major',      100000.00, 1.0000, 1.0000, 1.1000,
   'Major asset with moderate over-reservation tolerance.'),

  ('ADA',  'Spot', 'Major',      100000.00, 1.0000, 1.0000, 1.1000,
   'Major asset with moderate over-reservation tolerance.');
