-- ============================================================================
-- FinAgent OS pgTAP 140: fix round 1, run and ledger RPCs
-- Controls:
--   FAO-GOV-002, FAO-GOV-003 (A1): RUN_REFUSED ledger rows are bounded per
--     invoker and agent by max_runs_per_hour; past it the call is
--     RATE_LIMITED and no ledger row is written.
--   FAO-GOV-001, FAO-GOV-004 (A2): Writer events cannot carry evidence keys
--     the database alone writes; a Writer FAILED gets source, stage and the
--     n8n execution id from the database.
--   FAO-GOV-001 (A3): the sweep's GRANTS_DRIFT and TEST_CLOCK_SET rows are
--     journaled even when the fao_workflow bucket is past the flood cap, and
--     do not count toward it; every other refusal stays capped.
-- ============================================================================
BEGIN;
SELECT plan(49);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.n(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j::text)::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.append_err(p_events jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)', p_events)) $$;
-- RUN_REFUSED rows naming the invoker for the agent in the last hour
CREATE FUNCTION pg_temp.refused(p_email text, p_agent text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.shadow_ledger l
   WHERE l.agent_id = p_agent AND l.inputs->>'event_type' = 'RUN_REFUSED'
     AND l.inputs->>'invoker_id' = tests.uid(p_email)::text
     AND l.event_timestamp > fao_private.clock() - interval '1 hour' $$;
CREATE FUNCTION pg_temp.refused_all(p_agent text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.shadow_ledger l
   WHERE l.agent_id = p_agent AND l.inputs->>'event_type' = 'RUN_REFUSED' $$;
CREATE FUNCTION pg_temp.wf_bucket() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.fao_refusal_journal j
   WHERE j.actor_uid IS NULL AND j.db_role = 'fao_workflow'
     AND j.code NOT IN ('JOURNAL_SUPPRESSED', 'GRANTS_DRIFT', 'TEST_CLOCK_SET')
     AND j.at > clock_timestamp() - interval '1 minute' $$;
CREATE FUNCTION pg_temp.bad_token() RETURNS text LANGUAGE sql VOLATILE AS $$
  SELECT left(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 43) $$;

-- ============================================================================
-- A1: RUN_REFUSED rows are bounded per invoker and agent
-- ============================================================================
-- The limit is set 2 above the most refusals either invoker already has in
-- the last hour (committed rows from other layers), so the counts below do
-- not depend on earlier activity.
INSERT INTO v VALUES ('a_base', to_jsonb(pg_temp.refused('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1')));
INSERT INTO v VALUES ('s_base', to_jsonb(pg_temp.refused('sarah.chen@finagent-os.demo', 'fao_close_orchestrator_v1')));
INSERT INTO v VALUES ('lim', to_jsonb(2 + greatest(pg_temp.n('a_base'), pg_temp.n('s_base'))));
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 140 refusal bound', true);
  UPDATE public.agent_registry SET max_runs_per_hour = pg_temp.n('lim') WHERE agent_id = 'fao_close_orchestrator_v1';
  UPDATE public.agent_registry SET status = 'DEPRECATED' WHERE agent_id = 'fao_treasury_monitor_v1';
END $$;
INSERT INTO v VALUES ('all_before', to_jsonb(pg_temp.refused_all('fao_close_orchestrator_v1')));

CREATE TEMP TABLE a1 (n int, r jsonb);
INSERT INTO a1 SELECT n, tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1', 'pgtap 140', tests.new_key())
  FROM generate_series(1, (pg_temp.n('lim') - pg_temp.n('a_base'))::int) n;
SELECT is((SELECT count(*) FROM a1 WHERE r->>'code' = 'AGENT_NOT_ACTIVE' AND (r->>'http_status')::int = 409),
  pg_temp.n('lim') - pg_temp.n('a_base'), 'A1: refusals up to max_runs_per_hour are AGENT_NOT_ACTIVE (409)');
SELECT is(pg_temp.refused('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1'), pg_temp.n('lim'),
  'A1: each of them commits one RUN_REFUSED row, reaching the limit');

-- Over the limit: RATE_LIMITED, journaled, and no ledger row
INSERT INTO v VALUES ('over1', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1', 'pgtap 140', tests.new_key()));
SELECT is(pg_temp.g('over1')->>'code', 'RATE_LIMITED', 'A1: the next refusal is RATE_LIMITED');
SELECT is((pg_temp.g('over1')->>'http_status')::int, 429, 'A1: RATE_LIMITED is 429');
SELECT is(pg_temp.g('over1')->>'message', 'Too many runs in the last hour.', 'A1: RATE_LIMITED carries its fixed message');
SELECT is(pg_temp.refused('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1'), pg_temp.n('lim'),
  'A1: no RUN_REFUSED row is written over the limit');
SELECT is((tests.journal_row((pg_temp.g('over1')->>'ref')::bigint))->>'code', 'RATE_LIMITED', 'A1: the RATE_LIMITED refusal is journaled');
SELECT is((tests.journal_row((pg_temp.g('over1')->>'ref')::bigint))->>'entry_point', 'rpc:fao_run_start', 'A1: journaled against fao_run_start');

-- Ten more fresh keys: all RATE_LIMITED, the ledger does not grow
CREATE TEMP TABLE a1_flood (n int, r jsonb);
INSERT INTO a1_flood SELECT n, tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1', 'pgtap 140', tests.new_key())
  FROM generate_series(1, 10) n;
SELECT is((SELECT count(*) FROM a1_flood WHERE r->>'code' = 'RATE_LIMITED'), 10::bigint, 'A1: ten fresh idempotency keys are all RATE_LIMITED');
SELECT is(pg_temp.refused_all('fao_close_orchestrator_v1') - pg_temp.n('all_before'), pg_temp.n('lim') - pg_temp.n('a_base'),
  'A1: the flood adds no ledger row for the agent');
SELECT is((SELECT count(*) FROM public.run_invocations WHERE agent_id = 'fao_close_orchestrator_v1'
            AND invoker_id = tests.uid('aisha.okonkwo@finagent-os.demo') AND requested_at = now()), 0::bigint,
  'A1: no run record is created for a refused agent');

-- The bound is per invoker and per agent
INSERT INTO v VALUES ('sarah', tests.start_raw('sarah.chen@finagent-os.demo', 'fao_close_orchestrator_v1', 'pgtap 140', tests.new_key()));
SELECT is(pg_temp.g('sarah')->>'code', 'AGENT_NOT_ACTIVE', 'A1: another invoker on the same agent is not limited by Aisha''s refusals');
SELECT is(pg_temp.refused('sarah.chen@finagent-os.demo', 'fao_close_orchestrator_v1'), pg_temp.n('s_base') + 1,
  'A1: and gets her own RUN_REFUSED row');
INSERT INTO v VALUES ('dep', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_treasury_monitor_v1', 'pgtap 140', tests.new_key()));
SELECT is(pg_temp.g('dep')->>'code', 'AGENT_NOT_ACTIVE', 'A1: the same invoker on another non-active agent is counted separately');

-- An ACTIVE agent is unaffected
INSERT INTO v VALUES ('active', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'pgtap 140', tests.new_key()));
SELECT ok((pg_temp.g('active')->>'ok')::boolean, 'A1: an ACTIVE agent still starts for the same invoker');

-- Earlier checks still come first: a bad input is INVALID_INPUT, not RATE_LIMITED
INSERT INTO v VALUES ('bad', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1', 'pgtap 140', 'short'));
SELECT is(pg_temp.g('bad')->>'code', 'INVALID_INPUT', 'A1: input checks still run before the bound');

-- The window is one hour on the FinAgent clock
SELECT tests.set_clock(3601);
INSERT INTO v VALUES ('later', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1', 'pgtap 140', tests.new_key()));
SELECT is(pg_temp.g('later')->>'code', 'AGENT_NOT_ACTIVE', 'A1: an hour later the refusal is recorded again');
SELECT is(pg_temp.refused_all('fao_close_orchestrator_v1') - pg_temp.n('all_before'), pg_temp.n('lim') - pg_temp.n('a_base') + 2,
  'A1: with one new RUN_REFUSED row (plus Sarah''s)');
SELECT tests.set_clock(0);

-- ============================================================================
-- A2: Writer evidence fields
-- ============================================================================
INSERT INTO v VALUES ('run', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC', 'ETH'])));

-- Every reserved key is refused on ASSET_RECONCILED, nothing stored
CREATE TEMP TABLE a2_ar (k text, e text);
INSERT INTO a2_ar SELECT k, pg_temp.append_err(jsonb_build_array(
    jsonb_set(tests.asset_event(pg_temp.c('run'), 'BTC', 'ALLOW'), ARRAY['inputs', k], to_jsonb('forged'::text))))
  FROM unnest(ARRAY['invoker_id', 'invoked_via', 'reason', 'approver_id', 'approvers',
                    'agent_invoker_id', 'hitl_id', 'decision', 'decided_at']) k;
SELECT is((SELECT count(*) FROM a2_ar WHERE e = '22023 FAO-GOV-001 ledger_append: item 0: inputs.' || k || ' is set only by the database'), 9::bigint,
  'A2: ASSET_RECONCILED refuses each of the 9 database-only inputs keys with a named error');
SELECT is(tests.ledger_count(pg_temp.c('run'), 'ASSET_RECONCILED'), 0::bigint, 'A2: no ASSET_RECONCILED row is stored');

-- A JSON null or a non-string value is still refused (presence, not value)
SELECT matches(pg_temp.append_err(jsonb_build_array(
    jsonb_set(tests.asset_event(pg_temp.c('run'), 'BTC', 'ALLOW'), '{inputs,approver_id}', 'null'::jsonb))),
  'inputs\.approver_id is set only by the database', 'A2: a null approver_id key is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(
    jsonb_set(tests.asset_event(pg_temp.c('run'), 'BTC', 'ALLOW'), '{inputs,hitl_id}', '42'::jsonb))),
  'inputs\.hitl_id is set only by the database', 'A2: a numeric hitl_id is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(
    jsonb_set(tests.asset_event(pg_temp.c('run'), 'BTC', 'ALLOW'), '{inputs,approvers}', to_jsonb(ARRAY[tests.uid('sarah.chen@finagent-os.demo')])))),
  'inputs\.approvers is set only by the database', 'A2: an approvers list is refused');

-- All or none: a good item followed by a bad one stores nothing
SELECT matches(pg_temp.append_err(jsonb_build_array(
    tests.asset_event(pg_temp.c('run'), 'BTC', 'ALLOW'),
    jsonb_set(tests.asset_event(pg_temp.c('run'), 'ETH', 'ALLOW'), '{inputs,decision}', '"APPROVED"'))),
  '^22023 FAO-GOV-001 ledger_append: item 1: inputs\.decision is set only by the database$', 'A2: the bad item is named by its index');
SELECT is(tests.ledger_count(pg_temp.c('run'), 'ASSET_RECONCILED'), 0::bigint, 'A2: the good item in that batch is not stored');

-- A top-level reserved key is an unknown field (existing refusal)
SELECT matches(pg_temp.append_err(jsonb_build_array(
    tests.asset_event(pg_temp.c('run'), 'BTC', 'ALLOW') || jsonb_build_object('approver_id', tests.uid('sarah.chen@finagent-os.demo')))),
  'item 0: unknown field approver_id', 'A2: a top-level approver_id is refused as an unknown field');

-- A clean ASSET_RECONCILED still appends
INSERT INTO v VALUES ('ok_ar', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('run'), 'BTC', 'ALLOW'))));
SELECT is((pg_temp.g('ok_ar')->>'count')::int, 1, 'A2: a clean ASSET_RECONCILED still appends');

-- STARTED: the six request and approval keys are refused
INSERT INTO v VALUES ('st', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('st_claim', tests.claim(pg_temp.g('st')->>'run_token'));
CREATE TEMP TABLE a2_st (k text, e text);
INSERT INTO a2_st SELECT k, pg_temp.append_err(jsonb_build_array(
    jsonb_set(tests.started_event((pg_temp.g('st')->>'correlation_id')::uuid, ARRAY['BTC']), ARRAY['inputs', k], to_jsonb('forged'::text))))
  FROM unnest(ARRAY['approver_id', 'approvers', 'agent_invoker_id', 'hitl_id', 'decision', 'decided_at']) k;
SELECT is((SELECT count(*) FROM a2_st WHERE e = '22023 FAO-GOV-001 ledger_append: item 0: inputs.' || k || ' is set only by the database'), 6::bigint,
  'A2: STARTED refuses the 6 request and approval keys');
SELECT is(tests.ledger_count((pg_temp.g('st')->>'correlation_id')::uuid, 'STARTED'), 0::bigint, 'A2: no STARTED row is stored');
-- STARTED may carry invoker_id, invoked_via and reason; the database overwrites them
INSERT INTO v VALUES ('st_ok', tests.append(jsonb_build_array(jsonb_set(jsonb_set(
    tests.started_event((pg_temp.g('st')->>'correlation_id')::uuid, ARRAY['BTC']),
    '{inputs,reason}', '"forged reason"'), '{inputs,invoker_id}', to_jsonb(tests.uid('sarah.chen@finagent-os.demo'))))));
SELECT is((SELECT inputs->>'reason' || '/' || (inputs->>'invoker_id') FROM public.shadow_ledger
            WHERE correlation_id = (pg_temp.g('st')->>'correlation_id')::uuid AND inputs->>'event_type' = 'STARTED'),
  'pgtap run/' || tests.uid('aisha.okonkwo@finagent-os.demo')::text, 'A2: STARTED reason and invoker_id come from the run');

-- FAILED: every reserved key is refused
CREATE FUNCTION pg_temp.failed_event(p_corr uuid, p_inputs jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'correlation_id', p_corr, 'event_type', 'FAILED', 'inputs', p_inputs,
    'policy_outcome', 'BLOCKED', 'policy_rationale', 'pgtap writer failure',
    'status', 'FAILURE', 'error_details', 'pgtap boom') $$;
INSERT INTO v VALUES ('fx', to_jsonb('pgtap-140-' || left(md5(random()::text), 20)));
INSERT INTO v VALUES ('f_start', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('f_claim', tests.claim(pg_temp.g('f_start')->>'run_token', pg_temp.g('fx')#>>'{}'));
INSERT INTO v VALUES ('f_corr', pg_temp.g('f_start')->'correlation_id');
INSERT INTO v VALUES ('f_started', tests.append(jsonb_build_array(tests.started_event(pg_temp.c('f_corr'), ARRAY['BTC']))));
CREATE TEMP TABLE a2_f (k text, e text);
INSERT INTO a2_f SELECT k, pg_temp.append_err(jsonb_build_array(
    pg_temp.failed_event(pg_temp.c('f_corr'), jsonb_build_object('failed_node', 'Per-Asset Reconcile', k, 'forged'))))
  FROM unnest(ARRAY['invoker_id', 'invoked_via', 'reason', 'approver_id', 'approvers',
                    'agent_invoker_id', 'hitl_id', 'decision', 'decided_at']) k;
SELECT is((SELECT count(*) FROM a2_f WHERE e = '22023 FAO-GOV-001 ledger_append: item 0: inputs.' || k || ' is set only by the database'), 9::bigint,
  'A2: FAILED refuses each of the 9 database-only inputs keys');
SELECT is(tests.run_state(pg_temp.c('f_corr')), 'RUNNING', 'A2: a refused FAILED leaves the run RUNNING');

-- FAILED: forged source, stage and execution id are replaced by the database
INSERT INTO v VALUES ('f_ok', tests.append(jsonb_build_array(pg_temp.failed_event(pg_temp.c('f_corr'),
  jsonb_build_object('failed_node', 'Per-Asset Reconcile', 'source', 'sweep', 'stage', 'after_request', 'n8n_execution_id', 'forged-exec')))));
SELECT is((pg_temp.g('f_ok')->>'count')::int, 1, 'A2: a FAILED with forged source, stage and execution id is accepted');
SELECT is((SELECT inputs->>'source' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('f_corr') AND inputs->>'event_type' = 'FAILED'),
  'writer', 'A2: Writer FAILED source is writer, not the supplied sweep');
SELECT is((SELECT inputs->>'stage' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('f_corr') AND inputs->>'event_type' = 'FAILED'),
  'before_request', 'A2: Writer FAILED stage is before_request, not the supplied after_request');
SELECT is((SELECT inputs->>'n8n_execution_id' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('f_corr') AND inputs->>'event_type' = 'FAILED'),
  pg_temp.g('fx')#>>'{}', 'A2: Writer FAILED execution id is the one that claimed the run');
SELECT is((SELECT inputs->>'failed_node' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('f_corr') AND inputs->>'event_type' = 'FAILED'),
  'Per-Asset Reconcile', 'A2: the Writer failed_node is kept');
SELECT is(tests.run_state(pg_temp.c('f_corr')), 'FAILED', 'A2: the run is FAILED');

-- FAILED with no source or stage at all gets them from the database
INSERT INTO v VALUES ('g_start', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('g_claim', tests.claim(pg_temp.g('g_start')->>'run_token'));
INSERT INTO v VALUES ('g_append', tests.append(jsonb_build_array(
  tests.started_event((pg_temp.g('g_start')->>'correlation_id')::uuid, ARRAY['ETH']),
  pg_temp.failed_event((pg_temp.g('g_start')->>'correlation_id')::uuid, jsonb_build_object('failed_node', 'Init Execution', 'source', 'error_workflow')))));
SELECT is((SELECT (inputs->>'source') || '/' || (inputs->>'stage') || '/' || (inputs->>'n8n_execution_id') FROM public.shadow_ledger
            WHERE correlation_id = (pg_temp.g('g_start')->>'correlation_id')::uuid AND inputs->>'event_type' = 'FAILED'),
  'writer/before_request/' || (SELECT n8n_execution_id FROM public.run_invocations WHERE correlation_id = (pg_temp.g('g_start')->>'correlation_id')::uuid),
  'A2: a FAILED claiming error_workflow is recorded as writer, before_request, with the run execution id');

-- ============================================================================
-- A3: sweep rows are not suppressed by the fao_workflow flood cap
-- ============================================================================
-- The cap is set 2 above what the (no session, fao_workflow) bucket already
-- holds in the last minute.
INSERT INTO v VALUES ('wf_base', to_jsonb(pg_temp.wf_bucket()));
INSERT INTO v VALUES ('j_start', to_jsonb(coalesce((SELECT max(refusal_id) FROM public.fao_refusal_journal), 0)));
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 140 lower the journal cap', true);
  UPDATE public.fao_settings SET value = (pg_temp.n('wf_base') + 2)::text WHERE key = 'journal_cap_per_minute';
END $$;
INSERT INTO v VALUES ('tc_before', to_jsonb(tests.journal_count('TEST_CLOCK_SET')));
INSERT INTO v VALUES ('gd_before', to_jsonb(tests.journal_count('GRANTS_DRIFT')));

-- One claim refusal is journaled (one slot left)
INSERT INTO v VALUES ('c1', tests.claim_raw(pg_temp.bad_token(), 'pgtap-140-c1'));
SELECT ok(pg_temp.g('c1')->>'code' = 'INVALID_TOKEN' AND pg_temp.g('c1')->>'ref' IS NOT NULL, 'A3: setup: a claim refusal is journaled in the fao_workflow bucket');

-- The sweep journals TEST_CLOCK_SET and GRANTS_DRIFT; neither uses a slot
SELECT tests.set_clock(140001);
GRANT SELECT ON public.materiality_thresholds TO anon;
INSERT INTO v VALUES ('sw1', tests.sweep());
SELECT ok((pg_temp.g('sw1')->>'grants_drift')::boolean, 'A3: setup: the sweep sees the planted grant');
SELECT is(pg_temp.wf_bucket(), pg_temp.n('wf_base') + 1, 'A3: sweep rows do not count toward the cap');

-- The last slot, then the cap
INSERT INTO v VALUES ('c2', tests.claim_raw(pg_temp.bad_token(), 'pgtap-140-c2'));
SELECT ok(pg_temp.g('c2')->>'ref' IS NOT NULL, 'A3: the claim refusal that fills the cap is journaled');
CREATE TEMP TABLE a3_flood (n int, r jsonb);
INSERT INTO a3_flood SELECT n, tests.claim_raw(pg_temp.bad_token(), 'pgtap-140-f' || n) FROM generate_series(1, 20) n;
SELECT is((SELECT count(*) FROM a3_flood WHERE r->>'code' = 'INVALID_TOKEN' AND r->>'ref' IS NULL), 20::bigint,
  'A3: 20 bad tokens past the cap are refused and not journaled');
SELECT ok(EXISTS (SELECT 1 FROM public.fao_refusal_journal WHERE actor_uid IS NULL AND db_role = 'fao_workflow'
                   AND code = 'JOURNAL_SUPPRESSED' AND at > clock_timestamp() - interval '1 minute'),
  'A3: the fao_workflow bucket is suppressed');

-- With the bucket suppressed, a new drift state and a new clock offset are still journaled
SELECT tests.set_clock(140002);
GRANT SELECT ON public.process_owners TO anon;
INSERT INTO v VALUES ('sw2', tests.sweep());
REVOKE SELECT ON public.process_owners FROM anon;
REVOKE SELECT ON public.materiality_thresholds FROM anon;
SELECT is(tests.journal_count('TEST_CLOCK_SET') - pg_temp.n('tc_before'), 2::bigint,
  'A3: TEST_CLOCK_SET is journaled for each offset, including while the bucket is suppressed');
SELECT is(tests.journal_count('GRANTS_DRIFT') - pg_temp.n('gd_before'), 2::bigint,
  'A3: GRANTS_DRIFT is journaled for each drift state, including while the bucket is suppressed');
SELECT is((SELECT count(*) FROM public.fao_refusal_journal WHERE code IN ('GRANTS_DRIFT', 'TEST_CLOCK_SET')
            AND entry_point = 'sweep' AND actor_uid IS NULL AND db_role = 'fao_workflow' AND refusal_id > pg_temp.n('j_start')), 4::bigint,
  'A3: the four sweep rows sit in the (no session, fao_workflow) bucket');

-- The cap still holds for every other code after the sweep rows
INSERT INTO v VALUES ('c3', tests.claim_raw(pg_temp.bad_token(), 'pgtap-140-c3'));
SELECT ok(pg_temp.g('c3')->>'code' = 'INVALID_TOKEN' AND pg_temp.g('c3')->>'ref' IS NULL, 'A3: claim refusals stay capped after the sweep rows');

SELECT * FROM finish();
ROLLBACK;
