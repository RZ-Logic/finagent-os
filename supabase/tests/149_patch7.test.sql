-- ============================================================================
-- FinAgent OS pgTAP 149: patch round 7, run and ledger RPCs
-- Controls:
--   FAO-GOV-001, FAO-GOV-004 (O3, owner decision 2026-11-08): a STARTED
--     event whose inputs carry invoker_id, invoked_via, reason or
--     n8n_execution_id (at any depth, in any normalised spelling) is refused
--     and nothing is written; the database still sets the four values on
--     STARTED from the run record.
--   FAO-GOV-001 (L1): an inputs key holding a bidi isolate, a variation
--     selector, a tag character, a Hangul filler, the Braille blank or a
--     Mongolian selector is refused at any depth. A letter from another
--     script that looks Latin is an ordinary Writer key: it is stored beside
--     the real key and replaces nothing (KNOWN-LIMITS U17).
--   FAO-GOV-003 (L4): the run start rate limit counts run starts and EXPIRED
--     replay refusals in real time (now()); moving the test clock neither
--     empties nor frees the window, and rows older than an hour of real time
--     are not counted.
-- Characters are built with chr() so the file holds no escapes.
-- ============================================================================
BEGIN;
SELECT plan(24);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j->>'correlation_id')::uuid FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.n(p_k text) RETURNS int LANGUAGE sql AS $$ SELECT (j#>>'{}')::int FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.cs(p_j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT (p_j->>'ok') || '/' || (p_j->>'code') || '/' || (p_j->>'http_status') $$;
CREATE FUNCTION pg_temp.append_err(p_events jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)', p_events)) $$;
CREATE FUNCTION pg_temp.started_with(p_corr uuid, p_path text[], p_value jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(tests.started_event(p_corr, ARRAY['BTC']), ARRAY['inputs'] || p_path, p_value) $$;
CREATE FUNCTION pg_temp.asset_with(p_corr uuid, p_asset text, p_path text[], p_value jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(tests.asset_event(p_corr, p_asset), ARRAY['inputs'] || p_path, p_value) $$;
-- A RUNNING run of the flagship with a chosen execution id (no STARTED yet).
CREATE FUNCTION pg_temp.claimed(p_email text, p_exec text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_s jsonb; v_c jsonb;
BEGIN
  v_s := tests.start_run(p_email);
  v_c := tests.claim(v_s->>'run_token', p_exec);
  IF (v_c->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'pgtap 149: claim refused %', v_c; END IF;
  RETURN (v_s->>'correlation_id')::uuid;
END $$;
CREATE FUNCTION pg_temp.rl_count() RETURNS int LANGUAGE sql AS $$
  SELECT fao_private.run_start_count(tests.uid('ratelimit@local.test'), 'fao_ratelimit_test_v1', 'rpc:fao_run_start') $$;

SELECT tests.set_clock(0);

-- ============================================================================
-- O3: STARTED may not carry the four run keys; the database sets them
-- ============================================================================
INSERT INTO v VALUES ('o3', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-149-o3')));
CREATE TEMP TABLE o3_top (k text, e text);
INSERT INTO o3_top SELECT k, pg_temp.append_err(jsonb_build_array(pg_temp.started_with(pg_temp.c('o3'), ARRAY[k], '"forged"')))
  FROM unnest(ARRAY['invoker_id', 'invoked_via', 'reason', 'n8n_execution_id']) k;
SELECT is((SELECT count(*) FROM o3_top WHERE e = '22023 FAO-GOV-001 ledger_append: item 0: inputs.' || k || ' is set only by the database'), 4::bigint,
  'O3: each of the four run keys at the top level of STARTED inputs is refused by name');
CREATE TEMP TABLE o3_deep (k text, e text);
INSERT INTO o3_deep SELECT k, pg_temp.append_err(jsonb_build_array(
    pg_temp.started_with(pg_temp.c('o3'), ARRAY['meta'], jsonb_build_object('run', jsonb_build_array(jsonb_build_object(k, 'x'))))))
  FROM unnest(ARRAY['invoker_id', 'invoked_via', 'reason', 'n8n_execution_id']) k;
SELECT is((SELECT count(*) FROM o3_deep WHERE e = '22023 FAO-GOV-001 ledger_append: item 0: inputs.meta.run.[0].' || k || ' is set only by the database'), 4::bigint,
  'O3: each of the four run keys nested inside an array is refused');
SELECT is(pg_temp.append_err(jsonb_build_array(pg_temp.started_with(pg_temp.c('o3'), ARRAY['fixture_provenance'], '{"BTC": {"source": "Kraken PoR", "reason": "x"}}'))),
  '22023 FAO-GOV-001 ledger_append: item 0: inputs.fixture_provenance.BTC.reason is set only by the database',
  'O3: reason inside fixture provenance is refused (only source is the exception there)');
SELECT is(pg_temp.append_err(jsonb_build_array(pg_temp.started_with(pg_temp.c('o3'), ARRAY['Invoked_Via'], '"cli"'))),
  '22023 FAO-GOV-001 ledger_append: item 0: inputs.Invoked_Via is set only by the database',
  'O3: another letter case is refused');
SELECT is(pg_temp.append_err(jsonb_build_array(pg_temp.started_with(pg_temp.c('o3'),
            ARRAY[chr(65362) || chr(65349) || chr(65345) || chr(65363) || chr(65359) || chr(65358)], '"x"'))),
  '22023 FAO-GOV-001 ledger_append: item 0: inputs.' || chr(65362) || chr(65349) || chr(65345) || chr(65363) || chr(65359) || chr(65358) || ' is set only by the database',
  'O3: a full-width reason is refused (NFKC)');
SELECT is(pg_temp.append_err(jsonb_build_array(pg_temp.started_with(pg_temp.c('o3'), ARRAY[' n8n_execution_id'], '"x"'))),
  '22023 FAO-GOV-001 ledger_append: item 0: an inputs key at the top level holds whitespace or a control character',
  'O3: a padded n8n_execution_id is refused');
SELECT is(tests.ledger_count(pg_temp.c('o3'), 'STARTED')::text || '/' || coalesce((SELECT array_length(asset_scope, 1)::text FROM public.run_invocations WHERE correlation_id = pg_temp.c('o3')), 'null'),
  '0/null', 'O3: the refused batches wrote nothing (no STARTED row, no asset scope)');
SELECT is(tests.append(jsonb_build_array(tests.started_event(pg_temp.c('o3'), ARRAY['BTC'])))->>'ok', 'true',
  'O3: a STARTED without the run keys is accepted');
SELECT is((SELECT (inputs->>'invoker_id') || '/' || (inputs->>'invoked_via') || '/' || (inputs->>'reason') || '/' || (inputs->>'n8n_execution_id')
             FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('o3') AND inputs->>'event_type' = 'STARTED'),
  tests.uid('aisha.okonkwo@finagent-os.demo')::text || '/test/pgtap run/pgtap-149-o3',
  'O3: the database still sets invoker_id, invoked_via, reason and n8n_execution_id from the run record');
SELECT is(tests.append(jsonb_build_array(jsonb_build_object('correlation_id', pg_temp.c('o3'), 'event_type', 'FAILED',
            'inputs', jsonb_build_object('failed_node', 'Writer', 'n8n_execution_id', 'forged'),
            'policy_outcome', 'BLOCKED', 'policy_rationale', 'pgtap 149 failed', 'status', 'FAILURE')))->>'ok', 'true',
  'O3: the Writer FAILED overwrites are unchanged (n8n_execution_id still accepted there)');

-- ============================================================================
-- L1: more invisible and blank characters are refused in inputs keys
-- ============================================================================
INSERT INTO v VALUES ('l1', jsonb_build_object('correlation_id', tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC', 'ETH', 'SOL'])));
-- U+2066 to U+2069, U+FE00, U+FE0F, U+E0000, U+E0001, U+E007F, U+3164,
-- U+115F, U+1160, U+2800, U+180B to U+180F
CREATE TEMP TABLE l1_cp (cp int);
INSERT INTO l1_cp VALUES (8294), (8295), (8296), (8297), (65024), (65039), (917504), (917505), (917631),
                         (12644), (4447), (4448), (10240), (6155), (6156), (6157), (6158), (6159);
CREATE TEMP TABLE l1_top (cp int, e text);
INSERT INTO l1_top SELECT cp, pg_temp.append_err(jsonb_build_array(pg_temp.asset_with(pg_temp.c('l1'), 'BTC', ARRAY['event_type' || chr(cp)], '"x"')))
  FROM l1_cp;
SELECT is((SELECT count(*) FROM l1_top WHERE e = '22023 FAO-GOV-001 ledger_append: item 0: an inputs key at the top level holds whitespace or a control character'),
  18::bigint, 'L1: event_type followed by each of the 18 listed characters is refused');
CREATE TEMP TABLE l1_mid (cp int, e text);
INSERT INTO l1_mid SELECT cp, pg_temp.append_err(jsonb_build_array(
    pg_temp.asset_with(pg_temp.c('l1'), 'BTC', ARRAY['threshold'], jsonb_build_object('invoker' || chr(cp) || '_id', 'x'))))
  FROM l1_cp;
SELECT is((SELECT count(*) FROM l1_mid WHERE e = '22023 FAO-GOV-001 ledger_append: item 0: an inputs key at threshold holds whitespace or a control character'),
  18::bigint, 'L1: each character inside a nested key is refused');
INSERT INTO v VALUES ('l1s', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-149-l1s')));
CREATE TEMP TABLE l1_started (cp int, e text);
INSERT INTO l1_started SELECT cp, pg_temp.append_err(jsonb_build_array(
    pg_temp.started_with(pg_temp.c('l1s'), ARRAY['fixture_provenance'], jsonb_build_object('BTC', jsonb_build_object('source' || chr(cp), 'x')))))
  FROM l1_cp;
SELECT is((SELECT count(*) FROM l1_started WHERE e LIKE '%an inputs key at fixture_provenance.BTC holds whitespace or a control character'),
  18::bigint, 'L1: each character after the fixture provenance source key is refused');
SELECT is(tests.ledger_count(pg_temp.c('l1'), 'ASSET_RECONCILED'), 0::bigint, 'L1: nothing was stored by the refused batches');
-- Residual (KNOWN-LIMITS U17): a Cyrillic look-alike is kept as its own key
SELECT is(tests.append(jsonb_build_array(pg_temp.asset_with(pg_temp.c('l1'), 'ETH', ARRAY[chr(1077) || 'vent_type'], '"FAILED"')))->>'ok', 'true',
  'L1 residual: a Cyrillic look-alike of event_type is accepted as an ordinary Writer key');
SELECT is((SELECT (inputs->>'event_type') || '/' || (inputs->>(chr(1077) || 'vent_type'))
             FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('l1') AND inputs->>'asset' = 'ETH'),
  'ASSET_RECONCILED/FAILED', 'L1 residual: the real event_type is unchanged; the look-alike sits beside it');
SELECT is(tests.append(jsonb_build_array(pg_temp.asset_with(pg_temp.c('l1'), 'SOL', ARRAY['note_' || chr(233)], '"ok"')))->>'ok', 'true',
  'L1: an ordinary non-ASCII letter in a key is still accepted');

-- ============================================================================
-- L4: the rate limit window is real time
-- ============================================================================
-- ratelimit@local.test holds the invoker grant on fao_ratelimit_test_v1
-- only. The limit is set 3 above what the invoker already has in the last
-- hour (committed rows from other layers), so the counts below do not depend
-- on earlier activity.
INSERT INTO v VALUES ('base', to_jsonb(pg_temp.rl_count()));
DO $$ BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 149 rate window', true);
  UPDATE public.agent_registry SET max_runs_per_hour = pg_temp.n('base') + 3 WHERE agent_id = 'fao_ratelimit_test_v1';
END $$;
-- Runs started while the test clock is two hours ahead are counted
SELECT tests.set_clock(7200);
INSERT INTO v VALUES ('ka', to_jsonb(tests.new_key())), ('kb', to_jsonb(tests.new_key())), ('kc', to_jsonb(tests.new_key()));
INSERT INTO v VALUES ('a', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.g('ka')#>>'{}'));
INSERT INTO v VALUES ('b', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.g('kb')#>>'{}'));
SELECT is(pg_temp.cs(pg_temp.g('a')) || ' ' || pg_temp.cs(pg_temp.g('b')), 'true/OK/200 true/OK/200', 'L4 setup: two runs start with the test clock moved');
SELECT is(pg_temp.rl_count(), pg_temp.n('base') + 2, 'L4: with the test clock two hours ahead, the two new runs are counted');
-- An EXPIRED replay journaled while the clock is moved is counted too
SELECT tests.set_clock(7200 + 700);
INSERT INTO v VALUES ('a_r', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.g('ka')#>>'{}'));
SELECT is(pg_temp.cs(pg_temp.g('a_r')) || '/' || pg_temp.rl_count()::text,
  'false/EXPIRED/410/' || (pg_temp.n('base') + 3)::text, 'L4: the EXPIRED replay is refused and counted with the clock moved');
SELECT is(pg_temp.cs(tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.g('kc')#>>'{}')), 'false/RATE_LIMITED/429',
  'L4: at the limit a new start is RATE_LIMITED with the test clock moved (before patch round 7 the count was empty)');
SELECT tests.set_clock(0);
-- The hour is real time: rows older than an hour of real time are not
-- counted, rows inside it are (rows built as the owner, rolled back below)
INSERT INTO public.run_invocations (agent_id, invoker_id, risk_tier, invoked_via, reason, idempotency_key, state, requested_at)
SELECT 'fao_ratelimit_test_v1', tests.uid('ratelimit@local.test'), ar.risk_tier, 'test', 'pgtap 149 aged', tests.new_key(), 'REQUESTED', now() - interval '61 minutes'
  FROM public.agent_registry ar WHERE ar.agent_id = 'fao_ratelimit_test_v1';
INSERT INTO public.fao_refusal_journal (at, actor_uid, db_role, session_role, entry_point, target_table, target_key, attempted, code, message)
VALUES (now() - interval '61 minutes', tests.uid('ratelimit@local.test'), 'authenticated', 'authenticator', 'rpc:fao_run_start',
        'run_invocations', 'fao_ratelimit_test_v1', '{}'::jsonb, 'EXPIRED', 'pgtap 149 aged');
SELECT is(pg_temp.rl_count(), pg_temp.n('base') + 3, 'L4: a run and an EXPIRED refusal 61 minutes old in real time are not counted');
INSERT INTO public.run_invocations (agent_id, invoker_id, risk_tier, invoked_via, reason, idempotency_key, state, requested_at)
SELECT 'fao_ratelimit_test_v1', tests.uid('ratelimit@local.test'), ar.risk_tier, 'test', 'pgtap 149 recent', tests.new_key(), 'REQUESTED', now() - interval '59 minutes'
  FROM public.agent_registry ar WHERE ar.agent_id = 'fao_ratelimit_test_v1';
INSERT INTO public.fao_refusal_journal (at, actor_uid, db_role, session_role, entry_point, target_table, target_key, attempted, code, message)
VALUES (now() - interval '59 minutes', tests.uid('ratelimit@local.test'), 'authenticated', 'authenticator', 'rpc:fao_run_start',
        'run_invocations', 'fao_ratelimit_test_v1', '{}'::jsonb, 'EXPIRED', 'pgtap 149 recent');
SELECT is(pg_temp.rl_count(), pg_temp.n('base') + 5, 'L4: a run and an EXPIRED refusal 59 minutes old in real time are counted');
SELECT ok(pg_get_functiondef('fao_private.run_start_count(uuid,text,text)'::regprocedure) NOT LIKE '%fao_private.clock()%'
          AND pg_get_functiondef('public.fao_run_start(json)'::regprocedure) NOT LIKE '%event_timestamp > fao_private.clock()%',
  'L4: neither rate limit count compares with the test-clock-shifted fao_private.clock()');

SELECT * FROM finish();
ROLLBACK;
