-- ============================================================================
-- FinAgent OS — Seed 0003: agent_registry
-- ============================================================================
-- Seeds the four agents that constitute the formalized control population
-- for the Apr 26 launch: one flagship (ACTIVE) and three stubs
-- (STUB_DOCUMENTED) that inherit governance controls but have no workflow yet.
--
-- Design principle: every agent — stub or active — has a named process
-- owner, a declared risk tier, an enumerated SOX control list, a
-- documented rollback procedure, and declared data sources. Stubs exist
-- in the registry to prove the governance framework is not post-hoc
-- rationalization: the controls exist before the code does.
--
-- Prerequisites:
--   1. Migrations 0001–0006 have run successfully.
--   2. Seed 0002_process_owners_seed.sql has run (Sarah, Marcus, Aisha
--      exist in public.process_owners).
--
-- Seeded agents:
--   1. fao_reserve_recon_v1      — Flagship. RED tier. ACTIVE.
--                                  Owner: Sarah Chen (Controller).
--   2. fao_close_orchestrator_v1 — Stub. AMBER tier. STUB_DOCUMENTED.
--                                  Owner: Sarah Chen (Controller).
--   3. fao_variance_analyzer_v1  — Stub. AMBER tier. STUB_DOCUMENTED.
--                                  Owner: Aisha Okonkwo (FP&A Lead).
--   4. fao_treasury_monitor_v1   — Stub. RED tier. STUB_DOCUMENTED.
--                                  Owner: Marcus Patel (CFO).
--
-- Design notes:
--   - process_owner_id is resolved by email lookup, consistent with
--     seed 0002. No hardcoded UUIDs.
--   - ai_advisory_enabled is FALSE for all agents (FAO-GOV-014: AI
--     disabled by default). The FAO_AI_ASSIST_ENABLED runtime switch is
--     planned for v1.1; nothing reads it, and no workflow reads this
--     column at runtime in v1.
--   - approval_threshold follows risk tier: GREEN/AMBER = 1 approver,
--     RED = 2 approvers.
--   - Not idempotent. Re-running will fail on PRIMARY KEY (agent_id).
--     TRUNCATE agent_registry first if re-seeding.
--   - WARNING: agent_registry is referenced by shadow_ledger and
--     hitl_queue, so a bare TRUNCATE fails and only TRUNCATE ... CASCADE
--     succeeds. CASCADE also empties shadow_ledger and hitl_queue, which
--     erases audit evidence. Re-seed only a fresh database; never re-seed
--     one that holds evidence.
--   - The flagship rollback_procedure text below describes a correcting
--     row with status CORRECTED_BY. That correction procedure is planned
--     for v1.1 and is not supported today: the execution_status enum
--     (migration 0001) allows only SUCCESS, FAILURE, PARTIAL and
--     ROLLED_BACK, so such a row cannot be written.
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-24
-- ============================================================================

-- --- 1. Flagship: Reserve Reconciliation Agent -----------------------------

INSERT INTO public.agent_registry (
  agent_id,
  display_name,
  risk_tier,
  status,
  workflow_id,
  approval_threshold,
  sox_control_ids,
  ai_advisory_enabled,
  rollback_procedure,
  data_sources,
  production_targets,
  sla_max_execution_seconds,
  sla_max_hitl_resolution_hrs,
  process_owner_id
)
SELECT
  'fao_reserve_recon_v1',
  'Reserve Reconciliation Agent',
  'RED',
  'ACTIVE',
  'fao_reserve_recon_v1',
  2,  -- RED tier: two approvers configured; not enforced in v1 (ADR-0001)
  ARRAY[
    'FAO-GOV-001',  -- Shadow Ledger append-only
    'FAO-GOV-002',  -- Agent Registry membership
    'FAO-GOV-003',  -- Risk-tier classification
    'FAO-GOV-004',  -- Segregation of Duties
    'FAO-GOV-013',  -- Named Process Owner
    'FAO-GOV-014',  -- AI disabled by default
    'FAO-REC-001',  -- Per-asset deterministic compare
    'FAO-REC-002',  -- Materiality thresholds (ratio + band)
    'FAO-REC-006',  -- Policy engine (deterministic)
    'FAO-REC-007'   -- Negative balance detection
  ]::TEXT[],
  FALSE,  -- AI advisory off by default; FAO_AI_ASSIST_ENABLED switch planned for v1.1, not read in v1
  -- rollback_procedure: the CORRECTED_BY correction described in this text is
  -- planned for v1.1 and not supported by the current execution_status enum.
  'On failed commit: rollback is a no-op because the flagship writes only to the append-only Shadow Ledger — there is no destructive target system to reverse. If a ledger write is discovered to be erroneous, the correcting entry is a new row with status CORRECTED_BY and a reference to the original ledger_id. The original row is never deleted or updated (FAO-GOV-001).',
  '{
    "wallet_balances": "fixtures/wallet_data.json (mock Fireblocks REST snapshot)",
    "ledger_balances": "fixtures/ledger_data.json (mock NetSuite GL saved search)",
    "materiality": "public.materiality_thresholds (seeded Apr 20)"
  }'::JSONB,
  '{
    "primary":   "public.shadow_ledger (append-only evidence)",
    "secondary": "public.hitl_queue (when policy_outcome = REQUIRE_HUMAN)",
    "notification": "Slack #fao-approvals (notification only, not authoritative)"
  }'::JSONB,
  300,   -- 5 min max execution
  24,    -- 24 hr max HITL resolution for RED-tier items
  (SELECT id FROM public.process_owners WHERE email = 'sarah.chen@finagent-os.demo');

-- --- 2. Stub: Close Orchestrator -------------------------------------------

INSERT INTO public.agent_registry (
  agent_id,
  display_name,
  risk_tier,
  status,
  workflow_id,
  approval_threshold,
  sox_control_ids,
  ai_advisory_enabled,
  rollback_procedure,
  data_sources,
  production_targets,
  sla_max_execution_seconds,
  sla_max_hitl_resolution_hrs,
  process_owner_id
)
SELECT
  'fao_close_orchestrator_v1',
  'Close Orchestrator',
  'AMBER',
  'STUB_DOCUMENTED',
  NULL,  -- no n8n workflow yet
  1,     -- AMBER tier: single approver
  ARRAY[
    'FAO-GOV-001',
    'FAO-GOV-002',
    'FAO-GOV-003',
    'FAO-GOV-004',
    'FAO-GOV-013',
    'FAO-GOV-014'
  ]::TEXT[],
  FALSE,
  'Stub agent. No runtime rollback defined. When implementation begins, rollback will be: on failed close-step commit, emit a compensating journal entry and flag the close task for manual completion. Full procedure to be documented in ADR prior to ACTIVE status.',
  '{"note": "To be declared when stub is promoted to ACTIVE"}'::JSONB,
  '{"note": "To be declared when stub is promoted to ACTIVE"}'::JSONB,
  NULL,
  NULL,
  (SELECT id FROM public.process_owners WHERE email = 'sarah.chen@finagent-os.demo');

-- --- 3. Stub: Variance Analyzer --------------------------------------------

INSERT INTO public.agent_registry (
  agent_id,
  display_name,
  risk_tier,
  status,
  workflow_id,
  approval_threshold,
  sox_control_ids,
  ai_advisory_enabled,
  rollback_procedure,
  data_sources,
  production_targets,
  sla_max_execution_seconds,
  sla_max_hitl_resolution_hrs,
  process_owner_id
)
SELECT
  'fao_variance_analyzer_v1',
  'Variance Analyzer',
  'AMBER',
  'STUB_DOCUMENTED',
  NULL,
  1,
  ARRAY[
    'FAO-GOV-001',
    'FAO-GOV-002',
    'FAO-GOV-003',
    'FAO-GOV-004',
    'FAO-GOV-013',
    'FAO-GOV-014'
  ]::TEXT[],
  FALSE,
  'Stub agent. Advisory-only by design — Variance Analyzer will never write to production ledgers; it only surfaces variance explanations for human review. Rollback is therefore structurally unnecessary. Full procedure to be documented in ADR prior to ACTIVE status.',
  '{"note": "To be declared when stub is promoted to ACTIVE"}'::JSONB,
  '{"note": "To be declared when stub is promoted to ACTIVE"}'::JSONB,
  NULL,
  NULL,
  (SELECT id FROM public.process_owners WHERE email = 'aisha.okonkwo@finagent-os.demo');

-- --- 4. Stub: Treasury Monitor ---------------------------------------------

INSERT INTO public.agent_registry (
  agent_id,
  display_name,
  risk_tier,
  status,
  workflow_id,
  approval_threshold,
  sox_control_ids,
  ai_advisory_enabled,
  rollback_procedure,
  data_sources,
  production_targets,
  sla_max_execution_seconds,
  sla_max_hitl_resolution_hrs,
  process_owner_id
)
SELECT
  'fao_treasury_monitor_v1',
  'Treasury Monitor',
  'RED',
  'STUB_DOCUMENTED',
  NULL,
  2,  -- RED tier: two approvers
  ARRAY[
    'FAO-GOV-001',
    'FAO-GOV-002',
    'FAO-GOV-003',
    'FAO-GOV-004',
    'FAO-GOV-013',
    'FAO-GOV-014'
  ]::TEXT[],
  FALSE,
  'Stub agent. Monitor-only by design — surfaces treasury exposure and concentration metrics; does not execute treasury actions. Any proposed rebalance is a HITL ticket, not an automated action. Full procedure to be documented in ADR prior to ACTIVE status.',
  '{"note": "To be declared when stub is promoted to ACTIVE"}'::JSONB,
  '{"note": "To be declared when stub is promoted to ACTIVE"}'::JSONB,
  NULL,
  NULL,
  (SELECT id FROM public.process_owners WHERE email = 'marcus.patel@finagent-os.demo');

-- --- Verification -----------------------------------------------------------
-- Run after seeding to confirm four rows with correct tier/status/owner mix:
--
--   SELECT agent_id, risk_tier, status, approval_threshold,
--          (SELECT name FROM public.process_owners po
--             WHERE po.id = ar.process_owner_id) AS owner
--   FROM public.agent_registry ar
--   ORDER BY agent_id;
--
-- Expected result:
--   fao_close_orchestrator_v1  | AMBER | STUB_DOCUMENTED | 1 | Sarah Chen
--   fao_reserve_recon_v1       | RED   | ACTIVE          | 2 | Sarah Chen
--   fao_treasury_monitor_v1    | RED   | STUB_DOCUMENTED | 2 | Marcus Patel
--   fao_variance_analyzer_v1   | AMBER | STUB_DOCUMENTED | 1 | Aisha Okonkwo
