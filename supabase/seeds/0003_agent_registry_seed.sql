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
--     Re-seed only a fresh database; never re-seed one that holds
--     evidence. TRUNCATE is refused on agent_registry and on every table
--     that references it (FAO-GOV-001, phase 2-5 migration 0013).
--   - Phase 2-5: the first statement sets fao.change_reason, which every
--     change to agent_registry now needs (FAO-GOV-002).
--   - sox_control_ids lists every control SOX-MAPPING.md says the agent
--     exercises (fix round 5, F-28): the flagship adds FAO-GOV-008,
--     FAO-GOV-009, FAO-GOV-015, FAO-REC-003, FAO-REC-004 and FAO-REC-008.
--     The stubs have no workflow, so they list only the inherited platform
--     controls. Planned controls (FAO-GOV-005, 010 to 012, FAO-REC-005,
--     009) are not listed. supabase/tests/146_round5_hitl.test.sql asserts
--     the set per agent.
--   - The flagship rollback_procedure text below describes the correction
--     procedure: an erroneous ledger row is corrected by a CORRECTION event
--     that references the original ledger_id (fao_ledger_correct, phase
--     2-5). The original row is never changed.
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-24
-- ============================================================================

-- FAO-GOV-002: change reason for this session (required by the
-- agent_registry triggers).
SELECT set_config('fao.change_reason', 'seed 0003', false);

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
    'FAO-GOV-008',  -- Correlation ID threading
    'FAO-GOV-009',  -- Policy outcome vocabulary
    'FAO-GOV-013',  -- Named Process Owner
    'FAO-GOV-014',  -- AI disabled by default
    'FAO-GOV-015',  -- MCP tool surface (invoke_reserve_recon and the read tools)
    'FAO-REC-001',  -- Per-asset deterministic compare
    'FAO-REC-002',  -- Materiality thresholds (ratio + band)
    'FAO-REC-003',  -- Reserve ratio computation (per asset)
    'FAO-REC-004',  -- Reserve ratio floor check (per asset)
    'FAO-REC-006',  -- Policy engine (deterministic)
    'FAO-REC-007',  -- Negative balance detection
    'FAO-REC-008'   -- Audit evidence records by correlation_id
  ]::TEXT[],
  FALSE,  -- AI advisory off by default; FAO_AI_ASSIST_ENABLED switch planned for v1.1, not read in v1
  -- rollback_procedure: corrections are CORRECTION events written by
  -- fao_ledger_correct (phase 2-5); the live text is reworded to match in
  -- cutover runbook step 8.
  'On failed commit: rollback is a no-op because the flagship writes only to the append-only Shadow Ledger; there is no destructive target system to reverse. If a ledger write is discovered to be erroneous, the correcting entry is a CORRECTION event that references the original ledger_id. The original row is never deleted or updated (FAO-GOV-001).',
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
