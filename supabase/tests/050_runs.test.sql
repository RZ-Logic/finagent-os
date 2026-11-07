-- ============================================================================
-- FinAgent OS pgTAP 050: fao_run_start and fao_run_claim
-- Controls: FAO-GOV-008 (invoker from the session, idempotency, single-use
-- hashed run token), FAO-GOV-002 (registry status gate with a committed
-- RUN_REFUSED row), FAO-GOV-003 (rate limit), FAO-GOV-001 (journal).
-- ============================================================================
BEGIN;
SELECT plan(64);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE TEMP TABLE tokens (t text);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
-- Journal rows written by this file only (other layers may have committed rows).
INSERT INTO v VALUES ('start_id', to_jsonb(coalesce((SELECT max(refusal_id) FROM public.fao_refusal_journal), 0)));
CREATE FUNCTION pg_temp.since() RETURNS bigint LANGUAGE sql AS $$ SELECT (j::text)::bigint FROM v WHERE k = 'start_id' $$;

-- Input validation (400)
INSERT INTO v VALUES ('bad_agent', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'Bad-Agent', 'r', tests.new_key()));
INSERT INTO v VALUES ('empty_reason', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', '', tests.new_key()));
INSERT INTO v VALUES ('long_reason', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', repeat('r', 501), tests.new_key()));
INSERT INTO v VALUES ('ctrl_reason', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', E'r\u0007', tests.new_key()));
INSERT INTO v VALUES ('short_key', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'r', 'short'));
INSERT INTO v VALUES ('bad_key', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'r', 'abc def ghi'));
INSERT INTO v VALUES ('bad_via', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'r', tests.new_key(), 'web'));
SELECT is(pg_temp.g('bad_agent')->>'code', 'INVALID_INPUT', 'start: malformed agent id is INVALID_INPUT');
SELECT is(pg_temp.g('empty_reason')->>'code', 'INVALID_INPUT', 'start: empty reason is INVALID_INPUT');
SELECT is(pg_temp.g('long_reason')->>'code', 'INVALID_INPUT', 'start: reason over 500 characters is INVALID_INPUT');
SELECT is(pg_temp.g('ctrl_reason')->>'code', 'INVALID_INPUT', 'start: control characters in the reason are INVALID_INPUT');
SELECT is(pg_temp.g('short_key')->>'code', 'INVALID_INPUT', 'start: short idempotency key is INVALID_INPUT');
SELECT is(pg_temp.g('bad_key')->>'code', 'INVALID_INPUT', 'start: idempotency key with spaces is INVALID_INPUT');
SELECT is(pg_temp.g('bad_via')->>'code', 'INVALID_INPUT', 'start: unknown invoked_via is INVALID_INPUT');
SELECT is((pg_temp.g('bad_via')->>'http_status')::int, 400, 'INVALID_INPUT is 400');

-- 401, 403, 404
INSERT INTO v VALUES ('anon', tests.start_raw('anon', 'fao_reserve_recon_v1', 'r', tests.new_key()));
INSERT INTO v VALUES ('outsider', tests.start_raw('outsider@local.test', 'fao_reserve_recon_v1', 'r', tests.new_key()));
INSERT INTO v VALUES ('reader', tests.start_raw('mcp.reader@finagent-os.demo', 'fao_reserve_recon_v1', 'r', tests.new_key()));
INSERT INTO v VALUES ('marcus', tests.start_raw('marcus.patel@finagent-os.demo', 'fao_reserve_recon_v1', 'r', tests.new_key()));
INSERT INTO v VALUES ('unknown', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_no_such_agent', 'r', tests.new_key()));
SELECT is(pg_temp.g('anon')->>'code', 'NO_SESSION', 'start: anon gets NO_SESSION');
SELECT is((pg_temp.g('anon')->>'http_status')::int, 401, 'NO_SESSION is 401');
SELECT is(pg_temp.g('outsider')->>'code', 'NOT_AN_OWNER', 'start: Outsider gets NOT_AN_OWNER');
SELECT is(pg_temp.g('reader')->>'code', 'NOT_AN_OWNER', 'start: the reader gets NOT_AN_OWNER');
SELECT is((pg_temp.g('reader')->>'http_status')::int, 403, 'NOT_AN_OWNER is 403');
SELECT ok(pg_temp.g('reader')->>'ref' IS NOT NULL, 'the NOT_AN_OWNER refusal is journaled');
SELECT is(pg_temp.g('marcus')->>'code', 'NOT_AUTHORISED', 'start: Marcus (owner without the invoker role) gets NOT_AUTHORISED');
SELECT is(pg_temp.g('unknown')->>'code', 'UNKNOWN_AGENT', 'start: unknown agent gets UNKNOWN_AGENT');
SELECT is((pg_temp.g('unknown')->>'http_status')::int, 404, 'UNKNOWN_AGENT is 404');

-- 409 with a RUN_REFUSED row for STUB_DOCUMENTED and DEPRECATED agents
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 050 deprecate probe', true);
  UPDATE public.agent_registry SET status = 'DEPRECATED' WHERE agent_id = 'fao_treasury_monitor_v1';
END $$;
INSERT INTO v VALUES ('stub', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_close_orchestrator_v1', 'r', tests.new_key()));
INSERT INTO v VALUES ('deprecated', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_treasury_monitor_v1', 'r', tests.new_key()));
SELECT is(pg_temp.g('stub')->>'code', 'AGENT_NOT_ACTIVE', 'start: STUB_DOCUMENTED agent gets AGENT_NOT_ACTIVE');
SELECT is((pg_temp.g('stub')->>'http_status')::int, 409, 'AGENT_NOT_ACTIVE is 409');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE agent_id = 'fao_close_orchestrator_v1' AND inputs->>'event_type' = 'RUN_REFUSED'), 1::bigint, 'one RUN_REFUSED row for the stub agent');
SELECT is((SELECT policy_outcome::text || '/' || status::text || '/' || hitl_status::text FROM public.shadow_ledger WHERE agent_id = 'fao_close_orchestrator_v1' AND inputs->>'event_type' = 'RUN_REFUSED'),
  'DENY/FAILURE/NOT_REQUIRED', 'RUN_REFUSED is DENY, FAILURE, NOT_REQUIRED');
SELECT is((SELECT policy_rationale FROM public.shadow_ledger WHERE agent_id = 'fao_close_orchestrator_v1' AND inputs->>'event_type' = 'RUN_REFUSED'),
  'FAO-GOV-002 run refused: agent fao_close_orchestrator_v1 status STUB_DOCUMENTED', 'RUN_REFUSED rationale wording');
SELECT is((SELECT inputs->>'invoker_id' FROM public.shadow_ledger WHERE agent_id = 'fao_close_orchestrator_v1' AND inputs->>'event_type' = 'RUN_REFUSED'),
  tests.uid('aisha.okonkwo@finagent-os.demo')::text, 'RUN_REFUSED names the invoker from the session');
SELECT is(pg_temp.g('deprecated')->>'code', 'AGENT_NOT_ACTIVE', 'start: DEPRECATED agent gets AGENT_NOT_ACTIVE');
SELECT is((SELECT inputs->>'agent_status' FROM public.shadow_ledger WHERE agent_id = 'fao_treasury_monitor_v1' AND inputs->>'event_type' = 'RUN_REFUSED'),
  'DEPRECATED', 'RUN_REFUSED row for the deprecated agent');

-- 429 at max_runs_per_hour. The limit is set to 2 above the user's runs in
-- the last hour (committed runs from other layers), so the third new run is
-- the first one over the limit.
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 050 rate limit probe', true);
  UPDATE public.agent_registry SET max_runs_per_hour = 2 + (
    SELECT count(*) FROM public.run_invocations r
    WHERE r.invoker_id = tests.uid('ratelimit@local.test') AND r.agent_id = 'fao_ratelimit_test_v1'
      AND r.requested_at > fao_private.clock() - interval '1 hour')
  WHERE agent_id = 'fao_ratelimit_test_v1';
END $$;
INSERT INTO v VALUES ('rl1', tests.start_raw('ratelimit@local.test', 'fao_ratelimit_test_v1', 'r', tests.new_key()));
INSERT INTO v VALUES ('rl2', tests.start_raw('ratelimit@local.test', 'fao_ratelimit_test_v1', 'r', tests.new_key()));
INSERT INTO v VALUES ('rl3', tests.start_raw('ratelimit@local.test', 'fao_ratelimit_test_v1', 'r', tests.new_key()));
SELECT ok((pg_temp.g('rl1')->>'ok')::boolean AND (pg_temp.g('rl2')->>'ok')::boolean, 'the first two runs within the hour start');
SELECT is(pg_temp.g('rl3')->>'code', 'RATE_LIMITED', 'the third run within the hour is RATE_LIMITED');
SELECT is((pg_temp.g('rl3')->>'http_status')::int, 429, 'RATE_LIMITED is 429');

-- Success and the stored token
INSERT INTO v VALUES ('key1', to_jsonb(tests.new_key()));
INSERT INTO v VALUES ('s1', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'pgtap 050', pg_temp.g('key1')#>>'{}'));
INSERT INTO tokens SELECT pg_temp.g('s1')->>'run_token';
SELECT is(pg_temp.g('s1')->>'state', 'REQUESTED', 'start: new run is REQUESTED');
SELECT is(pg_temp.g('s1')->>'replayed', 'false', 'start: new run is not a replay');
SELECT matches(pg_temp.g('s1')->>'run_token', '^[A-Za-z0-9_-]{43}$', 'start: token is 43 URL-safe characters');
SELECT ok(pg_temp.g('s1')->>'token_expires_at' IS NOT NULL, 'start: token expiry returned');
SELECT is((SELECT invoker_id FROM public.run_invocations WHERE correlation_id = (pg_temp.g('s1')->>'correlation_id')::uuid), tests.uid('aisha.okonkwo@finagent-os.demo'), 'run records the invoker from the session');
SELECT is((SELECT invoked_via FROM public.run_invocations WHERE correlation_id = (pg_temp.g('s1')->>'correlation_id')::uuid), 'test', 'run records invoked_via');
SELECT is((SELECT token_hash FROM fao_private.run_tokens WHERE correlation_id = (pg_temp.g('s1')->>'correlation_id')::uuid),
  extensions.digest(pg_temp.g('s1')->>'run_token', 'sha256'), 'the token is stored only as its SHA-256 hash');

-- Replay with the same key
INSERT INTO v VALUES ('s1b', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'pgtap 050', pg_temp.g('key1')#>>'{}'));
INSERT INTO tokens SELECT pg_temp.g('s1b')->>'run_token';
SELECT is(pg_temp.g('s1b')->>'correlation_id', pg_temp.g('s1')->>'correlation_id', 'replay returns the same run');
SELECT is(pg_temp.g('s1b')->>'replayed', 'true', 'replay is marked replayed');
SELECT isnt(pg_temp.g('s1b')->>'run_token', pg_temp.g('s1')->>'run_token', 'replay while unclaimed issues a new token');
SELECT is((SELECT token_hash FROM fao_private.run_tokens WHERE correlation_id = (pg_temp.g('s1')->>'correlation_id')::uuid),
  extensions.digest(pg_temp.g('s1b')->>'run_token', 'sha256'), 'the stored hash is the new token''s');
INSERT INTO v VALUES ('claim_old', tests.claim_raw(pg_temp.g('s1')->>'run_token', 'pgtap-050-old'));
SELECT is(pg_temp.g('claim_old')->>'code', 'INVALID_TOKEN', 'the replaced token is no longer valid');
INSERT INTO v VALUES ('claim_new', tests.claim_raw(pg_temp.g('s1b')->>'run_token', 'pgtap-050-new'));
SELECT is(pg_temp.g('claim_new')->>'ok', 'true', 'the new token claims the run');
SELECT is(pg_temp.g('claim_new')->>'invoker_id', tests.uid('aisha.okonkwo@finagent-os.demo')::text, 'claim returns the invoker from the run');
INSERT INTO v VALUES ('s1c', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'pgtap 050', pg_temp.g('key1')#>>'{}'));
SELECT ok(pg_temp.g('s1c')->>'replayed' = 'true' AND pg_temp.g('s1c')->>'run_token' IS NULL, 'replay after the claim returns no token');
SELECT is(pg_temp.g('s1c')->>'state', 'RUNNING', 'replay after the claim reports RUNNING');
INSERT INTO v VALUES ('s1d', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_ratelimit_test_v1', 'pgtap 050', pg_temp.g('key1')#>>'{}'));
SELECT is(pg_temp.g('s1d')->>'code', 'INVALID_INPUT', 'the same key for a different agent is INVALID_INPUT');

-- Claim refusals
INSERT INTO v VALUES ('claim_second', tests.claim_raw(pg_temp.g('s1b')->>'run_token', 'pgtap-050-second'));
INSERT INTO v VALUES ('claim_malformed', tests.claim_raw('short', 'pgtap-050-x'));
INSERT INTO v VALUES ('claim_bad_exec', tests.claim_raw(repeat('a', 43), 'bad exec id!'));
INSERT INTO v VALUES ('claim_unknown', tests.claim_raw(repeat('Q', 43), 'pgtap-050-unknown'));
SELECT is(pg_temp.g('claim_second')->>'code', 'ALREADY_CLAIMED', 'claim: second claim is ALREADY_CLAIMED');
SELECT is((pg_temp.g('claim_second')->>'http_status')::int, 409, 'ALREADY_CLAIMED is 409');
SELECT is(pg_temp.g('claim_malformed')->>'code', 'INVALID_INPUT', 'claim: malformed token is INVALID_INPUT');
SELECT is((pg_temp.g('claim_malformed')->>'http_status')::int, 400, 'claim INVALID_INPUT is 400');
SELECT is(pg_temp.g('claim_bad_exec')->>'code', 'INVALID_INPUT', 'claim: malformed execution id is INVALID_INPUT');
SELECT is(pg_temp.g('claim_unknown')->>'code', 'INVALID_TOKEN', 'claim: unknown token is INVALID_TOKEN');
SELECT is((pg_temp.g('claim_unknown')->>'http_status')::int, 401, 'INVALID_TOKEN is 401');

-- Expired token on claim (410) and on replay (EXPIRED)
INSERT INTO v VALUES ('s2', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'pgtap 050 expiry', tests.new_key()));
INSERT INTO tokens SELECT pg_temp.g('s2')->>'run_token';
INSERT INTO v VALUES ('key3', to_jsonb(tests.new_key()));
INSERT INTO v VALUES ('s3', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'pgtap 050 replay expiry', pg_temp.g('key3')#>>'{}'));
INSERT INTO tokens SELECT pg_temp.g('s3')->>'run_token';
SELECT tests.set_clock(700);
INSERT INTO v VALUES ('claim_expired', tests.claim_raw(pg_temp.g('s2')->>'run_token', 'pgtap-050-expired'));
INSERT INTO v VALUES ('s3b', tests.start_raw('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', 'pgtap 050 replay expiry', pg_temp.g('key3')#>>'{}'));
SELECT tests.set_clock(0);
SELECT is(pg_temp.g('claim_expired')->>'code', 'TOKEN_EXPIRED', 'claim: expired token is TOKEN_EXPIRED');
SELECT is((pg_temp.g('claim_expired')->>'http_status')::int, 410, 'TOKEN_EXPIRED is 410');
SELECT is(tests.run_state((pg_temp.g('s2')->>'correlation_id')::uuid), 'EXPIRED', 'the run with the expired token is EXPIRED');
SELECT is(pg_temp.g('s3b')->>'state', 'EXPIRED', 'replay of an expired unclaimed run reports EXPIRED');
SELECT ok(pg_temp.g('s3b')->>'replayed' = 'true' AND pg_temp.g('s3b')->>'run_token' IS NULL, 'replay of an expired run issues no token');
SELECT is(tests.run_state((pg_temp.g('s3')->>'correlation_id')::uuid), 'EXPIRED', 'the replayed expired run is EXPIRED');

-- Claim refusals are journaled without the token
SELECT is((SELECT count(*) FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND entry_point = 'rpc:fao_run_claim'), 6::bigint,
  'six claim refusals are journaled');
SELECT is_empty($$SELECT 1 FROM public.fao_refusal_journal j JOIN tokens t ON j.attempted::text LIKE '%' || t.t || '%' OR coalesce(j.target_key, '') LIKE '%' || t.t || '%'$$,
  'no journal row holds a run token');
SELECT ok((SELECT bool_and(attempted ? 'n8n_execution_id') FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND entry_point = 'rpc:fao_run_claim'),
  'claim refusals record the execution id attempted');
SELECT is_empty($$SELECT 1 FROM public.shadow_ledger l JOIN tokens t ON l.inputs::text LIKE '%' || t.t || '%'$$,
  'no ledger row holds a run token');
SELECT is_empty($$SELECT 1 FROM public.run_invocations r JOIN tokens t ON to_jsonb(r)::text LIKE '%' || t.t || '%'$$,
  'no run record holds a run token');
SELECT is((SELECT length(token_hash) FROM fao_private.run_tokens WHERE correlation_id = (pg_temp.g('s2')->>'correlation_id')::uuid), 32,
  'token_hash is a 32-byte digest');

SELECT * FROM finish();
ROLLBACK;
