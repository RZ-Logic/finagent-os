-- ============================================================================
-- FinAgent OS pgTAP 147: patch round 6, run path database (group G1)
-- Controls:
--   FAO-GOV-008 (P4, K4 invariant): every write that sets
--     agent_registry.sla_max_execution_seconds below 900 is refused (23514),
--     for the owner too, so the stale-run rule never fires before the n8n
--     executionTimeout (600 s on the flagship). NULL and 900 or more are
--     accepted; an UPDATE that leaves a stored lower value unchanged is not
--     refused (the live row is raised by the cutover runbook).
--   FAO-GOV-003 (P5): a replay of an expired idempotency key counts toward
--     the same RATE_LIMITED rule as run starts: over max_runs_per_hour the
--     replay is refused RATE_LIMITED (429) instead of EXPIRED, and EXPIRED
--     replays use up the budget for new starts. The window is real time
--     (patch round 7 L4): moving the test clock does not free it.
--   FAO-GOV-004 (P6): the read policies run has_role / has_any_role once
--     per statement (scalar subquery); members, the reader and outsiders
--     still see what they saw; U12 still holds.
--   FAO-GOV-001 (P7): reserved inputs keys match after
--     normalize(lower(btrim(key)), NFKC); a key holding whitespace or a
--     control character is refused at any depth.
-- ============================================================================
BEGIN;
SELECT plan(48);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
GRANT SELECT ON v TO authenticated;
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j->>'correlation_id')::uuid FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.k(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT j#>>'{}' FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.cs(p_j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT (p_j->>'ok') || '/' || (p_j->>'code') || '/' || (p_j->>'http_status') $$;
-- An owner write to agent_registry with a change reason; returns the SQLSTATE.
CREATE FUNCTION pg_temp.reg(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_state text := '00000';
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 147 SLA floor', true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  RETURN v_state;
END $$;
CREATE FUNCTION pg_temp.sla(p_agent text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(sla_max_execution_seconds::text, 'NULL') FROM public.agent_registry WHERE agent_id = p_agent $$;
CREATE FUNCTION pg_temp.append_err(p_events jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)', p_events)) $$;
-- An ASSET_RECONCILED event with one extra inputs key at a path.
CREATE FUNCTION pg_temp.with_key(p_corr uuid, p_path text[], p_value jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(tests.asset_event(p_corr, 'BTC'), ARRAY['inputs'] || p_path, p_value) $$;
CREATE FUNCTION pg_temp.expired_journal(p_email text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.fao_refusal_journal
   WHERE actor_uid = tests.uid(p_email) AND entry_point = 'rpc:fao_run_start' AND code = 'EXPIRED' $$;

-- A RUNNING run of the flagship with a chosen execution id.
CREATE FUNCTION pg_temp.claimed(p_email text, p_exec text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_s jsonb; v_c jsonb;
BEGIN
  v_s := tests.start_run(p_email);
  v_c := tests.claim(v_s->>'run_token', p_exec);
  IF (v_c->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'pgtap 147: claim refused %', v_c; END IF;
  RETURN (v_s->>'correlation_id')::uuid;
END $$;

SELECT tests.set_clock(0);

-- ============================================================================
-- P4: execution SLA floor of 900 s on every agent_registry write
-- ============================================================================
SELECT is((SELECT count(*) FROM public.agent_registry WHERE sla_max_execution_seconds < 900), 0::bigint,
  'P4: no seeded agent has an execution SLA below 900 s');
SELECT is(pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 600 WHERE agent_id = 'fao_reserve_recon_v1'$$), '23514',
  'P4: the owner setting the flagship SLA to 600 s is refused (23514)');
SELECT is(pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 899 WHERE agent_id = 'fao_close_orchestrator_v1'$$), '23514',
  'P4: 899 s is refused');
SELECT is(pg_temp.sla('fao_reserve_recon_v1'), '900', 'P4: the refused write changed nothing');
SELECT is(pg_temp.reg($$INSERT INTO public.agent_registry (agent_id, display_name, risk_tier, status, approval_threshold, sox_control_ids,
                          ai_advisory_enabled, rollback_procedure, data_sources, production_targets, sla_max_execution_seconds,
                          sla_max_hitl_resolution_hrs, process_owner_id)
                        SELECT 'fao_pgtap147_v1', 'pgtap 147', 'GREEN', 'STUB_DOCUMENTED', 1, ARRAY['FAO-GOV-001']::text[], false,
                               'pgtap', '{}'::jsonb, '{}'::jsonb, 300, 24, po.id
                          FROM public.process_owners po WHERE po.email = 'sarah.chen@finagent-os.demo'$$), '23514',
  'P4: an INSERT with a 300 s SLA is refused');
SELECT is((SELECT count(*) FROM public.agent_registry WHERE agent_id = 'fao_pgtap147_v1'), 0::bigint, 'P4: the refused INSERT added no agent');
SELECT is(pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 1200 WHERE agent_id = 'fao_close_orchestrator_v1'$$)
          || '/' || pg_temp.sla('fao_close_orchestrator_v1'), '00000/1200', 'P4: 1200 s is accepted');
SELECT is(pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 900 WHERE agent_id = 'fao_close_orchestrator_v1'$$)
          || '/' || pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = NULL WHERE agent_id = 'fao_close_orchestrator_v1'$$)
          || '/' || pg_temp.sla('fao_close_orchestrator_v1'), '00000/00000/NULL', 'P4: exactly 900 s and NULL are accepted');
-- A row that already holds a lower value (a live row from before this
-- patch), stood in for with the guard trigger off for one statement.
SELECT tests.as_owner();
ALTER TABLE public.agent_registry DISABLE TRIGGER agent_registry_sla_guard_row;
SELECT pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 300 WHERE agent_id = 'fao_variance_analyzer_v1'$$);
ALTER TABLE public.agent_registry ENABLE TRIGGER agent_registry_sla_guard_row;
SELECT is(pg_temp.reg($$UPDATE public.agent_registry SET max_runs_per_hour = 5 WHERE agent_id = 'fao_variance_analyzer_v1'$$)
          || '/' || pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 300, max_runs_per_hour = 4 WHERE agent_id = 'fao_variance_analyzer_v1'$$),
  '00000/00000', 'P4: an UPDATE that leaves a stored lower value unchanged is not refused');
SELECT is(pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 600 WHERE agent_id = 'fao_variance_analyzer_v1'$$)
          || '/' || pg_temp.reg($$UPDATE public.agent_registry SET sla_max_execution_seconds = 900 WHERE agent_id = 'fao_variance_analyzer_v1'$$)
          || '/' || pg_temp.sla('fao_variance_analyzer_v1'), '23514/00000/900',
  'P4: a stored lower value can only be raised to 900 s or more (the cutover step)');
SELECT is((SELECT count(*) FROM public.fao_admin_audit WHERE reason = 'pgtap 147 SLA floor' AND row_key->>'agent_id' = 'fao_variance_analyzer_v1'
             AND new_row->>'sla_max_execution_seconds' = '900'), 1::bigint,
  'P4: the raise is audited with its change reason');
SELECT ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.agent_registry'::regclass AND tgname = 'agent_registry_sla_guard_row' AND tgenabled = 'O'),
  'P4: the guard trigger is attached and enabled');
SELECT is_empty($$SELECT r FROM unnest(ARRAY['anon', 'authenticated', 'service_role', 'fao_workflow']) r
                  WHERE has_function_privilege(r, 'fao_private.agent_registry_sla_guard_row()', 'EXECUTE')$$,
  'P4: the guard function is granted to no client role');

-- ============================================================================
-- P5: EXPIRED replays count toward the run start rate limit
-- ============================================================================
-- ratelimit@local.test holds the invoker grant on fao_ratelimit_test_v1 only;
-- its limit is set to 3 runs an hour here.
SELECT pg_temp.reg($$UPDATE public.agent_registry SET max_runs_per_hour = 3 WHERE agent_id = 'fao_ratelimit_test_v1'$$);
INSERT INTO v VALUES ('ka', to_jsonb(tests.new_key())), ('kb', to_jsonb(tests.new_key())), ('kc', to_jsonb(tests.new_key()));
INSERT INTO v VALUES ('e0', to_jsonb(pg_temp.expired_journal('ratelimit@local.test')));
INSERT INTO v VALUES ('a', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('ka')));
INSERT INTO v VALUES ('b', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('kb')));
SELECT ok(pg_temp.g('a')->>'ok' = 'true' AND pg_temp.g('b')->>'ok' = 'true', 'P5 setup: two runs started (2 of 3)');
SELECT tests.set_clock(700);
INSERT INTO v VALUES ('a_r1', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('ka')));
SELECT is(pg_temp.cs(pg_temp.g('a_r1')) || '/' || ((pg_temp.g('a_r1')->>'correlation_id')::uuid = pg_temp.c('a'))::text,
  'false/EXPIRED/410/true', 'P5: under the limit the replay of an expired key is EXPIRED (410) with its run');
SELECT is(pg_temp.expired_journal('ratelimit@local.test') - (pg_temp.g('e0')#>>'{}')::bigint, 1::bigint,
  'P5: the EXPIRED replay is journaled once (3 of 3 counted)');
INSERT INTO v VALUES ('b_r1', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('kb')));
SELECT is(pg_temp.cs(pg_temp.g('b_r1')), 'false/RATE_LIMITED/429',
  'P5: at the limit, the replay that expires a run is refused RATE_LIMITED (429)');
SELECT is(tests.run_state(pg_temp.c('b')), 'EXPIRED', 'P5: that run is still EXPIRED (its token had expired)');
SELECT ok(NOT pg_temp.g('b_r1') ? 'correlation_id' AND NOT pg_temp.g('b_r1') ? 'run_token',
  'P5: the RATE_LIMITED refusal names no run and carries no token');
INSERT INTO v VALUES ('j_rl0', to_jsonb(tests.journal_count('RATE_LIMITED')));
INSERT INTO v VALUES ('a_r2', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('ka')));
SELECT is(pg_temp.cs(pg_temp.g('a_r2')), 'false/RATE_LIMITED/429', 'P5: a replay of an EXPIRED run over the limit is RATE_LIMITED');
SELECT is(tests.journal_count('RATE_LIMITED') - (pg_temp.g('j_rl0')#>>'{}')::bigint, 1::bigint, 'P5: the RATE_LIMITED refusal is journaled');
SELECT is(pg_temp.expired_journal('ratelimit@local.test') - (pg_temp.g('e0')#>>'{}')::bigint, 1::bigint,
  'P5: refusals over the limit write no further EXPIRED row');
SELECT is(pg_temp.cs(tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('kc'))), 'false/RATE_LIMITED/429',
  'P5: EXPIRED replays use up the budget for new starts (2 runs plus 1 replay)');
SELECT is((SELECT count(*) FROM public.run_invocations WHERE idempotency_key = pg_temp.k('kc')), 0::bigint, 'P5: the refused start created no run');
SELECT is((SELECT count(*) FROM public.run_invocations WHERE invoker_id = tests.uid('ratelimit@local.test') AND agent_id = 'fao_ratelimit_test_v1'
             AND idempotency_key IN (pg_temp.k('ka'), pg_temp.k('kb'))), 2::bigint, 'P5: still one run per key');
-- Patch round 7 (L4): the window is one hour of real time (now(), the clock
-- requested_at and the journal use); moving the test clock past the hour
-- does not free the budget. Window expiry in real time: 149_patch7.
SELECT tests.set_clock(700 + 3601);
INSERT INTO v VALUES ('a_r3', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('ka')));
SELECT is(pg_temp.cs(pg_temp.g('a_r3')), 'false/RATE_LIMITED/429',
  'P5 (L4): with the test clock moved past the hour the replay is still RATE_LIMITED (real-time window)');
SELECT is(pg_temp.cs(tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1', pg_temp.k('kc'))), 'false/RATE_LIMITED/429',
  'P5 (L4): and a new start is still refused');
SELECT tests.set_clock(0);

-- ============================================================================
-- P6: role helpers once per statement in the read policies; U12 kept
-- ============================================================================
SELECT is_empty($$SELECT p.tablename || ' ' || p.policyname FROM pg_policies p
                  WHERE p.schemaname = 'public'
                    AND regexp_count(coalesce(p.qual, ''), 'fao_private\.has_') <> regexp_count(coalesce(p.qual, ''), 'SELECT fao_private\.has_')$$,
  'P6: every policy calls has_role / has_any_role only inside a scalar subquery');
SELECT is((SELECT count(*) FROM pg_policies p WHERE p.schemaname = 'public' AND p.qual LIKE '%SELECT fao_private.has_%'), 10::bigint,
  'P6: the ten FinAgent read policies use the wrapped form');
SELECT is((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'fao_private' AND p.proname IN ('has_role', 'has_any_role') AND p.provolatile = 's' AND p.prosecdef), 2::bigint,
  'P6: has_role and has_any_role are STABLE and SECURITY DEFINER');
INSERT INTO v VALUES ('ledger_n', to_jsonb((SELECT count(*) FROM public.shadow_ledger)));
SELECT is(tests.value_as('mcp.reader@finagent-os.demo', 'SELECT count(*)::text FROM public.shadow_ledger'), pg_temp.g('ledger_n')#>>'{}',
  'P6: the reader reads every ledger row');
SELECT is(tests.value_as('outsider@local.test', 'SELECT count(*)::text FROM public.shadow_ledger')
          || '/' || tests.value_as('outsider@local.test', 'SELECT count(*)::text FROM public.run_invocations')
          || '/' || tests.value_as('outsider@local.test', 'SELECT count(*)::text FROM public.fao_refusal_journal'), '0/0/0',
  'P6: a caller with no role reads no ledger, run or journal row');
SELECT is(tests.value_as('aisha.okonkwo@finagent-os.demo', 'SELECT count(*)::text FROM public.fao_refusal_journal')
          || '/' || tests.value_as('mcp.reader@finagent-os.demo', 'SELECT (count(*) > 0)::text FROM public.fao_refusal_journal'), '0/true',
  'P6: the journal policy still admits the reader and not a plain invoker');
SELECT is(tests.value_as('sarah.chen@finagent-os.demo',
            format('SELECT fao_private.has_any_role(%L::uuid)::text || ''/'' || fao_private.has_role(%L::uuid, ''invoker'', NULL)::text',
                   tests.uid('aisha.okonkwo@finagent-os.demo'), tests.uid('aisha.okonkwo@finagent-os.demo'))), 'false/false',
  'P6 (U12): a client asking directly about another user still gets false');
SELECT is(tests.value_as('sarah.chen@finagent-os.demo',
            format('SELECT fao_private.has_any_role(%L::uuid)::text', tests.uid('sarah.chen@finagent-os.demo'))), 'true',
  'P6: a client asking about itself is answered (no stack read needed)');
SELECT is(tests.value_as('mcp.reader@finagent-os.demo', $$SELECT fao_private.has_any_role(auth.uid())::text$$)
          || '/' || tests.value_as('outsider@local.test', $$SELECT fao_private.has_any_role(auth.uid())::text$$), 'true/false',
  'P6: has_any_role keeps its answer (reader global grant true, no grant false)');

-- ============================================================================
-- P7: reserved inputs keys after NFKC and case folding; no whitespace or
--     control characters in any key
-- ============================================================================
INSERT INTO v VALUES ('p7', jsonb_build_object('correlation_id', tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC', 'ETH'])));
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY['invoker_id '], '"x"'))),
  'item 0: an inputs key at the top level holds whitespace or a control character', 'P7: a trailing space is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY[U&'invoker_id\00A0'], '"x"'))),
  'holds whitespace or a control character', 'P7: a trailing no-break space is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY[U&'invoker\200B_id'], '"x"'))),
  'holds whitespace or a control character', 'P7: a zero-width space inside the key is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY['threshold'], jsonb_build_object(E'a\tb', 1)))),
  'item 0: an inputs key at threshold holds whitespace or a control character', 'P7: a tab in a nested key is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY['notes'], jsonb_build_array(jsonb_build_object(E'n\u0001', 1))))),
  'item 0: an inputs key at notes\.\[0\] holds whitespace or a control character', 'P7: a control character in a key inside an array is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY[U&'\FF49\FF4E\FF56\FF4F\FF4B\FF45\FF52\FF3F\FF49\FF44'], '"x"'))),
  'is set only by the database', 'P7: a full-width look-alike of invoker_id is refused as reserved');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY[U&'\FF21\FF30\FF30\FF32\FF2F\FF36\FF25\FF32_ID'], '"x"'))),
  'is set only by the database', 'P7: full-width capitals mixed with ASCII (APPROVER_ID) are refused as reserved');
SELECT matches(pg_temp.append_err(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY['threshold'], '{"DeCiSiOn": "APPROVED"}'))),
  'item 0: inputs\.threshold\.DeCiSiOn is set only by the database', 'P7: mixed case is refused as reserved');
SELECT is(tests.append(jsonb_build_array(pg_temp.with_key(pg_temp.c('p7'), ARRAY['threshold'], '{"band_upper": 1.05, "note_text": "a b"}')))->>'ok', 'true',
  'P7: a clean event (spaces only in values) is still accepted');
INSERT INTO v VALUES ('p7s', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-147-p7s')));
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('p7s'), ARRAY['BTC']),
                 ARRAY['inputs', U&'\FF49\FF4E\FF56\FF4F\FF4B\FF45\FF52_id'], '"x"'))),
  'is set only by the database', 'P7: STARTED overwrites are exact-spelling only (a full-width invoker_id is refused)');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('p7s'), ARRAY['BTC']), '{inputs,fixture_provenance}',
                 '{"BTC": {"source ": "pgtap"}}'))),
  'item 0: an inputs key at fixture_provenance\.BTC holds whitespace or a control character',
  'P7: the fixture provenance exception needs the exact key (a trailing space is refused)');
SELECT is(tests.append(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('p7s'), ARRAY['BTC']), '{inputs,fixture_provenance}',
                 '{"BTC": {"source": "Kraken PoR"}}')))->>'ok', 'true',
  'P7: STARTED with the exact fixture_provenance.<asset>.source is accepted');

SELECT * FROM finish();
ROLLBACK;
