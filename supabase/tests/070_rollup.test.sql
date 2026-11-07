-- ============================================================================
-- FinAgent OS pgTAP 070: run_rollup, chain checks and compose_rationale
-- Controls: FAO-REC-001 (worst-asset rollup, no aggregate ratio), FAO-GOV-001
-- (an incomplete or tampered chain is never committed), FAO-GOV-004 (any
-- REQUIRE_HUMAN, DENY or BLOCKED asset routes the run to review).
-- ============================================================================
BEGIN;
SELECT plan(29);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = p_k $$;
-- Owner-side stray ledger row, the way a tampered chain would look.
CREATE FUNCTION pg_temp.stray(p_corr uuid, p_asset text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, inputs, policy_outcome, policy_rationale, status)
  SELECT p_corr, r.execution_id, r.agent_id, r.risk_tier, jsonb_build_object('event_type', 'ASSET_RECONCILED', 'asset', p_asset, 'ratio', 1.0),
         'ALLOW', 'pgtap stray row', 'SUCCESS'
  FROM public.run_invocations r WHERE r.correlation_id = p_corr $$;

-- A stray duplicate asset blocks the commit
INSERT INTO v VALUES ('dup', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC','ETH'])));
INSERT INTO v VALUES ('dup_a', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('dup'), 'BTC'), tests.asset_event(pg_temp.c('dup'), 'ETH'))));
SELECT pg_temp.stray(pg_temp.c('dup'), 'BTC');
INSERT INTO v VALUES ('dup_f', tests.finalize(pg_temp.c('dup')));
SELECT is(pg_temp.g('dup_f')->>'code', 'AUDIT_CHAIN_MISMATCH', 'duplicate asset: finalize returns AUDIT_CHAIN_MISMATCH');
SELECT ok(pg_temp.g('dup_f')->>'state' = 'FAILED' AND pg_temp.g('dup_f')->>'hitl_required' = 'false', 'duplicate asset: run FAILED, no request');
SELECT ok(tests.ledger_count(pg_temp.c('dup'), 'COMMIT_BLOCKED') = 1 AND tests.ledger_count(pg_temp.c('dup'), 'COMMITTED') = 0, 'duplicate asset: COMMIT_BLOCKED, never COMMITTED');
SELECT is((SELECT inputs->'problems'->'duplicate' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('dup') AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  '["BTC"]'::jsonb, 'duplicate asset: problems.duplicate names it');

-- A stray unexpected asset blocks the commit
INSERT INTO v VALUES ('unexp', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC'])));
INSERT INTO v VALUES ('unexp_a', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('unexp'), 'BTC'))));
SELECT pg_temp.stray(pg_temp.c('unexp'), 'XRP');
INSERT INTO v VALUES ('unexp_f', tests.finalize(pg_temp.c('unexp')));
SELECT is(pg_temp.g('unexp_f')->>'code', 'AUDIT_CHAIN_MISMATCH', 'unexpected asset: AUDIT_CHAIN_MISMATCH');
SELECT is((SELECT inputs->'problems'->'unexpected' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('unexp') AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  '["XRP"]'::jsonb, 'unexpected asset: problems.unexpected names it');
SELECT is((SELECT policy_rationale FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('unexp') AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  'FAO-GOV-001 audit chain incomplete; run not committed', 'COMMIT_BLOCKED rationale wording');

-- A missing asset and a run with no STARTED are reported
INSERT INTO v VALUES ('miss', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC','ETH'])));
INSERT INTO v VALUES ('miss_a', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('miss'), 'BTC'))));
INSERT INTO v VALUES ('miss_f', tests.finalize(pg_temp.c('miss')));
SELECT is((SELECT inputs->'problems'->'missing' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('miss') AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  '["ETH"]'::jsonb, 'missing asset: problems.missing names it');
INSERT INTO v VALUES ('nostart', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('nostart_c', tests.claim(pg_temp.g('nostart')->>'run_token'));
INSERT INTO v VALUES ('nostart_f', tests.finalize((pg_temp.g('nostart')->>'correlation_id')::uuid));
SELECT is(pg_temp.g('nostart_f')->>'code', 'AUDIT_CHAIN_MISMATCH', 'no STARTED: AUDIT_CHAIN_MISMATCH');
SELECT is((SELECT (inputs->'problems'->>'started_count')::int FROM public.shadow_ledger WHERE correlation_id = (pg_temp.g('nostart')->>'correlation_id')::uuid AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  0, 'no STARTED: problems.started_count is 0');

-- A chain broken while awaiting a decision: the decision returns AUDIT_CHAIN_MISMATCH
INSERT INTO v VALUES ('req', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('req_corr', to_jsonb(tests.request_corr((pg_temp.g('req')::text)::bigint)));
SELECT pg_temp.stray(pg_temp.c('req_corr'), 'DOGE');
INSERT INTO v VALUES ('j_before', to_jsonb(tests.journal_total()));
INSERT INTO v VALUES ('req_d', tests.decide_raw('sarah.chen@finagent-os.demo', pg_temp.g('req')::text, 'APPROVED'));
SELECT is(pg_temp.g('req_d')->>'code', 'AUDIT_CHAIN_MISMATCH', 'decision on a broken chain returns AUDIT_CHAIN_MISMATCH');
SELECT ok(pg_temp.g('req_d')->>'ok' = 'true' AND pg_temp.g('req_d')->>'committed' = 'false' AND pg_temp.g('req_d')->'committed_ledger_id' = 'null'::jsonb,
  'AUDIT_CHAIN_MISMATCH is ok:true, committed:false, committed_ledger_id:null');
SELECT ok(tests.ledger_count(pg_temp.c('req_corr'), 'COMMIT_BLOCKED') = 1 AND tests.ledger_count(pg_temp.c('req_corr'), 'COMMITTED') = 0,
  'broken chain at decision: COMMIT_BLOCKED, never COMMITTED');
SELECT is(tests.run_state(pg_temp.c('req_corr')), 'FAILED', 'broken chain at decision: run FAILED');
SELECT is(tests.journal_total(), (pg_temp.g('j_before')::text)::bigint, 'AUDIT_CHAIN_MISMATCH is not journaled');

-- Routing: BLOCKED plus two CRITICAL; only BLOCKED; DENY
INSERT INTO v VALUES ('mix', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['ADA','BTC','SOL'])));
INSERT INTO v VALUES ('mix_a', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('mix'), 'ADA', 'BLOCKED'),
  tests.asset_event(pg_temp.c('mix'), 'BTC', 'REQUIRE_HUMAN', 'CRITICAL'), tests.asset_event(pg_temp.c('mix'), 'SOL', 'REQUIRE_HUMAN', 'CRITICAL'))));
INSERT INTO v VALUES ('mix_r', fao_private.run_rollup(pg_temp.c('mix')));
INSERT INTO v VALUES ('mix_f', tests.finalize(pg_temp.c('mix')));
SELECT is(pg_temp.g('mix_f')->>'hitl_required', 'true', 'BLOCKED plus two CRITICAL routes to review');
SELECT is(pg_temp.g('mix_f')->>'review_sub_tier', 'CRITICAL', 'BLOCKED plus two CRITICAL: review sub-tier CRITICAL');
SELECT is(pg_temp.g('mix_r')->>'rollup_outcome', 'BLOCKED', 'BLOCKED plus two CRITICAL: rollup outcome BLOCKED');

INSERT INTO v VALUES ('blk', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['ETH','XRP'])));
INSERT INTO v VALUES ('blk_a', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('blk'), 'ETH'), tests.asset_event(pg_temp.c('blk'), 'XRP', 'BLOCKED'))));
INSERT INTO v VALUES ('blk_f', tests.finalize(pg_temp.c('blk')));
SELECT is(pg_temp.g('blk_f')->>'hitl_required', 'true', 'a run whose only abnormal asset is BLOCKED routes to review');
SELECT is(pg_temp.g('blk_f')->>'review_sub_tier', 'CRITICAL', 'BLOCKED alone: review sub-tier CRITICAL');

INSERT INTO v VALUES ('deny', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['ETH','SOL'])));
INSERT INTO v VALUES ('deny_a', tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('deny'), 'ETH'), tests.asset_event(pg_temp.c('deny'), 'SOL', 'DENY'))));
INSERT INTO v VALUES ('deny_r', fao_private.run_rollup(pg_temp.c('deny')));
INSERT INTO v VALUES ('deny_f', tests.finalize(pg_temp.c('deny')));
SELECT is(pg_temp.g('deny_f')->>'hitl_required', 'true', 'DENY routes to review');

-- No aggregate ratio anywhere in the rollup output
SELECT is_empty($$SELECT k FROM jsonb_object_keys(pg_temp.g('mix_r')) k WHERE k ~* 'ratio'$$, 'run_rollup has no aggregate ratio key');
SELECT is_empty($$SELECT k FROM jsonb_object_keys(pg_temp.g('mix_f')) k WHERE k ~* 'ratio'$$, 'fao_run_finalize result has no aggregate ratio key');
SELECT is_empty($$SELECT k FROM jsonb_object_keys(pg_temp.g('mix_r')->'counts') k WHERE k ~* 'ratio'$$, 'rollup counts have no ratio key');

-- compose_rationale wording (2.10) for a fixed rollup
INSERT INTO v VALUES ('fix', to_jsonb(tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['ADA','BTC','ETH','SOL','USDT'])));
INSERT INTO v VALUES ('fix_a', tests.append(jsonb_build_array(
  tests.asset_event(pg_temp.c('fix'), 'ADA', 'REQUIRE_HUMAN', 'CRITICAL'),
  tests.asset_event(pg_temp.c('fix'), 'BTC', 'ALLOW_WITH_OBLIGATIONS'),
  tests.asset_event(pg_temp.c('fix'), 'ETH', 'ALLOW'),
  tests.asset_event(pg_temp.c('fix'), 'SOL', 'REQUIRE_HUMAN', 'CRITICAL'),
  tests.asset_event(pg_temp.c('fix'), 'USDT', 'REQUIRE_HUMAN', 'STANDARD'))));
INSERT INTO v VALUES ('fix_r', fao_private.run_rollup(pg_temp.c('fix')));
SELECT is(fao_private.compose_rationale(pg_temp.g('fix_r'), 'COMMITTED'),
  'FAO-REC-001 execution rollup over 5 assets. Outcomes: 1 ALLOW, 1 ALLOW_WITH_OBLIGATIONS, 3 REQUIRE_HUMAN. Worst-asset rule applied: execution outcome = REQUIRE_HUMAN (CRITICAL). Escalated assets: ADA (REQUIRE_HUMAN/CRITICAL), SOL (REQUIRE_HUMAN/CRITICAL), USDT (REQUIRE_HUMAN/STANDARD).',
  'compose_rationale COMMITTED wording');
SELECT is(fao_private.compose_rationale(pg_temp.g('fix_r'), 'HITL_REQUEST'),
  'FAO-REC-001 execution rollup over 5 assets. Outcomes: 1 ALLOW, 1 ALLOW_WITH_OBLIGATIONS, 3 REQUIRE_HUMAN. Worst-asset rule applied: execution outcome = REQUIRE_HUMAN (CRITICAL). Escalated assets: ADA (REQUIRE_HUMAN/CRITICAL), SOL (REQUIRE_HUMAN/CRITICAL), USDT (REQUIRE_HUMAN/STANDARD). Human review required (review sub-tier CRITICAL).',
  'compose_rationale HITL_REQUEST wording');
SELECT is(fao_private.compose_rationale(pg_temp.g('deny_r'), 'COMMITTED'),
  'FAO-REC-001 execution rollup over 2 assets. Outcomes: 1 ALLOW, 0 ALLOW_WITH_OBLIGATIONS, 0 REQUIRE_HUMAN, 1 DENY. Worst-asset rule applied: execution outcome = DENY. Escalated assets: SOL (DENY).',
  'compose_rationale lists DENY only when present and omits a NULL sub-tier');
INSERT INTO v VALUES ('fix_f', tests.finalize(pg_temp.c('fix')));
SELECT is((SELECT policy_rationale FROM public.hitl_queue WHERE correlation_id = pg_temp.c('fix')),
  fao_private.compose_rationale(pg_temp.g('fix_r'), 'HITL_REQUEST'), 'the request rationale is compose_rationale(r, HITL_REQUEST)');
SELECT is((pg_temp.g('fix_r')->'counts'), '{"ALLOW": 1, "ALLOW_WITH_OBLIGATIONS": 1, "REQUIRE_HUMAN": 3, "DENY": 0, "BLOCKED": 0}'::jsonb,
  'rollup counts carry all five outcome keys');

SELECT * FROM finish();
ROLLBACK;
