-- ============================================================================
-- FinAgent OS pgTAP 142: fix round 2, database core (runs, claim, ledger)
-- Controls:
--   FAO-GOV-004 (R03): a token issued before the invoker role was revoked, or
--     the owner deactivated, is refused at claim (NOT_AUTHORISED) and the run
--     expires.
--   FAO-GOV-002 (R04): an idempotency replay issues no new token once the
--     agent is not ACTIVE (AGENT_NOT_ACTIVE, run EXPIRED); claim refuses an
--     agent that is not ACTIVE; finalize raises for one.
--   FAO-GOV-001 (R05): ASSET_RECONCILED status agrees with the outcome.
--   FAO-GOV-008 (R06): claim locks the run row before the token row and
--     checks the hash again; a token rotated by a replay is INVALID_TOKEN.
--   FAO-GOV-001 (R07): every inputs key the database writes on some event
--     type is refused in Writer inputs, except the STARTED and FAILED
--     overwrites.
--   FAO-GOV-008 (R08): a token is claimed only by its own agent's workflow.
--   FAO-GOV-008 (R09): n8n execution ids are unique only among RUNNING runs;
--     fao_run_fail resolves an id to the unfinished run.
--   FAO-GOV-004 (R31): a legacy PENDING request with tier BLOCKED is closed
--     at cutover; the tier CHECK is added after the closure.
--   FAO-GOV-001 (R33): the 0010 column additions re-apply on a database that
--     already has the columns a rollback keeps.
-- The destructive cases (role revoked, owner deactivated, agent deprecated,
-- user triggers disabled) come last so earlier cases do not depend on them.
-- ============================================================================
BEGIN;
SELECT plan(73);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j->>'correlation_id')::uuid FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.tok(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT j->>'run_token' FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.since() RETURNS bigint LANGUAGE sql AS $$ SELECT (j::text)::bigint FROM v WHERE k = 'start_id' $$;
CREATE FUNCTION pg_temp.jcount(p_code text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.fao_refusal_journal
   WHERE refusal_id > pg_temp.since() AND entry_point = 'rpc:fao_run_claim' AND code = p_code $$;
CREATE FUNCTION pg_temp.append_err(p_events jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)', p_events)) $$;
CREATE FUNCTION pg_temp.fail(p_exec text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format('SELECT public.fao_run_fail(%L, %L, %L)', p_exec, 'Claim Run', 'pgtap 142')) $$;
CREATE FUNCTION pg_temp.consumed(p_corr uuid) RETURNS boolean LANGUAGE sql AS $$
  SELECT consumed_at IS NOT NULL FROM fao_private.run_tokens WHERE correlation_id = p_corr $$;
-- An asset event with a chosen status, or with extra inputs keys
CREATE FUNCTION pg_temp.asset_st(p_corr uuid, p_asset text, p_outcome text, p_status text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.asset_event(p_corr, p_asset, p_outcome) || jsonb_build_object('status', p_status) $$;
CREATE FUNCTION pg_temp.asset_kv(p_corr uuid, p_asset text, p_extra jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(tests.asset_event(p_corr, p_asset), '{inputs}', (tests.asset_event(p_corr, p_asset)->'inputs') || p_extra) $$;

INSERT INTO v VALUES ('start_id', to_jsonb((SELECT coalesce(max(refusal_id), 0) FROM public.fao_refusal_journal)));

-- Room in the per-hour rate limits for the runs below, whatever other layers
-- committed in the last hour.
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 142 rate limits', true);
  UPDATE public.agent_registry SET max_runs_per_hour = 60 WHERE agent_id IN ('fao_reserve_recon_v1', 'fao_ratelimit_test_v1');
END $$;

-- ============================================================================
-- R08: a token is claimed only by its own agent's workflow
-- ============================================================================
INSERT INTO v VALUES ('r8', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1'));
SELECT is(pg_temp.g('r8')->>'code', 'OK', 'R08: ratelimit@local.test starts a run for fao_ratelimit_test_v1');
INSERT INTO v VALUES ('r8_wrong', tests.claim_agent_raw(pg_temp.tok('r8'), 'pgtap-142-r8a', 'fao_reserve_recon_v1'));
SELECT is(pg_temp.g('r8_wrong')->>'code' || '/' || (pg_temp.g('r8_wrong')->>'http_status'), 'INVALID_TOKEN/401',
  'R08: the flagship workflow cannot claim a token issued for another agent (INVALID_TOKEN 401)');
SELECT is(tests.run_state(pg_temp.c('r8')), 'REQUESTED', 'R08: the run stays REQUESTED after the mismatch');
SELECT is(pg_temp.consumed(pg_temp.c('r8')), false, 'R08: the token is not consumed by the mismatch');
SELECT ok(EXISTS (SELECT 1 FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND entry_point = 'rpc:fao_run_claim'
                   AND code = 'INVALID_TOKEN' AND attempted->>'agent_id' = 'fao_reserve_recon_v1' AND target_key IS NULL),
  'R08: the mismatch is journaled with the agent attempted and no run key');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND attempted::text LIKE '%' || pg_temp.tok('r8') || '%'),
  'R08: the journal never holds the token');
INSERT INTO v VALUES ('r8_bad_agent', tests.claim_agent_raw(pg_temp.tok('r8'), 'pgtap-142-r8b', 'Not An Agent'));
SELECT is(pg_temp.g('r8_bad_agent')->>'code', 'INVALID_INPUT', 'R08: a malformed agent id is INVALID_INPUT');
INSERT INTO v VALUES ('r8_null_agent', tests.claim_agent_raw(pg_temp.tok('r8'), 'pgtap-142-r8c', NULL));
SELECT is(pg_temp.g('r8_null_agent')->>'code', 'INVALID_INPUT', 'R08: a NULL agent id is INVALID_INPUT');
INSERT INTO v VALUES ('r8_ok', tests.claim_agent_raw(pg_temp.tok('r8'), 'pgtap-142-r8d', 'fao_ratelimit_test_v1'));
SELECT is(pg_temp.g('r8_ok')->>'code' || '/' || (pg_temp.g('r8_ok')->>'agent_id'), 'OK/fao_ratelimit_test_v1',
  'R08: the token''s own agent workflow claims it');

-- ============================================================================
-- R06: run row before token row; a token rotated by a replay is refused
-- ============================================================================
INSERT INTO v VALUES ('k6', to_jsonb(tests.new_key()));
INSERT INTO v VALUES ('r6a', tests.start_run('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', pg_temp.g('k6')#>>'{}'));
INSERT INTO v VALUES ('r6b', tests.start_run('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', pg_temp.g('k6')#>>'{}'));
SELECT is((pg_temp.g('r6b')->>'replayed')::boolean AND pg_temp.c('r6a') = pg_temp.c('r6b')
          AND pg_temp.tok('r6a') <> pg_temp.tok('r6b'), true, 'R06: the replay rotates the token of the same run');
SELECT is(tests.claim_raw(pg_temp.tok('r6a'), 'pgtap-142-r6a')->>'code', 'INVALID_TOKEN', 'R06: the token replaced by the replay is INVALID_TOKEN');
SELECT is(tests.run_state(pg_temp.c('r6a')), 'REQUESTED', 'R06: the run stays REQUESTED');
SELECT is(tests.claim_raw(pg_temp.tok('r6b'), 'pgtap-142-r6b')->>'code', 'OK', 'R06: the current token claims the run');
SELECT matches(pg_get_functiondef('public.fao_run_claim(text,text,text)'::regprocedure),
  'FROM public\.run_invocations ri\s+WHERE ri\.correlation_id = v_corr\s+FOR UPDATE;\s+SELECT \* INTO v_tok\s+FROM fao_private\.run_tokens t\s+WHERE t\.correlation_id = v_corr\s+FOR UPDATE',
  'R06: fao_run_claim locks the run row, then the token row (the replay order)');
SELECT matches(pg_get_functiondef('public.fao_run_start(json)'::regprocedure),
  'WHERE ri\.invoker_id = v_uid\s+AND ri\.idempotency_key = p_idempotency_key\s+FOR UPDATE;.*FROM fao_private\.run_tokens t\s+WHERE t\.correlation_id = v_run\.correlation_id\s+FOR UPDATE',
  'R06: the fao_run_start replay locks the run row, then the token row');

-- ============================================================================
-- R09: execution ids unique only among RUNNING runs
-- ============================================================================
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.run_invocations'::regclass AND contype = 'u'
                       AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'public.run_invocations'::regclass AND attname = 'n8n_execution_id')]),
  'R09: no table-wide UNIQUE on run_invocations.n8n_execution_id');
SELECT is((SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indexrelid = 'public.run_invocations_running_execution_key'::regclass),
  'CREATE UNIQUE INDEX run_invocations_running_execution_key ON public.run_invocations USING btree (n8n_execution_id) WHERE (state = ''RUNNING''::fao_run_state)',
  'R09: the execution id is unique among RUNNING runs');
-- Run A claims X and commits.
INSERT INTO v VALUES ('r9a', tests.start_run('aisha.okonkwo@finagent-os.demo'));
SELECT is(tests.claim_raw(pg_temp.tok('r9a'), 'pgtap-142-x')->>'code', 'OK', 'R09: run A claims execution id X');
SELECT is(tests.append(jsonb_build_array(tests.started_event(pg_temp.c('r9a'), ARRAY['BTC']), tests.asset_event(pg_temp.c('r9a'), 'BTC')))->>'ok', 'true', 'R09: run A records STARTED and BTC');
SELECT is(tests.finalize(pg_temp.c('r9a'))->>'state', 'COMMITTED', 'R09: run A commits');
-- A new n8n database numbers from 1 again: run B claims the same id.
INSERT INTO v VALUES ('r9b', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('r9b_claim', tests.claim_raw(pg_temp.tok('r9b'), 'pgtap-142-x'));
SELECT is(pg_temp.g('r9b_claim')->>'code', 'OK', 'R09: run B claims X once run A has finished (a reused n8n execution id)');
-- While B is RUNNING, a third claim with X is refused and changes nothing.
INSERT INTO v VALUES ('r9c', tests.start_run('aisha.okonkwo@finagent-os.demo'));
SELECT is(tests.claim_raw(pg_temp.tok('r9c'), 'pgtap-142-x')->>'code', 'ALREADY_CLAIMED', 'R09: X is refused while a RUNNING run holds it');
SELECT is(tests.run_state(pg_temp.c('r9c')) || '/' || pg_temp.consumed(pg_temp.c('r9c'))::text, 'REQUESTED/false',
  'R09: the refused run stays REQUESTED with its token unconsumed');
-- fao_run_fail(X) reaches B, not the committed A.
INSERT INTO v VALUES ('r9_fail', pg_temp.fail('pgtap-142-x'));
SELECT is((pg_temp.g('r9_fail')->>'correlation_id')::uuid, pg_temp.c('r9b'), 'R09: fao_run_fail resolves X to the RUNNING run B');
SELECT is(tests.run_state(pg_temp.c('r9b')) || '/' || tests.run_state(pg_temp.c('r9a')), 'FAILED/COMMITTED', 'R09: B fails; A is untouched');
SELECT is(tests.ledger_count(pg_temp.c('r9a'), 'FAILED'), 0::bigint, 'R09: no FAILED event on the committed run A');
SELECT is(pg_temp.fail('pgtap-142-x')->>'code', 'ALREADY_TERMINAL', 'R09: with every holder finished, X answers ALREADY_TERMINAL');
-- An AWAITING_HITL run keeps its id; a later RUNNING holder is preferred.
INSERT INTO v VALUES ('r9d', tests.start_run('aisha.okonkwo@finagent-os.demo'));
SELECT is(tests.claim_raw(pg_temp.tok('r9d'), 'pgtap-142-y')->>'code', 'OK', 'R09: run D claims Y');
SELECT is(tests.append(jsonb_build_array(tests.started_event(pg_temp.c('r9d'), ARRAY['USDT']), tests.asset_event(pg_temp.c('r9d'), 'USDT', 'REQUIRE_HUMAN', 'STANDARD')))->>'ok', 'true', 'R09: run D records a review asset');
SELECT is(tests.finalize(pg_temp.c('r9d'))->>'state', 'AWAITING_HITL', 'R09: run D waits for review');
INSERT INTO v VALUES ('r9e', tests.start_run('aisha.okonkwo@finagent-os.demo'));
SELECT is(tests.claim_raw(pg_temp.tok('r9e'), 'pgtap-142-y')->>'code', 'OK', 'R09: run E claims Y while D (AWAITING_HITL) keeps it');
SELECT is((pg_temp.fail('pgtap-142-y')->>'correlation_id')::uuid, pg_temp.c('r9e'), 'R09: fao_run_fail resolves Y to the RUNNING holder E');
SELECT is(tests.ledger_count(pg_temp.c('r9d'), 'FAILED'), 0::bigint,
  'R09: no FAILED event on the AWAITING_HITL run D');
SELECT is((pg_temp.fail('pgtap-142-y')->>'correlation_id')::uuid, pg_temp.c('r9d'), 'R09: with E finished, Y resolves to the unfinished run D');

-- ============================================================================
-- R05: ASSET_RECONCILED status agrees with the outcome
-- ============================================================================
INSERT INTO v VALUES ('r5', jsonb_build_object('correlation_id', tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC', 'ETH', 'SOL', 'XRP', 'ADA'])));
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.asset_st(pg_temp.c('r5'), 'BTC', 'ALLOW', 'FAILURE'))),
  'ALLOW and ALLOW_WITH_OBLIGATIONS need status SUCCESS', 'R05: ALLOW with status FAILURE is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.asset_st(pg_temp.c('r5'), 'BTC', 'ALLOW_WITH_OBLIGATIONS', 'FAILURE'))),
  'ALLOW and ALLOW_WITH_OBLIGATIONS need status SUCCESS', 'R05: ALLOW_WITH_OBLIGATIONS with status FAILURE is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.asset_st(pg_temp.c('r5'), 'BTC', 'ALLOW', 'ROLLED_BACK'))),
  'ASSET_RECONCILED status must be SUCCESS or FAILURE', 'R05: status ROLLED_BACK is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.asset_st(pg_temp.c('r5'), 'BTC', 'BLOCKED', 'PARTIAL'))),
  'ASSET_RECONCILED status must be SUCCESS or FAILURE', 'R05: status PARTIAL is refused, even with BLOCKED');
SELECT is(tests.ledger_count(pg_temp.c('r5'), 'ASSET_RECONCILED'), 0::bigint, 'R05: nothing was stored by the refused batches');
SELECT is(tests.append(jsonb_build_array(
            pg_temp.asset_st(pg_temp.c('r5'), 'BTC', 'BLOCKED', 'FAILURE'),
            pg_temp.asset_st(pg_temp.c('r5'), 'ETH', 'REQUIRE_HUMAN', 'FAILURE'),
            pg_temp.asset_st(pg_temp.c('r5'), 'SOL', 'ALLOW', 'SUCCESS')))->>'ok', 'true',
  'R05: BLOCKED and REQUIRE_HUMAN with FAILURE, and ALLOW with SUCCESS, are accepted');

-- ============================================================================
-- R07: database-only inputs keys are refused in Writer inputs
-- ============================================================================
CREATE TEMP TABLE r7 (k text, err text);
INSERT INTO r7 SELECT k, pg_temp.append_err(jsonb_build_array(pg_temp.asset_kv(pg_temp.c('r5'), 'XRP', jsonb_build_object(k, 'x'))))
  FROM unnest(ARRAY['source', 'stage', 'failed_node', 'n8n_execution_id', 'approval_url', 'timeout_at', 'expired_at',
                    'sub_tier', 'configured_approvals', 'enforced_approvals', 'escalated_assets', 'notification_channel',
                    'slack_channel_id', 'per_asset_summary', 'counts', 'problems', 'code', 'agent_status',
                    'decision_notes', 'committed_ledger_id', 'corrects_ledger_id', 'kind', 'level', 'attempt']) AS k;
SELECT is((SELECT count(*) FROM r7 WHERE err LIKE '%item 0: inputs.' || k || ' is set only by the database%'), 24::bigint,
  'R07: each of the 24 database-only keys on ASSET_RECONCILED is refused by name');
SELECT is(tests.ledger_count(pg_temp.c('r5'), 'ASSET_RECONCILED'), 3::bigint, 'R07: nothing was stored by the refused batches');
SELECT is(tests.append(jsonb_build_array(pg_temp.asset_kv(pg_temp.c('r5'), 'XRP', '{"wallet_source": "x", "note": "free"}'::jsonb)))->>'ok', 'true',
  'R07: Writer keys outside the reserved list are still accepted');
-- STARTED: source refused; n8n_execution_id overwritten from the run record
INSERT INTO v VALUES ('r7s', tests.start_run('aisha.okonkwo@finagent-os.demo'));
SELECT is(tests.claim_raw(pg_temp.tok('r7s'), 'pgtap-142-r7s')->>'code', 'OK', 'R07: a run for the STARTED cases');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('r7s'), ARRAY['BTC']), '{inputs,source}', '"sweep"'))),
  'inputs\.source is set only by the database', 'R07: STARTED with inputs.source is refused');
SELECT is(tests.append(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('r7s'), ARRAY['BTC']), '{inputs,n8n_execution_id}', '"forged"'))) ->>'ok', 'true',
  'R07: STARTED may carry n8n_execution_id');
SELECT is((SELECT inputs->>'n8n_execution_id' FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('r7s') AND inputs->>'event_type' = 'STARTED'),
  'pgtap-142-r7s', 'R07: the STARTED n8n_execution_id is overwritten from the run record');
-- A Writer FAILED keeps its overwrites; other reserved keys are refused
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_build_object('correlation_id', pg_temp.c('r7s'), 'event_type', 'FAILED',
                 'inputs', jsonb_build_object('failed_node', 'Writer', 'approval_url', 'https://evil.example/'),
                 'policy_outcome', 'BLOCKED', 'policy_rationale', 'pgtap 142 failed', 'status', 'FAILURE'))),
  'inputs\.approval_url is set only by the database', 'R07: a Writer FAILED with approval_url is refused');
SELECT is(tests.append(jsonb_build_array(jsonb_build_object('correlation_id', pg_temp.c('r7s'), 'event_type', 'FAILED',
            'inputs', jsonb_build_object('failed_node', 'Writer', 'source', 'sweep', 'stage', 'after_request', 'n8n_execution_id', 'forged'),
            'policy_outcome', 'BLOCKED', 'policy_rationale', 'pgtap 142 failed', 'status', 'FAILURE')))->>'ok', 'true',
  'R07: a Writer FAILED may carry failed_node, source, stage and n8n_execution_id');
SELECT is((SELECT (inputs->>'failed_node') || '/' || (inputs->>'source') || '/' || (inputs->>'stage') || '/' || (inputs->>'n8n_execution_id')
             FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('r7s') AND inputs->>'event_type' = 'FAILED'),
  'Writer/writer/before_request/pgtap-142-r7s', 'R07: the Writer FAILED keeps failed_node; source, stage and execution id come from the database');

-- ============================================================================
-- R04: the registry status gate holds at replay, claim and finalize
-- ============================================================================
INSERT INTO v VALUES ('k4', to_jsonb(tests.new_key()));
INSERT INTO v VALUES ('r4a', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.g('k4')#>>'{}'));
INSERT INTO v VALUES ('r4b', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1'));
INSERT INTO v VALUES ('r4c', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1'));
SELECT is(tests.claim_raw(pg_temp.tok('r4c'), 'pgtap-142-r4c')->>'code', 'OK', 'R04: run C is claimed while the agent is ACTIVE');
SELECT is(tests.append(jsonb_build_array(tests.started_event(pg_temp.c('r4c'), ARRAY['BTC']), tests.asset_event(pg_temp.c('r4c'), 'BTC')))->>'ok', 'true',
  'R04: run C records an all-ALLOW scope');
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 142 deprecate', true);
  UPDATE public.agent_registry SET status = 'DEPRECATED' WHERE agent_id = 'fao_ratelimit_test_v1';
END $$;
INSERT INTO v VALUES ('r4a_replay', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.g('k4')#>>'{}'));
SELECT is(pg_temp.g('r4a_replay')->>'code' || '/' || (pg_temp.g('r4a_replay')->>'http_status'), 'AGENT_NOT_ACTIVE/409',
  'R04: a replay after the agent was deprecated is AGENT_NOT_ACTIVE (409)');
SELECT ok(NOT (pg_temp.g('r4a_replay') ? 'run_token'), 'R04: the refused replay returns no token');
SELECT is(tests.run_state(pg_temp.c('r4a')), 'EXPIRED', 'R04: the replayed run expires');
SELECT is(tests.claim_raw(pg_temp.tok('r4a'), 'pgtap-142-r4a')->>'code', 'ALREADY_CLAIMED', 'R04: the expired run''s old token cannot be claimed');
INSERT INTO v VALUES ('r4b_claim', tests.claim_raw(pg_temp.tok('r4b'), 'pgtap-142-r4b'));
SELECT is(pg_temp.g('r4b_claim')->>'code' || '/' || (pg_temp.g('r4b_claim')->>'http_status'), 'AGENT_NOT_ACTIVE/409',
  'R04: a claim after the agent was deprecated is AGENT_NOT_ACTIVE (409)');
SELECT is(tests.run_state(pg_temp.c('r4b')) || '/' || pg_temp.consumed(pg_temp.c('r4b'))::text, 'EXPIRED/false',
  'R04: the refused claim expires the run and leaves the token unconsumed');
SELECT is(pg_temp.jcount('AGENT_NOT_ACTIVE'), 1::bigint, 'R04: the refused claim is journaled');
SELECT throws_matching(format('SELECT tests.finalize(%L::uuid)', pg_temp.c('r4c')), 'agent fao_ratelimit_test_v1 is not ACTIVE',
  'R04: finalize of an all-ALLOW run raises once the agent is not ACTIVE');
SELECT is(tests.run_state(pg_temp.c('r4c')) || '/' || tests.ledger_count(pg_temp.c('r4c'), 'COMMITTED')::text, 'RUNNING/0',
  'R04: nothing is committed; the run stays RUNNING for the sweep');

-- ============================================================================
-- R03: revoked or deactivated invokers' tokens are refused at claim
-- ============================================================================
INSERT INTO v VALUES ('r3a', tests.start_run('sarah.chen@finagent-os.demo'));
INSERT INTO v VALUES ('r3b', tests.start_run('aisha.okonkwo@finagent-os.demo'));
SELECT is((pg_temp.g('r3a')->>'ok')::boolean AND (pg_temp.g('r3b')->>'ok')::boolean, true, 'R03: Sarah and Aisha each hold a token');
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 142 revoke invoker', true);
  UPDATE public.fao_user_roles SET revoked_at = now()
   WHERE user_id = tests.uid('sarah.chen@finagent-os.demo') AND role = 'invoker' AND revoked_at IS NULL;
  PERFORM set_config('fao.change_reason', 'pgtap 142 deactivate owner', true);
  UPDATE public.process_owners SET active = false WHERE id = tests.uid('aisha.okonkwo@finagent-os.demo');
END $$;
INSERT INTO v VALUES ('r3a_claim', tests.claim_raw(pg_temp.tok('r3a'), 'pgtap-142-r3a'));
SELECT is(pg_temp.g('r3a_claim')->>'code' || '/' || (pg_temp.g('r3a_claim')->>'http_status'), 'NOT_AUTHORISED/403',
  'R03: a token issued before the invoker role was revoked is NOT_AUTHORISED (403)');
SELECT is(tests.run_state(pg_temp.c('r3a')) || '/' || pg_temp.consumed(pg_temp.c('r3a'))::text, 'EXPIRED/false',
  'R03: the run expires; the token is not consumed');
INSERT INTO v VALUES ('r3b_claim', tests.claim_raw(pg_temp.tok('r3b'), 'pgtap-142-r3b'));
SELECT is(pg_temp.g('r3b_claim')->>'code', 'NOT_AUTHORISED', 'R03: a token issued before the owner was deactivated is NOT_AUTHORISED');
SELECT is(tests.run_state(pg_temp.c('r3b')), 'EXPIRED', 'R03: the deactivated owner''s run expires');
SELECT is(pg_temp.jcount('NOT_AUTHORISED'), 2::bigint, 'R03: both refusals are journaled');

-- ============================================================================
-- R31: a legacy PENDING request with tier BLOCKED is closed at cutover
-- ============================================================================
-- Mirrors 0013 (see 130): the CHECK does not exist yet when the closure runs,
-- and the user triggers are off for this transaction only.
ALTER TABLE public.hitl_queue DROP CONSTRAINT hitl_tier_not_blocked;
ALTER TABLE public.hitl_queue DISABLE TRIGGER USER;
INSERT INTO v VALUES ('r31_corr', to_jsonb(gen_random_uuid()));
INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, sub_tier, policy_rationale, timeout_at)
VALUES ((pg_temp.g('r31_corr')#>>'{}')::uuid, 'fao_reserve_recon_v1', tests.uid('marcus.patel@finagent-os.demo'), 'BLOCKED', 'CRITICAL',
        'v1 pending blocked tier', now() - interval '1 hour');
INSERT INTO v VALUES ('r31_closed', to_jsonb(fao_private.close_legacy_requests()));
ALTER TABLE public.hitl_queue ENABLE TRIGGER USER;
SELECT is((pg_temp.g('r31_closed')::text)::int, 1, 'R31: the legacy PENDING BLOCKED request is closed');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE correlation_id = (pg_temp.g('r31_corr')#>>'{}')::uuid), 'EXPIRED',
  'R31: it is EXPIRED with its BLOCKED tier kept as recorded');
SELECT lives_ok($$ALTER TABLE public.hitl_queue ADD CONSTRAINT hitl_tier_not_blocked CHECK (risk_tier <> 'BLOCKED') NOT VALID$$,
  'R31: the tier CHECK is added after the closure, as 0013 does');
ALTER TABLE public.hitl_queue DISABLE TRIGGER USER;
INSERT INTO v VALUES ('r31_new', to_jsonb(tests.error_as('owner', format(
  $$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, sub_tier, policy_rationale, timeout_at)
    VALUES (%L, 'fao_reserve_recon_v1', %L, 'BLOCKED', 'CRITICAL', 'new blocked tier', now() + interval '1 hour')$$,
  gen_random_uuid(), tests.uid('marcus.patel@finagent-os.demo')))));
ALTER TABLE public.hitl_queue ENABLE TRIGGER USER;
SELECT matches(pg_temp.g('r31_new')#>>'{}', '^23514 .*hitl_tier_not_blocked', 'R31: the tier CHECK still refuses a new BLOCKED request (guards off, so only the CHECK applies)');

-- ============================================================================
-- R33: the 0010 column additions re-apply after a rollback
-- ============================================================================
SELECT lives_ok($$
  ALTER TABLE public.process_owners ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;
  ALTER TABLE public.agent_registry ADD COLUMN IF NOT EXISTS max_runs_per_hour int NOT NULL DEFAULT 6
    CONSTRAINT agent_max_runs_per_hour_range CHECK (max_runs_per_hour BETWEEN 1 AND 60);
  ALTER TABLE public.hitl_queue
    ADD COLUMN IF NOT EXISTS configured_approvals int   NOT NULL DEFAULT 1 CHECK (configured_approvals >= 1),
    ADD COLUMN IF NOT EXISTS enforced_approvals   int   NOT NULL DEFAULT 1 CHECK (enforced_approvals >= 1),
    ADD COLUMN IF NOT EXISTS approval_url         text,
    ADD COLUMN IF NOT EXISTS escalated_assets     jsonb NOT NULL DEFAULT '[]'::jsonb;
  ALTER TABLE public.shadow_ledger
    ADD COLUMN IF NOT EXISTS corrects_ledger_id bigint NULL REFERENCES public.shadow_ledger(ledger_id) ON DELETE RESTRICT;
  ALTER TABLE public.hitl_queue DROP CONSTRAINT IF EXISTS hitl_decision_coherence;
  ALTER TABLE public.hitl_queue ADD CONSTRAINT hitl_decision_coherence CHECK (
    (decision = 'PENDING' AND approver_id IS NULL AND decided_at IS NULL)
    OR (decision IN ('APPROVED','REJECTED') AND approver_id IS NOT NULL AND decided_at IS NOT NULL)
    OR (decision = 'EXPIRED' AND approver_id IS NULL AND decided_at IS NOT NULL));
$$, 'R33: the 0010 column and coherence statements re-apply where the columns a rollback keeps exist');
SELECT is((SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.hitl_queue'::regclass AND contype = 'c'
            AND pg_get_constraintdef(oid) IN ('CHECK ((configured_approvals >= 1))', 'CHECK ((enforced_approvals >= 1))')), 2::bigint,
  'R33: re-applying adds no second copy of the column CHECKs');

SELECT * FROM finish();
ROLLBACK;
