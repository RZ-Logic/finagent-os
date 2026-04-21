-- ============================================================================
-- FinAgent OS — Migration 0006: materiality_thresholds + Seed
-- ============================================================================
-- Per-asset materiality thresholds and expected reserve ratio bands for the
-- Reserve Reconciliation Agent. This table operationalizes Principle #8 from
-- the architecture: escalation triggers on deviation from a per-asset band,
-- not on a single 1.00 floor. Exchanges over-reserve by design (Kraken
-- published a BTC reserve ratio of 114.9% in a prior reporting period).
-- A naive single-floor agent would escalate every clean run.
--
-- The scope column matches Kraken's own Dec 2025 attestation scope evolution
-- (Spot / Futures / Spot_and_Futures). Today's seed populates Spot rows for
-- the seven in-scope assets. Futures rows would be added when Futures
-- reconciliation is enabled.
--
-- Control IDs implemented:
--   FAO-REC-002  Per-Asset Materiality Threshold Evaluation
--   FAO-REC-004  Reserve Ratio Threshold Check
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

CREATE TABLE public.materiality_thresholds (
  -- Asset code — BTC, ETH, USDC, etc. Part of composite PK with scope.
  asset_symbol      TEXT              NOT NULL,

  -- Attestation scope granularity. Spot and Futures have different
  -- appropriate ratio bands; composite PK allows per-scope tuning.
  scope             attestation_scope NOT NULL DEFAULT 'Spot',

  -- Asset classification. Drives default band widths: stablecoins get
  -- tight bands (1.00 to 1.005), majors get wider bands.
  asset_class       asset_class       NOT NULL,

  -- USD-value materiality threshold. Discrepancies above this value
  -- escalate regardless of ratio — small ratios on large asset pools
  -- can still be material in absolute dollars.
  materiality_usd   NUMERIC(14,2)     NOT NULL CHECK (materiality_usd > 0),

  -- Absolute floor. If reserve ratio falls below this value, the policy
  -- engine routes to REQUIRE_HUMAN (critical) regardless of other signals.
  -- Default 1.00 reflects the "reserves must equal or exceed liabilities"
  -- principle — anything below is definitionally under-reserved.
  ratio_floor       NUMERIC(5,4)      NOT NULL CHECK (ratio_floor > 0),

  -- Lower bound of the expected-ratio band. Agents do not escalate on
  -- ratios within [ratio_band_lower, ratio_band_upper]. Typically 1.00,
  -- meaning "fully reserved or better".
  ratio_band_lower  NUMERIC(5,4)      NOT NULL CHECK (ratio_band_lower > 0),

  -- Upper bound of the expected-ratio band. Over-reservation above this
  -- triggers investigation (unexpected surplus could indicate a ledger
  -- error on the other side of the comparison).
  ratio_band_upper  NUMERIC(5,4)      NOT NULL CHECK (ratio_band_upper >= ratio_band_lower),

  -- Band coherence: floor <= lower <= upper
  CONSTRAINT band_coherence CHECK (ratio_floor <= ratio_band_lower),

  -- Free-text notes explaining the rationale for each threshold.
  -- Appears in audit evidence packages.
  notes             TEXT,

  -- Governance metadata: who last reviewed this threshold, when.
  last_reviewed_by  UUID              REFERENCES public.process_owners(id) ON DELETE SET NULL,
  last_reviewed_at  TIMESTAMPTZ,

  -- Standard timestamps
  created_at        TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

  -- Composite PK allows (BTC, Spot) and (BTC, Futures) to coexist with
  -- different bands.
  PRIMARY KEY (asset_symbol, scope)
);

-- --- RLS --------------------------------------------------------------------

ALTER TABLE public.materiality_thresholds ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read all thresholds. Agents, dashboards, and
-- audit exports all need this.
CREATE POLICY "Authenticated users can read materiality_thresholds"
  ON public.materiality_thresholds
  FOR SELECT
  TO authenticated
  USING (true);

-- Only service_role can mutate. Threshold changes are formal governance
-- events — they happen via the Supabase dashboard by a Controller/CFO,
-- not via any agent or end-user identity.
CREATE POLICY "Only service_role can insert materiality_thresholds"
  ON public.materiality_thresholds
  FOR INSERT
  TO service_role
  WITH CHECK (true);

CREATE POLICY "Only service_role can update materiality_thresholds"
  ON public.materiality_thresholds
  FOR UPDATE
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Only service_role can delete materiality_thresholds"
  ON public.materiality_thresholds
  FOR DELETE
  TO service_role
  USING (true);

-- --- Comments for introspection --------------------------------------------

COMMENT ON TABLE  public.materiality_thresholds                 IS 'FAO-REC-002, FAO-REC-004: Per-asset materiality USD thresholds and expected reserve ratio bands. Drives the Reserve Reconciliation Agents escalation logic.';
COMMENT ON COLUMN public.materiality_thresholds.ratio_floor     IS 'Absolute floor below which the agent routes to REQUIRE_HUMAN (critical). Default 1.00 = fully-reserved.';
COMMENT ON COLUMN public.materiality_thresholds.ratio_band_upper IS 'Upper bound of normal-operating range. Above this, investigate unexpected surplus.';
