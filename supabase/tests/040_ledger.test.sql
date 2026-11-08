-- ============================================================================
-- FinAgent OS pgTAP 040: shadow ledger append-only and fao_ledger_append_batch
-- Controls: FAO-GOV-001 (append-only for every role, no TRUNCATE, all-or-none
-- batches, DB-set timestamps and context, corrections by reference).
-- ============================================================================
BEGIN;
SELECT plan(110);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
INSERT INTO v VALUES ('run7', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['ADA','BTC','ETH','SOL','USDC','USDT','XRP'])));
INSERT INTO v VALUES ('run8', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['A1','A2','A3','A4','A5','A6','A7','A8'])));
INSERT INTO v VALUES ('runx', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC','ETH'])));
INSERT INTO v VALUES ('done', to_jsonb(tests.make_run('sarah.chen@finagent-os.demo', ARRAY['ETH'])));
INSERT INTO v VALUES ('done_append', tests.append(jsonb_build_array(tests.asset_event((SELECT (j#>>'{}')::uuid FROM v WHERE k = 'done'), 'ETH', 'ALLOW'))));
INSERT INTO v VALUES ('done_final', tests.finalize((SELECT (j#>>'{}')::uuid FROM v WHERE k = 'done')));
INSERT INTO v VALUES ('any_ledger_id', to_jsonb((SELECT min(ledger_id) FROM public.shadow_ledger WHERE correlation_id = (SELECT (j#>>'{}')::uuid FROM v WHERE k = 'done'))));

CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.append_err(p_events jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)', p_events)) $$;

-- UPDATE and DELETE refused for every role and the owner
SELECT throws_ok($$UPDATE public.shadow_ledger SET policy_rationale = 'x'$$, '42501', NULL, 'owner: UPDATE on shadow_ledger is refused');
SELECT throws_ok($$DELETE FROM public.shadow_ledger$$, '42501', NULL, 'owner: DELETE on shadow_ledger is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'UPDATE public.shadow_ledger SET policy_rationale = ''x''')$$, '42501', NULL, 'authenticated: UPDATE is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'DELETE FROM public.shadow_ledger')$$, '42501', NULL, 'authenticated: DELETE is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'UPDATE public.shadow_ledger SET policy_rationale = ''x''')$$, '42501', NULL, 'fao_workflow: UPDATE is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'DELETE FROM public.shadow_ledger')$$, '42501', NULL, 'fao_workflow: DELETE is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'UPDATE public.shadow_ledger SET policy_rationale = ''x''')$$, '42501', NULL, 'service_role: UPDATE is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'DELETE FROM public.shadow_ledger')$$, '42501', NULL, 'service_role: DELETE is refused');

-- TRUNCATE with and without CASCADE on every FinAgent table. A plain TRUNCATE
-- of a table that other tables reference is refused by the foreign key check
-- before the trigger runs (0A000); with CASCADE the trigger refuses (42501).
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.shadow_ledger') IN ('42501', '0A000'), 'owner: TRUNCATE public.shadow_ledger is refused');
SELECT throws_ok($$TRUNCATE public.shadow_ledger CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.shadow_ledger CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.hitl_queue') IN ('42501', '0A000'), 'owner: TRUNCATE public.hitl_queue is refused');
SELECT throws_ok($$TRUNCATE public.hitl_queue CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.hitl_queue CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.run_invocations') IN ('42501', '0A000'), 'owner: TRUNCATE public.run_invocations is refused');
SELECT throws_ok($$TRUNCATE public.run_invocations CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.run_invocations CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.process_owners') IN ('42501', '0A000'), 'owner: TRUNCATE public.process_owners is refused');
SELECT throws_ok($$TRUNCATE public.process_owners CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.process_owners CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.agent_registry') IN ('42501', '0A000'), 'owner: TRUNCATE public.agent_registry is refused');
SELECT throws_ok($$TRUNCATE public.agent_registry CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.agent_registry CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.materiality_thresholds') IN ('42501', '0A000'), 'owner: TRUNCATE public.materiality_thresholds is refused');
SELECT throws_ok($$TRUNCATE public.materiality_thresholds CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.materiality_thresholds CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.fao_user_roles') IN ('42501', '0A000'), 'owner: TRUNCATE public.fao_user_roles is refused');
SELECT throws_ok($$TRUNCATE public.fao_user_roles CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.fao_user_roles CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.fao_settings') IN ('42501', '0A000'), 'owner: TRUNCATE public.fao_settings is refused');
SELECT throws_ok($$TRUNCATE public.fao_settings CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.fao_settings CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.fao_refusal_journal') IN ('42501', '0A000'), 'owner: TRUNCATE public.fao_refusal_journal is refused');
SELECT throws_ok($$TRUNCATE public.fao_refusal_journal CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.fao_refusal_journal CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.fao_admin_audit') IN ('42501', '0A000'), 'owner: TRUNCATE public.fao_admin_audit is refused');
SELECT throws_ok($$TRUNCATE public.fao_admin_audit CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.fao_admin_audit CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE public.fao_notifications') IN ('42501', '0A000'), 'owner: TRUNCATE public.fao_notifications is refused');
SELECT throws_ok($$TRUNCATE public.fao_notifications CASCADE$$, '42501', NULL, 'owner: TRUNCATE public.fao_notifications CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE fao_private.run_tokens') IN ('42501', '0A000'), 'owner: TRUNCATE fao_private.run_tokens is refused');
SELECT throws_ok($$TRUNCATE fao_private.run_tokens CASCADE$$, '42501', NULL, 'owner: TRUNCATE fao_private.run_tokens CASCADE is refused');
SELECT ok(tests.sqlstate_as('owner', 'TRUNCATE fao_private.test_clock') IN ('42501', '0A000'), 'owner: TRUNCATE fao_private.test_clock is refused');
SELECT throws_ok($$TRUNCATE fao_private.test_clock CASCADE$$, '42501', NULL, 'owner: TRUNCATE fao_private.test_clock CASCADE is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.shadow_ledger CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.shadow_ledger is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.hitl_queue CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.hitl_queue is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.run_invocations CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.run_invocations is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.process_owners CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.process_owners is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.agent_registry CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.agent_registry is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.materiality_thresholds CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.materiality_thresholds is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.fao_user_roles CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.fao_user_roles is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.fao_settings CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.fao_settings is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.fao_refusal_journal CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.fao_refusal_journal is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.fao_admin_audit CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.fao_admin_audit is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE public.fao_notifications CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE public.fao_notifications is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE fao_private.run_tokens CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE fao_private.run_tokens is refused');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'TRUNCATE fao_private.test_clock CASCADE')$$, '42501', NULL, 'sarah: TRUNCATE fao_private.test_clock is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.shadow_ledger CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.shadow_ledger is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.hitl_queue CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.hitl_queue is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.run_invocations CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.run_invocations is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.process_owners CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.process_owners is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.agent_registry CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.agent_registry is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.materiality_thresholds CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.materiality_thresholds is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.fao_user_roles CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.fao_user_roles is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.fao_settings CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.fao_settings is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.fao_refusal_journal CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.fao_refusal_journal is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.fao_admin_audit CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.fao_admin_audit is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE public.fao_notifications CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE public.fao_notifications is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE fao_private.run_tokens CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE fao_private.run_tokens is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'TRUNCATE fao_private.test_clock CASCADE')$$, '42501', NULL, 'fao_workflow: TRUNCATE fao_private.test_clock is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.shadow_ledger CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.shadow_ledger is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.hitl_queue CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.hitl_queue is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.run_invocations CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.run_invocations is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.process_owners CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.process_owners is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.agent_registry CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.agent_registry is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.materiality_thresholds CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.materiality_thresholds is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.fao_user_roles CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.fao_user_roles is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.fao_settings CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.fao_settings is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.fao_refusal_journal CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.fao_refusal_journal is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.fao_admin_audit CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.fao_admin_audit is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE public.fao_notifications CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE public.fao_notifications is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE fao_private.run_tokens CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE fao_private.run_tokens is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'TRUNCATE fao_private.test_clock CASCADE')$$, '42501', NULL, 'service_role: TRUNCATE fao_private.test_clock is refused');

-- Direct INSERT refused for every client role
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, policy_outcome, policy_rationale, status) VALUES (gen_random_uuid(), gen_random_uuid(), ''fao_reserve_recon_v1'', ''RED'', ''ALLOW'', ''x'', ''SUCCESS'')')$$, '42501', NULL, 'authenticated: direct INSERT is refused');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, policy_outcome, policy_rationale, status) VALUES (gen_random_uuid(), gen_random_uuid(), ''fao_reserve_recon_v1'', ''RED'', ''ALLOW'', ''x'', ''SUCCESS'')')$$, '42501', NULL, 'fao_workflow: direct INSERT is refused');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, policy_outcome, policy_rationale, status) VALUES (gen_random_uuid(), gen_random_uuid(), ''fao_reserve_recon_v1'', ''RED'', ''ALLOW'', ''x'', ''SUCCESS'')')$$, '42501', NULL, 'service_role: direct INSERT is refused');

-- fao_ledger_append_batch refusals (each raises; nothing is stored)
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'BTC') || '{"event_timestamp":"2026-01-01T00:00:00Z"}')),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a supplied event_timestamp');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'BTC') || jsonb_build_object('hitl_approver_id', tests.uid('sarah.chen@finagent-os.demo')))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a supplied hitl_approver_id');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'BTC', 'ALLOW') || '{"hitl_status":"PENDING"}')),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses PENDING on an ALLOW asset');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'BTC', 'REQUIRE_HUMAN', 'STANDARD') || '{"hitl_status":"APPROVED"}')),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a decided hitl_status');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'BTC') || '{"risk_tier":"AMBER"}')),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a mismatched tier');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'BTC') || '{"agent_id":"fao_close_orchestrator_v1"}')),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a mismatched agent');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'DOGE'))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses an asset outside the run scope');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('runx'), 'BTC'), tests.asset_event(pg_temp.c('runx'), 'BTC'))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a duplicate asset in one batch');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.started_event(pg_temp.c('runx'), ARRAY['BTC','ETH']))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a second STARTED');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('runx'), 'BTC', 'ALLOW'), '{inputs,ratio}', 'null'::jsonb))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses ALLOW with a null ratio');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('runx'), 'BTC'), '{event_type}', '"CORRECTION"') #- '{inputs,event_type}')),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a CORRECTION event');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('runx'), 'BTC'), '{event_type}', '"HITL_RESOLVED"'))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a HITL_* event');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('runx'), 'BTC'), '{event_type}', '"COMMITTED"'))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses a COMMITTED event');
SELECT matches(pg_temp.append_err(jsonb_build_array(tests.asset_event(pg_temp.c('done'), 'ETH'))),
  '^[0-9A-Z]{5} FAO-GOV-001 ledger_append', 'refuses any event when the run is not RUNNING');
SELECT is(tests.ledger_count(pg_temp.c('runx'), 'ASSET_RECONCILED'), 0::bigint, 'none of the refused batches stored a row');

-- A batch of 8 with one bad item stores nothing
INSERT INTO v VALUES ('batch8', (
  SELECT jsonb_agg(CASE WHEN a = 'A5' THEN tests.asset_event(pg_temp.c('run8'), a) || '{"ledger_id": 1}' ELSE tests.asset_event(pg_temp.c('run8'), a) END ORDER BY a)
  FROM unnest(ARRAY['A1','A2','A3','A4','A5','A6','A7','A8']) a));
SELECT matches(pg_temp.append_err((SELECT j FROM v WHERE k = 'batch8')), '^[0-9A-Z]{5} FAO-GOV-001 ledger_append: item 4', 'the bad item (0-based index 4) is named');
SELECT is(tests.ledger_count(pg_temp.c('run8'), 'ASSET_RECONCILED'), 0::bigint, 'a batch of 8 with one bad item stores 0 rows');

-- A batch of 7 valid items stores 7 with DB-set timestamps
INSERT INTO v VALUES ('batch7', tests.append((
  SELECT jsonb_agg(tests.asset_event(pg_temp.c('run7'), a, CASE a WHEN 'SOL' THEN 'REQUIRE_HUMAN' ELSE 'ALLOW' END, CASE a WHEN 'SOL' THEN 'CRITICAL' END) ORDER BY a)
  FROM unnest(ARRAY['ADA','BTC','ETH','SOL','USDC','USDT','XRP']) a)));
SELECT is((SELECT (j->>'count')::int FROM v WHERE k = 'batch7'), 7, 'batch of 7 returns count 7');
SELECT is((SELECT jsonb_array_length(j->'inserted') FROM v WHERE k = 'batch7'), 7, 'batch of 7 returns 7 inserted entries');
SELECT is(tests.ledger_count(pg_temp.c('run7'), 'ASSET_RECONCILED'), 7::bigint, 'batch of 7 stores 7 rows');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('run7') AND event_timestamp = now()), 8::bigint, 'every row has the database timestamp');
SELECT is((SELECT count(DISTINCT execution_id) FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('run7')), 1::bigint, 'one execution id per run, from the database');

-- STARTED gets the invoker from the run. Patch round 7 (O3): supplied
-- invoker_id, invoked_via or n8n_execution_id values are refused (nothing is
-- written), and the database sets the four run keys itself.
INSERT INTO v VALUES ('start_s', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('claim_s', tests.claim((SELECT j->>'run_token' FROM v WHERE k = 'start_s'), 'pgtap-040-started'));
SELECT is(pg_temp.append_err(jsonb_build_array(
  jsonb_set(jsonb_set(jsonb_set(tests.started_event((SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s'), ARRAY['BTC']),
    '{inputs,invoker_id}', to_jsonb(tests.uid('marcus.patel@finagent-os.demo'))),
    '{inputs,invoked_via}', '"cli"'), '{inputs,n8n_execution_id}', '"forged"')))
  || '/' || tests.ledger_count((SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s'), 'STARTED')::text,
  '22023 FAO-GOV-001 ledger_append: item 0: inputs.invoker_id is set only by the database/0',
  'STARTED with a supplied invoker_id is refused and stores nothing (O3)');
INSERT INTO v VALUES ('append_s', tests.append(jsonb_build_array(
  tests.started_event((SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s'), ARRAY['BTC']))));
SELECT is((SELECT inputs->>'invoker_id' FROM public.shadow_ledger WHERE correlation_id = (SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s') AND inputs->>'event_type' = 'STARTED'),
  tests.uid('aisha.okonkwo@finagent-os.demo')::text, 'STARTED records the invoker from the run');
SELECT is((SELECT inputs->>'invoked_via' FROM public.shadow_ledger WHERE correlation_id = (SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s') AND inputs->>'event_type' = 'STARTED'),
  'test', 'STARTED records invoked_via from the run');
SELECT is((SELECT inputs->>'n8n_execution_id' FROM public.shadow_ledger WHERE correlation_id = (SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s') AND inputs->>'event_type' = 'STARTED'),
  'pgtap-040-started', 'STARTED records the claimed n8n execution id');
SELECT is((SELECT inputs->>'reason' FROM public.shadow_ledger WHERE correlation_id = (SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s') AND inputs->>'event_type' = 'STARTED'),
  'pgtap run', 'STARTED records the run reason');
SELECT is((SELECT asset_scope FROM public.run_invocations WHERE correlation_id = (SELECT (j->>'correlation_id')::uuid FROM v WHERE k = 'start_s')),
  ARRAY['BTC'], 'the run asset_scope is set from STARTED');

-- Corrections reference the original and leave it unchanged
INSERT INTO v VALUES ('orig_before', (SELECT to_jsonb(l) FROM public.shadow_ledger l WHERE ledger_id = (SELECT (j::text)::bigint FROM v WHERE k = 'any_ledger_id')));
INSERT INTO v VALUES ('correct', tests.jsonb_as('marcus.patel@finagent-os.demo',
  format($$SELECT public.fao_ledger_correct(json_build_object('p_ledger_id', %L, 'p_reason', 'pgtap correction'))$$, (SELECT j::text FROM v WHERE k = 'any_ledger_id'))));
INSERT INTO v VALUES ('correct_sarah', tests.jsonb_as('sarah.chen@finagent-os.demo',
  format($$SELECT public.fao_ledger_correct(json_build_object('p_ledger_id', %L, 'p_reason', 'pgtap correction'))$$, (SELECT j::text FROM v WHERE k = 'any_ledger_id'))));
SELECT is((SELECT j->>'ok' FROM v WHERE k = 'correct'), 'true', 'Marcus records a correction');
SELECT is((SELECT corrects_ledger_id FROM public.shadow_ledger WHERE ledger_id = (SELECT (j->>'ledger_id')::bigint FROM v WHERE k = 'correct')),
  (SELECT (j::text)::bigint FROM v WHERE k = 'any_ledger_id'), 'the CORRECTION row references the original');
SELECT is((SELECT inputs->>'event_type' FROM public.shadow_ledger WHERE ledger_id = (SELECT (j->>'ledger_id')::bigint FROM v WHERE k = 'correct')),
  'CORRECTION', 'the new row is a CORRECTION event');
SELECT is((SELECT to_jsonb(l) FROM public.shadow_ledger l WHERE ledger_id = (SELECT (j::text)::bigint FROM v WHERE k = 'any_ledger_id')),
  (SELECT j FROM v WHERE k = 'orig_before'), 'the original row is unchanged');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'correct_sarah'), 'NOT_AUTHORISED', 'Sarah (not an admin) is refused');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'correct_sarah'))->>'entry_point', 'rpc:fao_ledger_correct', 'the refusal is journaled');

SELECT * FROM finish();
ROLLBACK;
