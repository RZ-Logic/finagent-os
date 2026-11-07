-- ============================================================================
-- FinAgent OS pgTAP 144: fix round 3, the registry status gate at commit
-- Controls:
--   FAO-GOV-002 (item 1): an APPROVED decision for an agent that is no longer
--     ACTIVE (DEPRECATED or STUB_DOCUMENTED) is never COMMITTED SUCCESS. The
--     decision and HITL_RESOLVED stand; COMMIT_BLOCKED (inputs.code
--     AGENT_NOT_ACTIVE, the agent status, the rollup problems) and run FAILED
--     are written in the same transaction; the envelope is AGENT_NOT_ACTIVE
--     (409, journaled) with the decision fields. A REJECTED decision still
--     closes the run (COMMITTED, ROLLED_BACK, REJECTED).
--   FAO-GOV-002, FAO-GOV-001 (item 3): fao_run_finalize records the same
--     block instead of raising, with and without an intact audit chain, and
--     opens no request for a review-needed run.
--   FAO-GOV-002: both functions read the agent row FOR SHARE after the run
--     lock, so a concurrent status change is ordered against the commit (the
--     two-session case is run outside pgTAP; see the fix round 3 record).
-- Agent fao_reserve_recon_v1: invoker Aisha, approver Sarah. Every run is
-- made while the agent is ACTIVE; the status changes come after.
-- ============================================================================
BEGIN;
SELECT plan(50);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j#>>'{}')::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = p_k $$;
-- The run of a request
CREATE FUNCTION pg_temp.rc(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr(pg_temp.id(p_k)) $$;
CREATE FUNCTION pg_temp.since() RETURNS bigint LANGUAGE sql AS $$ SELECT (j#>>'{}')::bigint FROM v WHERE k = 'start_id' $$;
CREATE FUNCTION pg_temp.keys(p_j jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_j) AS k $$;
CREATE FUNCTION pg_temp.blocked(p_corr uuid) RETURNS public.shadow_ledger LANGUAGE sql AS $$
  SELECT * FROM public.shadow_ledger WHERE correlation_id = p_corr AND inputs->>'event_type' = 'COMMIT_BLOCKED' $$;
CREATE FUNCTION pg_temp.summary(p_corr uuid) RETURNS text LANGUAGE sql AS $$
  SELECT tests.run_state(p_corr) || '/' || tests.ledger_count(p_corr, 'COMMITTED') || '/' || tests.ledger_count(p_corr, 'COMMIT_BLOCKED') $$;
CREATE FUNCTION pg_temp.set_status(p_status text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 144 status ' || p_status, true);
  UPDATE public.agent_registry SET status = p_status::public.agent_status WHERE agent_id = 'fao_reserve_recon_v1';
END $$;
-- Owner-side stray ledger row, the way a tampered chain would look (as 070).
CREATE FUNCTION pg_temp.stray(p_corr uuid, p_asset text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, inputs, policy_outcome, policy_rationale, status)
  SELECT p_corr, r.execution_id, r.agent_id, r.risk_tier, jsonb_build_object('event_type', 'ASSET_RECONCILED', 'asset', p_asset, 'ratio', 1.0),
         'ALLOW', 'pgtap 144 stray row', 'SUCCESS'
  FROM public.run_invocations r WHERE r.correlation_id = p_corr $$;
CREATE FUNCTION pg_temp.jrows(p_entry text, p_key text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.fao_refusal_journal
   WHERE refusal_id > pg_temp.since() AND entry_point = p_entry AND code = 'AGENT_NOT_ACTIVE' AND target_key = p_key $$;
-- A RUNNING run with the given assets recorded (STARTED plus one event each)
CREATE FUNCTION pg_temp.run_with(p_scope text[], p_events jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_corr uuid;
  e jsonb := '[]'::jsonb;
  x jsonb;
BEGIN
  v_corr := tests.make_run('aisha.okonkwo@finagent-os.demo', p_scope);
  FOR x IN SELECT * FROM jsonb_array_elements(p_events) LOOP
    e := e || jsonb_build_array(tests.asset_event(v_corr, x->>0, x->>1, x->>2));
  END LOOP;
  PERFORM tests.append(e);
  RETURN v_corr;
END $$;

SELECT tests.set_clock(0);
INSERT INTO v VALUES ('start_id', to_jsonb((SELECT coalesce(max(refusal_id), 0) FROM public.fao_refusal_journal)));
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 144 rate limits', true);
  UPDATE public.agent_registry SET max_runs_per_hour = 60 WHERE agent_id = 'fao_reserve_recon_v1';
END $$;

-- ---------------------------------------------------------------------------
-- Setup while ACTIVE: requests awaiting a decision and RUNNING runs
-- ---------------------------------------------------------------------------
INSERT INTO v VALUES ('hA',  to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo', ARRAY['BTC'])));
INSERT INTO v VALUES ('hR',  to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('hB',  to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('hS1', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('hS2', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('hC',  to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.stray(pg_temp.rc('hB'), 'DOGE');
INSERT INTO v VALUES ('fA', to_jsonb(pg_temp.run_with(ARRAY['BTC'], '[["BTC", "ALLOW", null]]')));
INSERT INTO v VALUES ('fB', to_jsonb(pg_temp.run_with(ARRAY['BTC', 'ETH'], '[["BTC", "ALLOW", null]]')));
INSERT INTO v VALUES ('fH', to_jsonb(pg_temp.run_with(ARRAY['USDT'], '[["USDT", "REQUIRE_HUMAN", "STANDARD"]]')));
INSERT INTO v VALUES ('fS', to_jsonb(pg_temp.run_with(ARRAY['BTC'], '[["BTC", "ALLOW", null]]')));
INSERT INTO v VALUES ('fC', to_jsonb(pg_temp.run_with(ARRAY['BTC'], '[["BTC", "ALLOW", null]]')));
SELECT is((SELECT count(*) FROM public.run_invocations WHERE state = 'AWAITING_HITL'
             AND correlation_id IN (pg_temp.rc('hA'), pg_temp.rc('hR'), pg_temp.rc('hB'), pg_temp.rc('hS1'), pg_temp.rc('hS2'), pg_temp.rc('hC')))
          || '/' || (SELECT count(*) FROM public.run_invocations WHERE state = 'RUNNING'
             AND correlation_id IN (pg_temp.c('fA'), pg_temp.c('fB'), pg_temp.c('fH'), pg_temp.c('fS'), pg_temp.c('fC'))),
  '6/5', 'setup: six runs await a decision and five are RUNNING while the agent is ACTIVE');

-- ---------------------------------------------------------------------------
-- Item 1: decide after the agent is DEPRECATED
-- ---------------------------------------------------------------------------
SELECT pg_temp.set_status('DEPRECATED');

-- APPROVED, intact chain
INSERT INTO v VALUES ('dA', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('hA'), 'APPROVED', 'pgtap 144 approve'));
SELECT is(pg_temp.g('dA')->>'ok' || '/' || (pg_temp.g('dA')->>'code') || '/' || (pg_temp.g('dA')->>'http_status') || '/' || (pg_temp.g('dA')->>'message'),
  'false/AGENT_NOT_ACTIVE/409/The agent is not active.', 'decide DEPRECATED approve: envelope AGENT_NOT_ACTIVE 409 with the fixed message');
SELECT is((pg_temp.g('dA')->>'hitl_id')::bigint || '/' || (pg_temp.g('dA')->>'decision') || '/' || (pg_temp.g('dA')->>'committed')
          || '/' || coalesce(pg_temp.g('dA')->>'committed_ledger_id', 'null') || '/' || ((pg_temp.g('dA')->>'decided_at') IS NOT NULL)::text,
  pg_temp.id('hA') || '/APPROVED/false/null/true', 'decide DEPRECATED approve: decision fields kept, committed false, no ledger id');
SELECT is(pg_temp.keys(pg_temp.g('dA')),
  ARRAY['code', 'committed', 'committed_ledger_id', 'decided_at', 'decision', 'hitl_id', 'http_status', 'message', 'ok', 'ref'],
  'decide DEPRECATED approve: exactly the decide envelope keys');
SELECT is((SELECT decision::text || '/' || (approver_id = tests.uid('sarah.chen@finagent-os.demo'))::text || '/' || decision_notes
             FROM public.hitl_queue WHERE hitl_id = pg_temp.id('hA')),
  'APPROVED/true/pgtap 144 approve', 'decide DEPRECATED approve: the decision is recorded durably on the request');
SELECT is(pg_temp.summary(pg_temp.rc('hA')), 'FAILED/0/1', 'decide DEPRECATED approve: run FAILED, nothing COMMITTED, one COMMIT_BLOCKED');
SELECT is((SELECT last_error FROM public.run_invocations WHERE correlation_id = pg_temp.rc('hA')), 'agent not ACTIVE at commit',
  'decide DEPRECATED approve: the run names the reason');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('hA') AND status = 'SUCCESS'
             AND inputs->>'event_type' NOT IN ('STARTED', 'ASSET_RECONCILED', 'HITL_REQUESTED', 'HITL_RESOLVED')), 0::bigint,
  'decide DEPRECATED approve: no SUCCESS commit-side row of any kind');
SELECT is((SELECT (b).inputs->>'code' || '/' || ((b).inputs->>'agent_status') || '/' || (b).status || '/' || (b).policy_outcome
                  || '/' || (b).hitl_status || '/' || ((b).inputs->>'hitl_id')
             FROM (SELECT pg_temp.blocked(pg_temp.rc('hA')) AS b) s),
  'AGENT_NOT_ACTIVE/DEPRECATED/FAILURE/BLOCKED/APPROVED/' || pg_temp.id('hA'),
  'decide DEPRECATED approve: COMMIT_BLOCKED carries the code, agent status, decision and request');
SELECT is((SELECT (b).inputs->'problems' FROM (SELECT pg_temp.blocked(pg_temp.rc('hA')) AS b) s),
  '{"missing": [], "duplicate": [], "unexpected": [], "started_count": 1}'::jsonb,
  'decide DEPRECATED approve: the rollup evidence (intact chain) is kept');
SELECT ok((SELECT max(ledger_id) FILTER (WHERE inputs->>'event_type' = 'HITL_RESOLVED')
                < max(ledger_id) FILTER (WHERE inputs->>'event_type' = 'COMMIT_BLOCKED')
             FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('hA'))
          AND tests.ledger_count(pg_temp.rc('hA'), 'HITL_RESOLVED') = 1,
  'decide DEPRECATED approve: one HITL_RESOLVED, then COMMIT_BLOCKED');
SELECT ok((SELECT (b).policy_rationale LIKE 'FAO-GOV-002 agent fao_reserve_recon_v1 status DEPRECATED at commit%'
                  AND (b).policy_rationale NOT LIKE '%audit chain%' FROM (SELECT pg_temp.blocked(pg_temp.rc('hA')) AS b) s),
  'decide DEPRECATED approve: the rationale names the agent status and no chain problem');
SELECT is(pg_temp.jrows('rpc:fao_hitl_decide', pg_temp.id('hA')::text), 1::bigint, 'decide DEPRECATED approve: the refusal is journaled once');
SELECT is((SELECT (refusal_id = (pg_temp.g('dA')->>'ref')::bigint)::text || '/' || target_table || '/' || (attempted->>'decision')
             FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND entry_point = 'rpc:fao_hitl_decide'
              AND code = 'AGENT_NOT_ACTIVE' AND target_key = pg_temp.id('hA')::text),
  'true/hitl_queue/APPROVED', 'decide DEPRECATED approve: ref is the journal row, target hitl_queue, decision attempted');
INSERT INTO v VALUES ('dA2', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('hA'), 'APPROVED'));
SELECT is(pg_temp.g('dA2')->>'code' || '/' || pg_temp.summary(pg_temp.rc('hA')), 'ALREADY_DECIDED/FAILED/0/1',
  'decide DEPRECATED approve: a second approval is ALREADY_DECIDED and writes nothing');

-- REJECTED, intact chain
INSERT INTO v VALUES ('dR', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('hR'), 'REJECTED'));
SELECT is(pg_temp.g('dR')->>'ok' || '/' || (pg_temp.g('dR')->>'code') || '/' || (pg_temp.g('dR')->>'committed')
          || '/' || ((pg_temp.g('dR')->>'committed_ledger_id') IS NOT NULL)::text,
  'true/OK/true/true', 'decide DEPRECATED reject: OK, committed, with a ledger id');
SELECT is(pg_temp.keys(pg_temp.g('dR')), pg_temp.keys(pg_temp.g('dA')), 'decide: the blocked and the OK envelopes have the same keys');
SELECT is(pg_temp.summary(pg_temp.rc('hR')), 'COMMITTED/1/0', 'decide DEPRECATED reject: the run closes COMMITTED with no COMMIT_BLOCKED');
SELECT is((SELECT status::text || '/' || hitl_status::text || '/' || (ledger_id = (pg_temp.g('dR')->>'committed_ledger_id')::bigint)::text
             FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('hR') AND inputs->>'event_type' = 'COMMITTED'),
  'ROLLED_BACK/REJECTED/true', 'decide DEPRECATED reject: COMMITTED is ROLLED_BACK / REJECTED');
SELECT is(pg_temp.jrows('rpc:fao_hitl_decide', pg_temp.id('hR')::text), 0::bigint, 'decide DEPRECATED reject: nothing journaled');

-- APPROVED, broken chain: the status reason and the chain evidence together
INSERT INTO v VALUES ('dB', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('hB'), 'APPROVED'));
SELECT is(pg_temp.g('dB')->>'ok' || '/' || (pg_temp.g('dB')->>'code') || '/' || (pg_temp.g('dB')->>'committed'),
  'false/AGENT_NOT_ACTIVE/false', 'decide DEPRECATED approve, broken chain: AGENT_NOT_ACTIVE, not committed');
SELECT is(pg_temp.summary(pg_temp.rc('hB')), 'FAILED/0/1', 'decide DEPRECATED approve, broken chain: run FAILED, exactly one COMMIT_BLOCKED');
SELECT is((SELECT (b).inputs->>'code' || '/' || ((b).inputs->'problems'->'unexpected')::text FROM (SELECT pg_temp.blocked(pg_temp.rc('hB')) AS b) s),
  'AGENT_NOT_ACTIVE/["DOGE"]', 'decide DEPRECATED approve, broken chain: COMMIT_BLOCKED keeps the stray asset evidence');
SELECT ok((SELECT (b).policy_rationale LIKE 'FAO-GOV-002 %' AND (b).policy_rationale LIKE '%FAO-GOV-001 audit chain incomplete'
             FROM (SELECT pg_temp.blocked(pg_temp.rc('hB')) AS b) s),
  'decide DEPRECATED approve, broken chain: the rationale names both reasons');

-- The earlier checks still come first: the invoker is refused before any write
INSERT INTO v VALUES ('dSod', tests.decide('aisha.okonkwo@finagent-os.demo', pg_temp.id('hS1'), 'APPROVED'));
SELECT is(pg_temp.g('dSod')->>'code' || '/' || tests.ledger_count(pg_temp.rc('hS1'), 'HITL_RESOLVED') || '/' || pg_temp.summary(pg_temp.rc('hS1')),
  'SOD_SELF_APPROVAL/0/AWAITING_HITL/0/0', 'decide DEPRECATED: self-approval is still SOD_SELF_APPROVAL with nothing written');

-- ---------------------------------------------------------------------------
-- Item 3: finalize after the agent is DEPRECATED
-- ---------------------------------------------------------------------------
INSERT INTO v VALUES ('xA', tests.finalize(pg_temp.c('fA')));
SELECT is(pg_temp.g('xA')->>'ok' || '/' || (pg_temp.g('xA')->>'code') || '/' || (pg_temp.g('xA')->>'http_status') || '/' || (pg_temp.g('xA')->>'state')
          || '/' || (pg_temp.g('xA')->>'hitl_required') || '/' || coalesce(pg_temp.g('xA')->>'committed_ledger_id', 'null'),
  'false/AGENT_NOT_ACTIVE/409/FAILED/false/null', 'finalize DEPRECATED, intact chain: AGENT_NOT_ACTIVE 409, state FAILED, nothing committed');
SELECT is(pg_temp.summary(pg_temp.c('fA')), 'FAILED/0/1', 'finalize DEPRECATED, intact chain: run FAILED with one COMMIT_BLOCKED (no raise)');
SELECT is((SELECT (b).inputs->>'code' || '/' || ((b).inputs->>'agent_status') || '/' || (b).status || '/' || (b).hitl_status
                  || '/' || coalesce((b).inputs->>'hitl_id', 'null') || '/' || ((b).inputs->'problems')::text
             FROM (SELECT pg_temp.blocked(pg_temp.c('fA')) AS b) s),
  'AGENT_NOT_ACTIVE/DEPRECATED/FAILURE/NOT_REQUIRED/null/{"missing": [], "duplicate": [], "unexpected": [], "started_count": 1}',
  'finalize DEPRECATED, intact chain: COMMIT_BLOCKED has the code, status and the intact rollup evidence');
SELECT is((SELECT target_table || '/' || (attempted->>'agent_id') || '/' || (refusal_id = (pg_temp.g('xA')->>'ref')::bigint)::text
             FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND entry_point = 'rpc:fao_run_finalize'
              AND code = 'AGENT_NOT_ACTIVE' AND target_key = pg_temp.c('fA')::text),
  'run_invocations/fao_reserve_recon_v1/true', 'finalize DEPRECATED: journaled once against the run, ref is the row');
SELECT throws_matching(format('SELECT tests.finalize(%L::uuid)', pg_temp.c('fA')), 'is not RUNNING',
  'finalize DEPRECATED: a second finalize of the FAILED run raises');
SELECT is(tests.ledger_count(pg_temp.c('fA'), 'COMMIT_BLOCKED') || '/' || pg_temp.jrows('rpc:fao_run_finalize', pg_temp.c('fA')::text), '1/1',
  'finalize DEPRECATED: the second call wrote nothing');

-- Broken chain (ETH missing): both reasons, one COMMIT_BLOCKED
INSERT INTO v VALUES ('xB', tests.finalize(pg_temp.c('fB')));
SELECT is(pg_temp.g('xB')->>'code' || '/' || (pg_temp.g('xB')->>'state') || '/' || pg_temp.summary(pg_temp.c('fB')),
  'AGENT_NOT_ACTIVE/FAILED/FAILED/0/1', 'finalize DEPRECATED, broken chain: AGENT_NOT_ACTIVE (not AUDIT_CHAIN_MISMATCH), one COMMIT_BLOCKED');
SELECT is((SELECT ((b).inputs->'problems'->'missing')::text || '/' || ((b).policy_rationale LIKE '%status DEPRECATED at commit%FAO-GOV-001 audit chain incomplete')::text
             FROM (SELECT pg_temp.blocked(pg_temp.c('fB')) AS b) s),
  '["ETH"]/true', 'finalize DEPRECATED, broken chain: the missing asset evidence and both reasons are kept');

-- Review needed: no request is opened for a retired agent
INSERT INTO v VALUES ('xH', tests.finalize(pg_temp.c('fH')));
SELECT is(pg_temp.g('xH')->>'code' || '/' || (pg_temp.g('xH')->>'hitl_required') || '/' || coalesce(pg_temp.g('xH')->>'hitl_id', 'null'),
  'AGENT_NOT_ACTIVE/false/null', 'finalize DEPRECATED, review needed: AGENT_NOT_ACTIVE with no request id');
SELECT is((SELECT count(*) FROM public.hitl_queue WHERE correlation_id = pg_temp.c('fH')) || '/' || tests.ledger_count(pg_temp.c('fH'), 'HITL_REQUESTED')
          || '/' || pg_temp.summary(pg_temp.c('fH')),
  '0/0/FAILED/0/1', 'finalize DEPRECATED, review needed: no request, no HITL_REQUESTED, run FAILED with COMMIT_BLOCKED');
SELECT is(pg_temp.keys(pg_temp.g('xH')), pg_temp.keys(pg_temp.g('xA')), 'finalize: blocked envelopes share one key set');

-- ---------------------------------------------------------------------------
-- STUB_DOCUMENTED behaves the same
-- ---------------------------------------------------------------------------
SELECT pg_temp.set_status('STUB_DOCUMENTED');
INSERT INTO v VALUES ('dS1', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('hS1'), 'APPROVED'));
SELECT is(pg_temp.g('dS1')->>'code' || '/' || pg_temp.summary(pg_temp.rc('hS1')), 'AGENT_NOT_ACTIVE/FAILED/0/1',
  'decide STUB approve: AGENT_NOT_ACTIVE, run FAILED, COMMIT_BLOCKED, nothing COMMITTED');
SELECT is((SELECT (b).inputs->>'agent_status' FROM (SELECT pg_temp.blocked(pg_temp.rc('hS1')) AS b) s), 'STUB_DOCUMENTED',
  'decide STUB approve: COMMIT_BLOCKED names STUB_DOCUMENTED');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('hS1')) || '/' || tests.ledger_count(pg_temp.rc('hS1'), 'HITL_RESOLVED'),
  'APPROVED/1', 'decide STUB approve: the decision and HITL_RESOLVED stand');
INSERT INTO v VALUES ('dS2', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('hS2'), 'REJECTED'));
SELECT is(pg_temp.g('dS2')->>'code' || '/' || pg_temp.summary(pg_temp.rc('hS2'))
          || '/' || (SELECT status::text || '/' || hitl_status::text FROM public.shadow_ledger
                      WHERE correlation_id = pg_temp.rc('hS2') AND inputs->>'event_type' = 'COMMITTED'),
  'OK/COMMITTED/1/0/ROLLED_BACK/REJECTED', 'decide STUB reject: closes as COMMITTED ROLLED_BACK / REJECTED');
INSERT INTO v VALUES ('xS', tests.finalize(pg_temp.c('fS')));
SELECT is(pg_temp.g('xS')->>'code' || '/' || pg_temp.summary(pg_temp.c('fS'))
          || '/' || (SELECT (b).inputs->>'agent_status' FROM (SELECT pg_temp.blocked(pg_temp.c('fS')) AS b) s),
  'AGENT_NOT_ACTIVE/FAILED/0/1/STUB_DOCUMENTED', 'finalize STUB: AGENT_NOT_ACTIVE, COMMIT_BLOCKED names STUB_DOCUMENTED');

-- ---------------------------------------------------------------------------
-- Control: ACTIVE again, the same paths commit (the gate is not over-broad)
-- ---------------------------------------------------------------------------
SELECT pg_temp.set_status('ACTIVE');
INSERT INTO v VALUES ('dC', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('hC'), 'APPROVED'));
SELECT is(pg_temp.g('dC')->>'ok' || '/' || (pg_temp.g('dC')->>'code') || '/' || pg_temp.summary(pg_temp.rc('hC'))
          || '/' || (SELECT status::text FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('hC') AND inputs->>'event_type' = 'COMMITTED'),
  'true/OK/COMMITTED/1/0/SUCCESS', 'control: approval for an ACTIVE agent commits SUCCESS');
INSERT INTO v VALUES ('xC', tests.finalize(pg_temp.c('fC')));
SELECT is(pg_temp.g('xC')->>'ok' || '/' || (pg_temp.g('xC')->>'code') || '/' || (pg_temp.g('xC')->>'state') || '/' || pg_temp.summary(pg_temp.c('fC')),
  'true/OK/COMMITTED/COMMITTED/1/0', 'control: finalize for an ACTIVE agent commits');
SELECT is(pg_temp.keys(pg_temp.g('xC')), pg_temp.keys(pg_temp.g('xA')), 'finalize: the blocked and the OK envelopes have the same keys');

-- ---------------------------------------------------------------------------
-- Ordering against a concurrent status change: the share lock after the run
-- lock, before the rollup and every commit-side write
-- ---------------------------------------------------------------------------
SELECT matches(pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure),
  'WHERE ri\.correlation_id = v_req\.correlation_id\s+FOR UPDATE;.*FROM public\.agent_registry ar\s+WHERE ar\.agent_id = v_run\.agent_id\s+FOR SHARE;\s+r := fao_private\.run_rollup',
  'decide: the agent row is read FOR SHARE after the run lock and before the rollup');
SELECT matches(pg_get_functiondef('public.fao_run_finalize(uuid)'::regprocedure),
  'WHERE ri\.correlation_id = p_correlation_id\s+FOR UPDATE;.*FROM public\.agent_registry ar\s+WHERE ar\.agent_id = v_run\.agent_id\s+FOR SHARE;\s+r := fao_private\.run_rollup',
  'finalize: the agent row is read FOR SHARE after the run lock and before the rollup');
SELECT matches(pg_get_functiondef('public.fao_admin_set_agent(json)'::regprocedure),
  'FROM public\.agent_registry a\s+WHERE a\.agent_id = p_agent_id\s+FOR UPDATE',
  'fao_admin_set_agent locks the agent row FOR UPDATE, so it conflicts with the share lock');
SELECT ok(position('''COMMITTED''' IN substring(pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure) FROM 'FOR SHARE;(.*)$'))
          > position('AGENT_NOT_ACTIVE' IN substring(pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure) FROM 'FOR SHARE;(.*)$')),
  'decide: the status gate comes before the COMMITTED append');

-- A status change committed between the request and the decision is seen at
-- commit (the read-committed side of the race), for a second approver too
INSERT INTO v VALUES ('hY', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.set_status('DEPRECATED');
INSERT INTO v VALUES ('dY', tests.decide('marcus.patel@finagent-os.demo', pg_temp.id('hY'), 'APPROVED'));
SELECT is(pg_temp.g('dY')->>'code' || '/' || pg_temp.summary(pg_temp.rc('hY')), 'AGENT_NOT_ACTIVE/FAILED/0/1',
  'deprecated after the request: Marcus''s approval is AGENT_NOT_ACTIVE with COMMIT_BLOCKED');
SELECT is((SELECT count(*) FROM public.shadow_ledger
            WHERE inputs->>'event_type' = 'COMMITTED' AND status = 'SUCCESS'
              AND correlation_id IN (pg_temp.rc('hA'), pg_temp.rc('hR'), pg_temp.rc('hB'), pg_temp.rc('hS1'), pg_temp.rc('hS2'),
                                     pg_temp.rc('hC'), pg_temp.rc('hY'), pg_temp.c('fA'), pg_temp.c('fB'), pg_temp.c('fH'),
                                     pg_temp.c('fS'), pg_temp.c('fC'))), 2::bigint,
  'across every run here only the two ACTIVE controls committed SUCCESS');

SELECT * FROM finish();
ROLLBACK;
