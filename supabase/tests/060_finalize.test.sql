-- ============================================================================
-- FinAgent OS pgTAP 060: fao_run_finalize and fao_run_fail
-- Controls: FAO-GOV-004 (one request and one HITL_REQUESTED, atomically with
-- the move to AWAITING_HITL; frozen approval counts), FAO-REC-001 (rollup
-- drives review), FAO-GOV-008 (failed runs recorded once, state machine).
-- ============================================================================
BEGIN;
SELECT plan(43);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.exec_of(p_corr uuid) RETURNS text LANGUAGE sql AS $$ SELECT n8n_execution_id FROM public.run_invocations WHERE correlation_id = p_corr $$;

-- A clean run commits with no request
INSERT INTO v VALUES ('clean', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['ETH','USDC'])));
INSERT INTO v VALUES ('clean_append', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('clean'), 'ETH'), tests.asset_event(pg_temp.c('clean'), 'USDC'))));
INSERT INTO v VALUES ('clean_fin', tests.finalize(pg_temp.c('clean')));
SELECT is(pg_temp.g('clean_fin')->>'state', 'COMMITTED', 'clean run: finalize returns COMMITTED');
SELECT is(pg_temp.g('clean_fin')->>'hitl_required', 'false', 'clean run: no review required');
SELECT is((SELECT count(*) FROM public.hitl_queue WHERE correlation_id = pg_temp.c('clean')), 0::bigint, 'clean run: no request');
SELECT is(tests.ledger_count(pg_temp.c('clean'), 'COMMITTED'), 1::bigint, 'clean run: one COMMITTED');
SELECT is((SELECT ledger_id FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('clean') AND inputs->>'event_type' = 'COMMITTED'),
  (pg_temp.g('clean_fin')->>'committed_ledger_id')::bigint, 'clean run: committed_ledger_id is the COMMITTED row');
SELECT is(tests.run_state(pg_temp.c('clean')), 'COMMITTED', 'clean run: run state COMMITTED');

-- A run needing review gets exactly one request
INSERT INTO v VALUES ('review', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['SOL','BTC','USDT'])));
INSERT INTO v VALUES ('review_append', tests.append(jsonb_build_array(
  tests.asset_event(pg_temp.c('review'), 'SOL', 'REQUIRE_HUMAN', 'CRITICAL'),
  tests.asset_event(pg_temp.c('review'), 'BTC', 'ALLOW'),
  tests.asset_event(pg_temp.c('review'), 'USDT', 'REQUIRE_HUMAN', 'STANDARD'))));
INSERT INTO v VALUES ('review_fin', tests.finalize(pg_temp.c('review')));
SELECT is(pg_temp.g('review_fin')->>'hitl_required', 'true', 'review run: review required');
SELECT is(pg_temp.g('review_fin')->>'state', 'AWAITING_HITL', 'review run: finalize returns AWAITING_HITL');
SELECT is(tests.run_state(pg_temp.c('review')), 'AWAITING_HITL', 'review run: run state AWAITING_HITL');
SELECT is((SELECT count(*) FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), 1::bigint, 'review run: exactly one request');
SELECT is(tests.ledger_count(pg_temp.c('review'), 'HITL_REQUESTED'), 1::bigint, 'review run: exactly one HITL_REQUESTED');
SELECT is(tests.ledger_count(pg_temp.c('review'), 'COMMITTED'), 0::bigint, 'review run: not committed yet');
SELECT is((SELECT approval_url FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), pg_temp.g('review_fin')->>'approval_url', 'review run: returned approval_url is stored');
SELECT is(pg_temp.g('review_fin')->>'approval_url', 'http://localhost:4173/?hitl_id=' || (pg_temp.g('review_fin')->>'hitl_id'), 'review run: approval_url is the base URL plus the hitl id only');
SELECT is((SELECT inputs->>'approval_url' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('review') AND inputs->>'event_type' = 'HITL_REQUESTED'),
  pg_temp.g('review_fin')->>'approval_url', 'review run: HITL_REQUESTED carries the same approval_url');
SELECT is((SELECT ledger_id FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('review') AND inputs->>'event_type' = 'HITL_REQUESTED'),
  (pg_temp.g('review_fin')->>'hitl_requested_ledger_id')::bigint, 'review run: hitl_requested_ledger_id is the HITL_REQUESTED row');
SELECT is((SELECT sub_tier::text FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), 'CRITICAL', 'review run: request sub-tier from the rollup');
SELECT is(pg_temp.g('review_fin')->>'review_sub_tier', 'CRITICAL', 'review run: review_sub_tier CRITICAL');
SELECT is((SELECT jsonb_agg(e->>'asset') FROM public.hitl_queue h CROSS JOIN LATERAL jsonb_array_elements(h.escalated_assets) e WHERE h.correlation_id = pg_temp.c('review')),
  '["SOL", "USDT"]'::jsonb, 'review run: escalated assets in scope order');
SELECT is((SELECT configured_approvals FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), 2, 'review run: configured_approvals from the registry (2)');
SELECT is((SELECT enforced_approvals FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), 1, 'review run: enforced_approvals is 1');
SELECT is((SELECT agent_invoker_id FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), tests.uid('aisha.okonkwo@finagent-os.demo'), 'review run: request names the invoker from the run');
SELECT is((SELECT timeout_at FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), (pg_temp.g('review_fin')->>'timeout_at')::timestamptz, 'review run: timeout_at returned and stored');
SELECT is((SELECT timeout_at FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), now() + interval '24 hours', 'review run: timeout from the agent SLA');

-- A forced failure inside request creation leaves nothing behind
CREATE FUNCTION tests.pgtap_raise_on_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'pgtap forced failure'; END $$;
CREATE TRIGGER pgtap_fail_request BEFORE INSERT ON public.hitl_queue FOR EACH ROW EXECUTE FUNCTION tests.pgtap_raise_on_insert();
INSERT INTO v VALUES ('forced', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['SOL'])));
INSERT INTO v VALUES ('forced_append', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('forced'), 'SOL', 'REQUIRE_HUMAN', 'CRITICAL'))));
INSERT INTO v VALUES ('forced_fin', tests.jsonb_as('fao_workflow', format('SELECT public.fao_run_finalize(%L::uuid)', pg_temp.c('forced'))));
DROP TRIGGER pgtap_fail_request ON public.hitl_queue;
SELECT ok(pg_temp.g('forced_fin') ? 'error', 'forced failure: finalize raises');
SELECT is(tests.run_state(pg_temp.c('forced')), 'RUNNING', 'forced failure: run stays RUNNING');
SELECT is((SELECT count(*) FROM public.hitl_queue WHERE correlation_id = pg_temp.c('forced')), 0::bigint, 'forced failure: no request');
SELECT is(tests.ledger_count(pg_temp.c('forced'), 'HITL_REQUESTED'), 0::bigint, 'forced failure: no HITL_REQUESTED');

-- Owner INSERTs the row guard refuses
SELECT throws_ok(format($$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale, timeout_at)
                          VALUES (%L, 'fao_reserve_recon_v1', %L, 'RED', 'x', now() + interval '1 day')$$, pg_temp.c('clean'), tests.uid('aisha.okonkwo@finagent-os.demo')),
  '42501', NULL, 'owner INSERT for a run that is not RUNNING is refused');
SELECT throws_ok(format($$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale, timeout_at)
                          VALUES (%L, 'fao_reserve_recon_v1', %L, 'RED', 'x', now() + interval '1 day')$$, pg_temp.c('review'), tests.uid('aisha.okonkwo@finagent-os.demo')),
  '42501', NULL, 'owner INSERT for a run that already has a request is refused');

-- Finalize on a non-RUNNING run raises
SELECT matches(tests.error_as('fao_workflow', format('SELECT public.fao_run_finalize(%L::uuid)', pg_temp.c('review'))),
  'FAO-GOV-008 run_finalize', 'finalize on a run that is not RUNNING raises');

-- fao_run_fail
INSERT INTO v VALUES ('j_before', to_jsonb(tests.journal_total()));
INSERT INTO v VALUES ('l_before', to_jsonb((SELECT count(*) FROM public.shadow_ledger)));
INSERT INTO v VALUES ('fail_unknown', tests.jsonb_as('fao_workflow', $$SELECT public.fao_run_fail('no-such-execution', 'Node', 'boom', 'flagship')$$));
SELECT is(pg_temp.g('fail_unknown')->>'code', 'UNKNOWN_EXECUTION', 'run_fail: unknown execution is UNKNOWN_EXECUTION');
SELECT is(pg_temp.g('fail_unknown')->>'ok', 'false', 'run_fail: UNKNOWN_EXECUTION is ok:false');
SELECT ok((SELECT count(*) FROM public.shadow_ledger) = (pg_temp.g('l_before')::text)::bigint AND tests.journal_total() = (pg_temp.g('j_before')::text)::bigint,
  'run_fail: an unknown execution writes nothing');

INSERT INTO v VALUES ('fail_running', tests.jsonb_as('fao_workflow',
  format($$SELECT public.fao_run_fail(%L, 'Per-Asset Reconcile', E'boom\u0001\nline', 'flagship')$$, pg_temp.exec_of(pg_temp.c('forced')))));
SELECT is(pg_temp.g('fail_running')->>'state', 'FAILED', 'run_fail: a RUNNING run moves to FAILED');
SELECT is(tests.run_state(pg_temp.c('forced')), 'FAILED', 'run_fail: run state FAILED');
SELECT is((SELECT inputs->>'stage' || '/' || (inputs->>'source') || '/' || policy_outcome::text || '/' || status::text FROM public.shadow_ledger
           WHERE correlation_id = pg_temp.c('forced') AND inputs->>'event_type' = 'FAILED'),
  'before_request/error_workflow/BLOCKED/FAILURE', 'run_fail: FAILED before_request from the error workflow');
SELECT is((SELECT policy_rationale FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('forced') AND inputs->>'event_type' = 'FAILED'),
  'FAO-GOV-008 run failed at Per-Asset Reconcile (error_workflow)', 'run_fail: FAILED rationale wording');
SELECT ok((SELECT error_details !~ '[[:cntrl:]]' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('forced') AND inputs->>'event_type' = 'FAILED'),
  'run_fail: error_details has no control characters');

INSERT INTO v VALUES ('fail_awaiting', tests.jsonb_as('fao_workflow',
  format($$SELECT public.fao_run_fail(%L, 'HITL Gateway', 'notifier failed', 'flagship')$$, pg_temp.exec_of(pg_temp.c('review')))));
SELECT is((SELECT inputs->>'stage' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('review') AND inputs->>'event_type' = 'FAILED'),
  'after_request', 'run_fail: an AWAITING_HITL run gets FAILED with stage after_request');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE correlation_id = pg_temp.c('review')), 'PENDING', 'run_fail: the request stays PENDING');
SELECT is(tests.run_state(pg_temp.c('review')), 'AWAITING_HITL', 'run_fail: the AWAITING_HITL run state is unchanged');

INSERT INTO v VALUES ('fail_terminal', tests.jsonb_as('fao_workflow',
  format($$SELECT public.fao_run_fail(%L, 'Node', 'late', 'flagship')$$, pg_temp.exec_of(pg_temp.c('clean')))));
SELECT ok(pg_temp.g('fail_terminal')->>'code' = 'ALREADY_TERMINAL' AND pg_temp.g('fail_terminal')->>'ok' = 'true'
          AND tests.ledger_count(pg_temp.c('clean'), 'FAILED') = 0, 'run_fail: a terminal run gives ALREADY_TERMINAL and writes nothing');

SELECT * FROM finish();
ROLLBACK;
