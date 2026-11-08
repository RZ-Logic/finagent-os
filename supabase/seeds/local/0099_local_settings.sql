-- ============================================================================
-- FinAgent OS: Seed local/0099: local-only settings, test agent and test user
-- ============================================================================
-- LOCAL ONLY. Never run against a hosted project. scripts/local-setup.mjs
-- runs it after seeds 0002 to 0008. The first statement after the change
-- reason checks for the local-only Auth user ratelimit@local.test and raises
-- when it is missing, so the file changes nothing on a project without it.
--
-- Control IDs exercised by the local tests:
--   FAO-GOV-002  rate limit per agent (a test agent with max_runs_per_hour 2;
--                the flagship raised to 60 so repeated test runs fit)
--   FAO-GOV-007  notifications point at a local Slack stub
--   FAO-GOV-001  journal flood cap raised to 1000 for the test suite
--
-- Changes:
--   approval_app_base_url   http://localhost:4173 (local approval page)
--   slack_api_base_url      http://127.0.0.1:8099/api (local stub)
--   journal_cap_per_minute  1000
--   fao_reserve_recon_v1    max_runs_per_hour 60
--   fao_ratelimit_test_v1   new agent: ACTIVE, GREEN, max_runs_per_hour 2,
--                           SLA 900 s and 24 h, owner Sarah Chen
--   ratelimit@local.test    process_owners row and an invoker grant on
--                           fao_ratelimit_test_v1 only
--
-- Contains no password. Users are created by scripts/local-setup.mjs through
-- the local Auth admin API.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- FAO-GOV-002: change reason for this session.
SELECT set_config('fao.change_reason', 'seed local/0099', false);

-- --- Guard: local stack only ------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = 'ratelimit@local.test') THEN
    RAISE EXCEPTION 'FAO-GOV-002 seed local/0099: local-only seed; Auth user ratelimit@local.test not found, nothing changed'
      USING ERRCODE = '22023';
  END IF;
END
$$;

-- --- Settings overrides -----------------------------------------------------
UPDATE public.fao_settings SET value = 'http://localhost:4173'     WHERE key = 'approval_app_base_url';
UPDATE public.fao_settings SET value = 'http://127.0.0.1:8099/api' WHERE key = 'slack_api_base_url';
UPDATE public.fao_settings SET value = '1000'                      WHERE key = 'journal_cap_per_minute';

-- --- Flagship rate limit ----------------------------------------------------
UPDATE public.agent_registry SET max_runs_per_hour = 60 WHERE agent_id = 'fao_reserve_recon_v1';

-- --- Local-only rate-limit test agent ---------------------------------------
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
  process_owner_id,
  max_runs_per_hour
)
SELECT
  'fao_ratelimit_test_v1',
  'Rate Limit Test Agent (local only)',
  'GREEN',
  'ACTIVE',
  NULL,
  1,
  ARRAY['FAO-GOV-001','FAO-GOV-002','FAO-GOV-003','FAO-GOV-004','FAO-GOV-013']::text[],
  FALSE,
  'Local test agent. Writes nothing outside the Shadow Ledger; an erroneous ledger row is corrected by a CORRECTION event that references the original ledger_id.',
  '{"note": "local test agent; no data sources"}'::jsonb,
  '{"note": "local test agent; no production targets"}'::jsonb,
  900,  -- at least 900 (patch round 6, P4; migration 0013 refuses lower)
  24,
  po.id,
  2
  FROM public.process_owners po
 WHERE po.email = 'sarah.chen@finagent-os.demo';

-- --- Local-only rate-limit test user ----------------------------------------
INSERT INTO public.process_owners (id, name, role, email, escalation_to)
SELECT u.id, 'Rate Limit Tester', 'Test Invoker', 'ratelimit@local.test', NULL
  FROM auth.users u
 WHERE lower(u.email) = 'ratelimit@local.test';

INSERT INTO public.fao_user_roles (user_id, role, agent_id, granted_by, reason)
SELECT u.id, 'invoker'::public.fao_app_role, 'fao_ratelimit_test_v1', NULL, 'seed local/0099'
  FROM auth.users u
 WHERE lower(u.email) = 'ratelimit@local.test';

-- --- Check ------------------------------------------------------------------
DO $$
DECLARE
  v_agents int;
  v_owner  int;
  v_grants int;
  v_values int;
BEGIN
  SELECT count(*) INTO v_agents FROM public.agent_registry
   WHERE agent_id = 'fao_ratelimit_test_v1' AND status = 'ACTIVE' AND max_runs_per_hour = 2;
  SELECT count(*) INTO v_owner FROM public.process_owners WHERE email = 'ratelimit@local.test';
  SELECT count(*) INTO v_grants FROM public.fao_user_roles r JOIN auth.users u ON u.id = r.user_id
   WHERE lower(u.email) = 'ratelimit@local.test' AND r.revoked_at IS NULL
     AND r.role = 'invoker' AND r.agent_id = 'fao_ratelimit_test_v1';
  SELECT count(*) INTO v_values FROM public.fao_settings
   WHERE (key = 'approval_app_base_url'  AND value = 'http://localhost:4173')
      OR (key = 'slack_api_base_url'     AND value = 'http://127.0.0.1:8099/api')
      OR (key = 'journal_cap_per_minute' AND value = '1000');
  IF v_agents <> 1 OR v_owner <> 1 OR v_grants <> 1 OR v_values <> 3 THEN
    RAISE EXCEPTION 'FAO-GOV-002 seed local/0099: incomplete (agent %, owner %, grant %, settings %)', v_agents, v_owner, v_grants, v_values
      USING ERRCODE = '22023';
  END IF;
END
$$;
