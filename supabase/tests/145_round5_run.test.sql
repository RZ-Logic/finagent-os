-- ============================================================================
-- FinAgent OS pgTAP 145: round 5, run path database (group G1)
-- Controls:
--   FAO-GOV-008 (K1): fao_run_fail(exec, node, message, source) takes a
--     closed source set; every call writes exactly one durable record (the
--     FAILED row on the run, or one public.workflow_failures row); it
--     attaches only for 'flagship' when the NEWEST run holding the id is
--     unfinished, and never falls back to an older run. workflow_failures is
--     append-only, read by members under RLS, written by no client role.
--   FAO-GOV-004 (K2): finalize refuses a commit when the invoker is no
--     longer an active owner with the invoker grant (INVOKER_NOT_ACTIVE,
--     COMMIT_BLOCKED, run FAILED, nothing raised); AGENT_NOT_ACTIVE first.
--   FAO-GOV-008 (K4): claim fails a stale RUNNING holder of the execution id
--     (older than the agent's sla_max_execution_seconds) and then claims; a
--     holder inside the window is still ALREADY_CLAIMED.
--   FAO-GOV-008 (K5): replaying the key of an expired run is EXPIRED (410)
--     with the correlation id and no token.
--   FAO-GOV-001 (U10): reserved inputs keys are refused at any depth and in
--     any letter case. (U16 (c)): inputs.asset on STARTED or a Writer
--     FAILED must be in the run asset scope.
--   FAO-GOV-004 (U12): has_role and has_any_role answer a client only about
--     itself, even when called directly; FinAgent functions keep working.
--   FAO-GOV-015 (B-28): every function in public and fao_private, legacy
--     included, pins search_path.
--   FAO-GOV-004 (F-09): the hitl_queue catalog comments describe the
--     current controls.
--   FAO-GOV-002 (F-19): tier, deadline and invoker come from the registry
--     and the session into the run and the request, for AMBER and GREEN.
-- The destructive cases (tier changes, role revoked, owner deactivated,
-- agent deprecated) come last.
-- ============================================================================
BEGIN;
SELECT plan(102);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.c(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT (j->>'correlation_id')::uuid FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.tok(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT j->>'run_token' FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.fail(p_exec text, p_node text, p_msg text, p_source text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format('SELECT public.fao_run_fail(%L, %L, %L, %L)', p_exec, p_node, p_msg, p_source)) $$;
CREATE FUNCTION pg_temp.wf_count() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.workflow_failures $$;
CREATE FUNCTION pg_temp.wf_last() RETURNS jsonb LANGUAGE sql AS $$
  SELECT to_jsonb(w) FROM public.workflow_failures w ORDER BY w.id DESC LIMIT 1 $$;
CREATE FUNCTION pg_temp.keys(p_j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(p_j) AS k $$;
CREATE FUNCTION pg_temp.append_err(p_events jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)', p_events)) $$;
-- A RUNNING run with a chosen execution id and no ledger rows yet.
CREATE FUNCTION pg_temp.claimed(p_email text, p_exec text, p_agent text DEFAULT 'fao_reserve_recon_v1') RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_s jsonb; v_c jsonb;
BEGIN
  v_s := tests.start_run(p_email, p_agent);
  v_c := tests.claim(v_s->>'run_token', p_exec);
  IF (v_c->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'pgtap 145: claim refused %', v_c; END IF;
  RETURN (v_s->>'correlation_id')::uuid;
END $$;
-- The same run taken to AWAITING_HITL (one review asset).
CREATE FUNCTION pg_temp.awaiting(p_email text, p_exec text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_corr uuid := pg_temp.claimed(p_email, p_exec);
BEGIN
  PERFORM tests.append(jsonb_build_array(tests.started_event(v_corr, ARRAY['USDT']),
                                         tests.asset_event(v_corr, 'USDT', 'REQUIRE_HUMAN', 'STANDARD')));
  IF tests.finalize(v_corr)->>'state' IS DISTINCT FROM 'AWAITING_HITL' THEN RAISE EXCEPTION 'pgtap 145: not AWAITING_HITL'; END IF;
  RETURN v_corr;
END $$;
-- The same run taken to COMMITTED (one clean asset).
CREATE FUNCTION pg_temp.committed(p_email text, p_exec text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_corr uuid := pg_temp.claimed(p_email, p_exec);
BEGIN
  PERFORM tests.append(jsonb_build_array(tests.started_event(v_corr, ARRAY['BTC']), tests.asset_event(v_corr, 'BTC')));
  IF tests.finalize(v_corr)->>'state' IS DISTINCT FROM 'COMMITTED' THEN RAISE EXCEPTION 'pgtap 145: not COMMITTED'; END IF;
  RETURN v_corr;
END $$;

-- Room in the per-hour rate limits for the runs below.
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 145 rate limits', true);
  UPDATE public.agent_registry SET max_runs_per_hour = 60 WHERE agent_id IN ('fao_reserve_recon_v1', 'fao_ratelimit_test_v1');
END $$;

-- ============================================================================
-- K1: signature, table, append-only, RLS
-- ============================================================================
SELECT has_function('public', 'fao_run_fail', ARRAY['text', 'text', 'text', 'text'], 'K1: fao_run_fail takes four text arguments');
SELECT hasnt_function('public', 'fao_run_fail', ARRAY['text', 'text', 'text'], 'K1: the three-argument fao_run_fail is gone');
SELECT is((SELECT pronargdefaults::int FROM pg_proc WHERE oid = 'public.fao_run_fail(text,text,text,text)'::regprocedure), 0,
  'K1: no argument has a default');
SELECT columns_are('public', 'workflow_failures',
  ARRAY['id', 'recorded_at', 'source', 'n8n_execution_id', 'failed_node', 'message', 'outcome', 'correlation_id'],
  'K1: workflow_failures columns');
SELECT throws_ok($$INSERT INTO public.workflow_failures (source, outcome) VALUES ('writer', 'PRE_CLAIM')$$, '23514', NULL,
  'K1: source outside the four values is refused by the CHECK');
SELECT throws_ok($$INSERT INTO public.workflow_failures (source, outcome) VALUES ('gateway', 'ATTACHED')$$, '23514', NULL,
  'K1: ATTACHED is never stored');

-- Source checked first; nothing written.
INSERT INTO v VALUES ('wf0', to_jsonb(pg_temp.wf_count()));
INSERT INTO v VALUES ('l0', to_jsonb((SELECT count(*) FROM public.shadow_ledger)));
SELECT is(tests.sqlstate_as('fao_workflow', $$SELECT public.fao_run_fail('1', 'Node', 'boom', 'bogus')$$), '22023',
  'K1: an unknown source raises 22023');
SELECT matches(tests.error_as('fao_workflow', $$SELECT public.fao_run_fail('1', 'Node', 'boom', NULL)$$),
  '^22023 FAO-GOV-008 run_fail: p_source must be flagship, flagship_pre_claim, gateway or sweeper$', 'K1: a NULL source raises with the fixed message');
SELECT is(tests.sqlstate_as('fao_workflow', $$SELECT public.fao_run_fail('1', 'Node', 'boom', 'Flagship')$$), '22023',
  'K1: the source set is case sensitive');
SELECT ok(pg_temp.wf_count() = (pg_temp.g('wf0')#>>'{}')::bigint
          AND (SELECT count(*) FROM public.shadow_ledger) = (pg_temp.g('l0')#>>'{}')::bigint,
  'K1: a refused source writes nothing');

-- gateway and sweeper: NOT_FLAGSHIP, never a run lookup.
INSERT INTO v VALUES ('gw', pg_temp.fail('pgtap-145-gw', 'Compose Slack' || chr(1) || ' Message' || repeat('n', 300),
                                         'gateway boom' || chr(10) || repeat('m', 600), 'gateway'));
SELECT is(pg_temp.keys(pg_temp.g('gw')), 'code,correlation_id,http_status,ledger_id,message,ok,outcome,ref,state',
  'K1: envelope keys');
SELECT is(pg_temp.g('gw')->>'ok' || '/' || (pg_temp.g('gw')->>'code') || '/' || (pg_temp.g('gw')->>'outcome') || '/'
          || coalesce(pg_temp.g('gw')->>'correlation_id', 'null') || '/' || coalesce(pg_temp.g('gw')->>'ledger_id', 'null')
          || '/' || coalesce(pg_temp.g('gw')->>'state', 'null'),
  'true/OK/NOT_FLAGSHIP/null/null/null', 'K1: a gateway failure is ok, NOT_FLAGSHIP, with no run');
SELECT is(pg_temp.wf_last()->>'source' || '/' || (pg_temp.wf_last()->>'outcome') || '/' || (pg_temp.wf_last()->>'n8n_execution_id')
          || '/' || coalesce(pg_temp.wf_last()->>'correlation_id', 'null'),
  'gateway/NOT_FLAGSHIP/pgtap-145-gw/null', 'K1: the gateway failure is one workflow_failures row');
SELECT ok(length(pg_temp.wf_last()->>'failed_node') = 200 AND length(pg_temp.wf_last()->>'message') = 500
          AND (pg_temp.wf_last()->>'failed_node') !~ '[[:cntrl:]]' AND (pg_temp.wf_last()->>'message') !~ '[[:cntrl:]]',
  'K1: failed_node and message are stored cleaned and cut to 200 and 500');
INSERT INTO v VALUES ('sw', pg_temp.fail('pgtap-145-sw', 'Check Sweep Errors', 'sweeper boom', 'sweeper'));
SELECT is(pg_temp.g('sw')->>'outcome' || '/' || (pg_temp.wf_last()->>'source') || '/' || (pg_temp.wf_last()->>'outcome'),
  'NOT_FLAGSHIP/sweeper/NOT_FLAGSHIP', 'K1: a sweeper failure is one NOT_FLAGSHIP row with source sweeper');
SELECT is(pg_temp.wf_count(), (pg_temp.g('wf0')#>>'{}')::bigint + 2, 'K1: exactly one row per call');

-- flagship_pre_claim while an older AWAITING_HITL run holds the same id.
INSERT INTO v VALUES ('pre_d', jsonb_build_object('correlation_id', pg_temp.awaiting('aisha.okonkwo@finagent-os.demo', 'pgtap-145-pre')));
INSERT INTO v VALUES ('pre', pg_temp.fail('pgtap-145-pre', 'Webhook', 'pre claim boom', 'flagship_pre_claim'));
SELECT is(pg_temp.g('pre')->>'ok' || '/' || (pg_temp.g('pre')->>'code') || '/' || (pg_temp.g('pre')->>'outcome') || '/'
          || coalesce(pg_temp.g('pre')->>'correlation_id', 'null') || '/' || coalesce(pg_temp.g('pre')->>'ledger_id', 'null'),
  'true/OK/PRE_CLAIM/null/null', 'K1: a pre-claim failure is ok, PRE_CLAIM, with no run');
SELECT is(pg_temp.wf_last()->>'source' || '/' || (pg_temp.wf_last()->>'outcome') || '/' || coalesce(pg_temp.wf_last()->>'correlation_id', 'null'),
  'flagship_pre_claim/PRE_CLAIM/null', 'K1: the pre-claim failure is one PRE_CLAIM row');
SELECT is(tests.ledger_count(pg_temp.c('pre_d'), 'FAILED') || '/' || tests.run_state(pg_temp.c('pre_d')), '0/AWAITING_HITL',
  'K1: no FAILED row on the older AWAITING_HITL run holding the same id (U14 (a))');

-- flagship, newest holder unfinished: ATTACHED, no workflow_failures row.
INSERT INTO v VALUES ('wf1', to_jsonb(pg_temp.wf_count()));
INSERT INTO v VALUES ('att', pg_temp.fail('pgtap-145-pre', 'HITL Gateway', 'notifier failed', 'flagship'));
SELECT is(pg_temp.g('att')->>'ok' || '/' || (pg_temp.g('att')->>'code') || '/' || (pg_temp.g('att')->>'outcome') || '/'
          || (pg_temp.g('att')->>'state') || '/' || ((pg_temp.g('att')->>'correlation_id')::uuid = pg_temp.c('pre_d'))::text
          || '/' || ((pg_temp.g('att')->>'ledger_id') IS NOT NULL)::text,
  'true/OK/ATTACHED/AWAITING_HITL/true/true', 'K1: a flagship failure attaches FAILED to the unfinished newest holder');
SELECT is(pg_temp.wf_count(), (pg_temp.g('wf1')#>>'{}')::bigint, 'K1: an attached failure writes no workflow_failures row');
SELECT is((SELECT inputs->>'source' || '/' || (inputs->>'stage') FROM public.shadow_ledger
            WHERE ledger_id = (pg_temp.g('att')->>'ledger_id')::bigint),
  'error_workflow/after_request', 'K1: the attached FAILED row keeps source error_workflow');
INSERT INTO v VALUES ('run_c', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-145-run')));
INSERT INTO v VALUES ('att2', pg_temp.fail('pgtap-145-run', 'Per-Asset Reconcile', 'boom', 'flagship'));
SELECT is(pg_temp.g('att2')->>'outcome' || '/' || (pg_temp.g('att2')->>'state') || '/' || tests.run_state(pg_temp.c('run_c')),
  'ATTACHED/FAILED/FAILED', 'K1: a RUNNING newest holder moves to FAILED');

-- flagship, newest holder finished, older holder unfinished: ALREADY_TERMINAL.
INSERT INTO v VALUES ('t_old', jsonb_build_object('correlation_id', pg_temp.awaiting('aisha.okonkwo@finagent-os.demo', 'pgtap-145-term')));
INSERT INTO v VALUES ('t_new', jsonb_build_object('correlation_id', pg_temp.committed('aisha.okonkwo@finagent-os.demo', 'pgtap-145-term')));
INSERT INTO v VALUES ('l1', to_jsonb((SELECT count(*) FROM public.shadow_ledger)));
INSERT INTO v VALUES ('term', pg_temp.fail('pgtap-145-term', 'Check Finalize Result', 'refused', 'flagship'));
SELECT is(pg_temp.g('term')->>'ok' || '/' || (pg_temp.g('term')->>'code') || '/' || (pg_temp.g('term')->>'outcome') || '/'
          || (pg_temp.g('term')->>'state') || '/' || coalesce(pg_temp.g('term')->>'ledger_id', 'null'),
  'true/ALREADY_TERMINAL/ALREADY_TERMINAL/COMMITTED/null', 'K1: the newest holder is finished: ALREADY_TERMINAL');
SELECT is((pg_temp.g('term')->>'correlation_id')::uuid, pg_temp.c('t_new'), 'K1: ALREADY_TERMINAL names the newest holder');
SELECT is((pg_temp.wf_last()->>'correlation_id')::uuid, pg_temp.c('t_new'), 'K1: the ALREADY_TERMINAL row stores the newest holder');
SELECT is(pg_temp.wf_last()->>'outcome' || '/' || (pg_temp.wf_last()->>'source'), 'ALREADY_TERMINAL/flagship', 'K1: ALREADY_TERMINAL row');
SELECT is(tests.ledger_count(pg_temp.c('t_old'), 'FAILED') || '/' || tests.run_state(pg_temp.c('t_old'))
          || '/' || ((SELECT count(*) FROM public.shadow_ledger) = (pg_temp.g('l1')#>>'{}')::bigint)::text,
  '0/AWAITING_HITL/true', 'K1: never falls back to the older unfinished run (red team r4 item 1); no ledger row');

-- flagship, unknown id: UNKNOWN_EXECUTION, ok:false, not journaled, one row.
INSERT INTO v VALUES ('j0', to_jsonb(tests.journal_total()));
INSERT INTO v VALUES ('unk', pg_temp.fail('pgtap-145-nobody', 'Node', 'boom', 'flagship'));
SELECT is(pg_temp.g('unk')->>'ok' || '/' || (pg_temp.g('unk')->>'code') || '/' || (pg_temp.g('unk')->>'http_status') || '/'
          || (pg_temp.g('unk')->>'outcome') || '/' || coalesce(pg_temp.g('unk')->>'correlation_id', 'null') || '/'
          || coalesce(pg_temp.g('unk')->>'state', 'null'),
  'false/UNKNOWN_EXECUTION/200/UNKNOWN_EXECUTION/null/null', 'K1: an unknown execution is ok:false UNKNOWN_EXECUTION');
SELECT is(pg_temp.keys(pg_temp.g('unk')), 'code,correlation_id,http_status,ledger_id,message,ok,outcome,ref,state',
  'K1: UNKNOWN_EXECUTION envelope keys');
SELECT is(tests.journal_total(), (pg_temp.g('j0')#>>'{}')::bigint, 'K1: UNKNOWN_EXECUTION is not journaled');
SELECT is(pg_temp.wf_last()->>'outcome' || '/' || (pg_temp.wf_last()->>'n8n_execution_id'), 'UNKNOWN_EXECUTION/pgtap-145-nobody',
  'K1: UNKNOWN_EXECUTION is one workflow_failures row');

-- Append-only, for the owner too.
SELECT throws_ok($$UPDATE public.workflow_failures SET message = 'x'$$, '42501', NULL, 'K1: UPDATE on workflow_failures is refused');
SELECT throws_ok($$DELETE FROM public.workflow_failures$$, '42501', NULL, 'K1: DELETE on workflow_failures is refused');
SELECT throws_ok($$TRUNCATE public.workflow_failures$$, '42501', NULL, 'K1: TRUNCATE on workflow_failures is refused');

-- RLS and grants: members (the MCP reader included) read; nobody else; no client writes.
SELECT ok(tests.value_as('sarah.chen@finagent-os.demo', 'SELECT count(*)::text FROM public.workflow_failures')::bigint >= 5,
  'K1: a member reads workflow_failures');
SELECT ok(tests.value_as('mcp.reader@finagent-os.demo', 'SELECT count(*)::text FROM public.workflow_failures')::bigint >= 5,
  'K1: the MCP reader reads workflow_failures');
SELECT is(tests.value_as('outsider@local.test', 'SELECT count(*)::text FROM public.workflow_failures'), '0',
  'K1: a signed-in non-member reads no row');
SELECT is(tests.sqlstate_as('anon', 'SELECT 1 FROM public.workflow_failures'), '42501', 'K1: anon cannot read workflow_failures');
SELECT is(tests.sqlstate_as('sarah.chen@finagent-os.demo', $$INSERT INTO public.workflow_failures (source, outcome) VALUES ('gateway', 'NOT_FLAGSHIP')$$),
  '42501', 'K1: authenticated cannot write workflow_failures');
SELECT is(tests.sqlstate_as('fao_workflow', $$INSERT INTO public.workflow_failures (source, outcome) VALUES ('gateway', 'NOT_FLAGSHIP')$$),
  '42501', 'K1: fao_workflow cannot write workflow_failures directly');
SELECT is(tests.sqlstate_as('fao_workflow', 'SELECT 1 FROM public.workflow_failures'), '42501', 'K1: fao_workflow cannot read workflow_failures');
SELECT is(tests.sqlstate_as('service_role', 'SELECT 1 FROM public.workflow_failures'), '42501', 'K1: service_role holds nothing on workflow_failures');
SELECT is((SELECT count(*) FROM fao_private.grants_drift()), 0::bigint, 'K1: the catalog matches the allow-list');

-- ============================================================================
-- K4: claim fails a stale RUNNING holder of the id, then claims
-- ============================================================================
INSERT INTO v VALUES ('k4_a', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-145-stale')));
SELECT tests.set_clock((SELECT sla_max_execution_seconds + 60 FROM public.agent_registry WHERE agent_id = 'fao_reserve_recon_v1'));
INSERT INTO v VALUES ('k4_b', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('k4_b_claim', tests.claim_raw(pg_temp.tok('k4_b'), 'pgtap-145-stale'));
SELECT tests.set_clock(0);
SELECT is(pg_temp.g('k4_b_claim')->>'code', 'OK', 'K4: a new run claims an id held by a stale RUNNING run');
SELECT is(tests.run_state(pg_temp.c('k4_a')) || '/' || tests.run_state(pg_temp.c('k4_b')), 'FAILED/RUNNING',
  'K4: the stale run is FAILED and the new run RUNNING');
SELECT is((SELECT error_details || '/' || (inputs->>'source') || '/' || (inputs->>'stage') || '/' || (inputs->>'n8n_execution_id')
             FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('k4_a') AND inputs->>'event_type' = 'FAILED'),
  'stale execution id reused by a new n8n execution/sweep/before_request/pgtap-145-stale', 'K4: the stale run gets one FAILED row with the fixed message');
SELECT is((SELECT last_error FROM public.run_invocations WHERE correlation_id = pg_temp.c('k4_a')),
  'stale execution id reused by a new n8n execution', 'K4: the stale run records the fixed message');
INSERT INTO v VALUES ('k4_c', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-145-fresh')));
INSERT INTO v VALUES ('k4_d', tests.start_run('aisha.okonkwo@finagent-os.demo'));
SELECT is(tests.claim_raw(pg_temp.tok('k4_d'), 'pgtap-145-fresh')->>'code', 'ALREADY_CLAIMED', 'K4: a holder inside the window is still ALREADY_CLAIMED');
SELECT is(tests.run_state(pg_temp.c('k4_c')) || '/' || tests.run_state(pg_temp.c('k4_d')) || '/' || tests.ledger_count(pg_temp.c('k4_c'), 'FAILED'),
  'RUNNING/REQUESTED/0', 'K4: the holder inside the window is untouched');

-- ============================================================================
-- K5: replaying the key of an expired run
-- ============================================================================
INSERT INTO v VALUES ('k5_key', to_jsonb(tests.new_key()));
INSERT INTO v VALUES ('k5', tests.start_run('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', pg_temp.g('k5_key')#>>'{}'));
SELECT tests.set_clock(700);
INSERT INTO v VALUES ('k5_r1', tests.start_run('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', pg_temp.g('k5_key')#>>'{}'));
SELECT tests.set_clock(0);
INSERT INTO v VALUES ('k5_r2', tests.start_run('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1', pg_temp.g('k5_key')#>>'{}'));
SELECT is(pg_temp.g('k5_r1')->>'ok' || '/' || (pg_temp.g('k5_r1')->>'code') || '/' || (pg_temp.g('k5_r1')->>'http_status'),
  'false/EXPIRED/410', 'K5: the replay that expires the run is EXPIRED (410)');
SELECT is((pg_temp.g('k5_r1')->>'correlation_id')::uuid, pg_temp.c('k5'), 'K5: the refusal names the run');
SELECT ok(pg_temp.g('k5_r1')->>'run_token' IS NULL AND pg_temp.g('k5_r2')->>'run_token' IS NULL, 'K5: no token');
SELECT is(pg_temp.g('k5_r2')->>'ok' || '/' || (pg_temp.g('k5_r2')->>'code') || '/' || (pg_temp.g('k5_r2')->>'http_status')
          || '/' || ((pg_temp.g('k5_r2')->>'correlation_id')::uuid = pg_temp.c('k5'))::text,
  'false/EXPIRED/410/true', 'K5: a replay of an EXPIRED run is EXPIRED (410) with its correlation id');
SELECT is(tests.run_state(pg_temp.c('k5')), 'EXPIRED', 'K5: the run is EXPIRED');
SELECT is((SELECT code FROM public.fao_refusal_journal WHERE refusal_id = (pg_temp.g('k5_r2')->>'ref')::bigint), 'EXPIRED',
  'K5: the refusal is journaled');

-- ============================================================================
-- U10: reserved inputs keys at any depth and in any letter case
-- ============================================================================
INSERT INTO v VALUES ('u10', jsonb_build_object('correlation_id', tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC', 'ETH', 'SOL'])));
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('u10'), 'BTC'), '{inputs,threshold}', '{"approver_id": "x"}'))),
  'item 0: inputs\.threshold\.approver_id is set only by the database', 'U10: a nested reserved key is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('u10'), 'BTC'), '{inputs,APPROVER_ID}', '"x"'))),
  'item 0: inputs\.APPROVER_ID is set only by the database', 'U10: a reserved key in another letter case is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('u10'), 'BTC'), '{inputs,notes}', '[{"meta": {"Hitl_Id": 1}}]'))),
  'item 0: inputs\.notes\.\[0\]\.meta\.Hitl_Id is set only by the database', 'U10: a reserved key inside an array is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.asset_event(pg_temp.c('u10'), 'BTC'), '{inputs,threshold}', '{"source": "sweep"}'))),
  'item 0: inputs\.threshold\.source is set only by the database', 'U10: a nested source outside fixture provenance is refused');
SELECT is(tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('u10'), 'BTC')))->>'ok', 'true', 'U10: a clean event is still accepted');
INSERT INTO v VALUES ('u10s', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-145-u10s')));
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('u10s'), ARRAY['BTC']), '{inputs,Invoker_ID}', '"x"'))),
  'item 0: inputs\.Invoker_ID is set only by the database', 'U10: STARTED overwrites are exact-spelling only');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('u10s'), ARRAY['BTC']), '{inputs,fixture_provenance}',
                 '{"BTC": {"source": "pgtap", "decision": "APPROVED"}}'))),
  'item 0: inputs\.fixture_provenance\.BTC\.decision is set only by the database', 'U10: other reserved keys in fixture provenance are refused');
SELECT is(tests.append(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('u10s'), ARRAY['BTC']), '{inputs,fixture_provenance}',
                 '{"BTC": {"source": "Kraken PoR", "notes": "pgtap"}}')))->>'ok', 'true',
  'U10: STARTED fixture_provenance.<asset>.source is accepted');
SELECT is((SELECT inputs #>> '{fixture_provenance,BTC,source}' FROM public.shadow_ledger
            WHERE correlation_id = pg_temp.c('u10s') AND inputs->>'event_type' = 'STARTED'), 'Kraken PoR', 'U10: the provenance source is stored');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_build_object('correlation_id', pg_temp.c('u10s'), 'event_type', 'FAILED',
                 'inputs', jsonb_build_object('failed_node', 'Per-Asset Reconcile', 'Source', 'sweep'), 'policy_outcome', 'BLOCKED',
                 'policy_rationale', 'pgtap 145', 'status', 'FAILURE'))),
  'item 0: inputs\.Source is set only by the database', 'U10: FAILED overwrites are exact-spelling only');

-- ============================================================================
-- U16 (c): inputs.asset on STARTED and FAILED is in the run scope
-- ============================================================================
INSERT INTO v VALUES ('u16', jsonb_build_object('correlation_id', pg_temp.claimed('aisha.okonkwo@finagent-os.demo', 'pgtap-145-u16')));
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_build_object('correlation_id', pg_temp.c('u16'), 'event_type', 'FAILED',
                 'inputs', jsonb_build_object('failed_node', 'Init Execution', 'asset', 'BTC'), 'policy_outcome', 'BLOCKED',
                 'policy_rationale', 'pgtap 145', 'status', 'FAILURE'))),
  'item 0: inputs\.asset is not in the run asset scope', 'U16 (c): FAILED naming an asset before STARTED is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('u16'), ARRAY['BTC']), '{inputs,asset}', '"DOGE"'))),
  'item 0: inputs\.asset is not in the run asset scope', 'U16 (c): STARTED naming an asset outside its scope is refused');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('u16'), ARRAY['BTC']), '{inputs,asset}', '7'))),
  'item 0: inputs\.asset is not in the run asset scope', 'U16 (c): a non-string asset on STARTED is refused');
SELECT is(tests.append(jsonb_build_array(jsonb_set(tests.started_event(pg_temp.c('u16'), ARRAY['BTC', 'ETH']), '{inputs,asset}', '"ETH"')))->>'ok', 'true',
  'U16 (c): STARTED naming an asset of its own scope is accepted');
SELECT matches(pg_temp.append_err(jsonb_build_array(jsonb_build_object('correlation_id', pg_temp.c('u16'), 'event_type', 'FAILED',
                 'inputs', jsonb_build_object('failed_node', 'Per-Asset Reconcile', 'asset', 'SOL'), 'policy_outcome', 'BLOCKED',
                 'policy_rationale', 'pgtap 145', 'status', 'FAILURE'))),
  'item 0: inputs\.asset is not in the run asset scope', 'U16 (c): FAILED naming an asset outside the scope is refused');
SELECT is(tests.append(jsonb_build_array(jsonb_build_object('correlation_id', pg_temp.c('u16'), 'event_type', 'FAILED',
                 'inputs', jsonb_build_object('failed_node', 'Per-Asset Reconcile', 'asset', 'BTC'), 'policy_outcome', 'BLOCKED',
                 'policy_rationale', 'pgtap 145', 'status', 'FAILURE')))->>'ok', 'true',
  'U16 (c): FAILED naming an asset in the scope is accepted');

-- ============================================================================
-- U12: a client learns only its own roles, even calling the helpers directly
-- ============================================================================
CREATE TEMP TABLE u12 (k text PRIMARY KEY, b boolean);
GRANT INSERT, SELECT ON u12 TO authenticated;
SELECT tests.as_user('sarah.chen@finagent-os.demo');
INSERT INTO u12 SELECT 'other_role', fao_private.has_role((SELECT po.id FROM public.process_owners po WHERE po.email = 'aisha.okonkwo@finagent-os.demo'), 'invoker', NULL);
INSERT INTO u12 SELECT 'other_any', fao_private.has_any_role((SELECT po.id FROM public.process_owners po WHERE po.email = 'aisha.okonkwo@finagent-os.demo'));
INSERT INTO u12 SELECT 'own_role', fao_private.has_role(auth.uid(), 'invoker', NULL);
INSERT INTO u12 SELECT 'own_any', fao_private.has_any_role(auth.uid());
INSERT INTO u12 SELECT 'rls', (SELECT count(*) FROM public.run_invocations) > 0;
RESET ROLE;
SELECT tests.as_owner();
SELECT is((SELECT b FROM u12 WHERE k = 'other_role'), false, 'U12: has_role about another user, called directly by a client, is false');
SELECT is((SELECT b FROM u12 WHERE k = 'other_any'), false, 'U12: has_any_role about another user, called directly by a client, is false');
SELECT is((SELECT b FROM u12 WHERE k = 'own_role') AND (SELECT b FROM u12 WHERE k = 'own_any'), true, 'U12: a client still learns its own roles');
SELECT is((SELECT b FROM u12 WHERE k = 'rls'), true, 'U12: the member read policies still work');
SELECT is(tests.value_as('sarah.chen@finagent-os.demo',
            format('SELECT fao_private.has_any_role(%L::uuid)::text', tests.uid('aisha.okonkwo@finagent-os.demo'))), 'false',
  'U12: a call through a non-FinAgent function is not trusted');
SELECT is(fao_private.has_role(tests.uid('aisha.okonkwo@finagent-os.demo'), 'invoker', NULL)
          AND fao_private.has_any_role(tests.uid('aisha.okonkwo@finagent-os.demo')), true, 'U12: the owner session is not restricted');
SELECT is(tests.value_as('sarah.chen@finagent-os.demo',
            $$SELECT (public.fao_whoami('{}'::json)->>'ok')$$), 'true', 'U12: SECURITY DEFINER callers keep working');

-- ============================================================================
-- B-28: every function in public and fao_private pins search_path
-- ============================================================================
SELECT is((SELECT string_agg(p.oid::regprocedure::text, ', ')
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname IN ('public', 'fao_private')
              AND NOT EXISTS (SELECT 1 FROM pg_depend d
                               WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
              AND NOT ('search_path=""' = ANY (coalesce(p.proconfig, ARRAY[]::text[])))), NULL,
  'B-28: every function in public and fao_private, legacy included, pins search_path to empty');
SELECT ok((SELECT 'search_path=""' = ANY (proconfig) FROM pg_proc WHERE oid = 'public.shadow_ledger_enforce_append_only()'::regprocedure),
  'B-28: the v1 append-only trigger function is pinned');
SELECT throws_ok($$UPDATE public.shadow_ledger SET policy_rationale = 'x' WHERE ledger_id = (SELECT max(ledger_id) FROM public.shadow_ledger)$$,
  '42501', NULL, 'B-28: the pinned trigger function still refuses UPDATE');

-- ============================================================================
-- F-09: hitl_queue catalog comments describe the current controls
-- ============================================================================
SELECT ok(obj_description('public.hitl_queue'::regclass, 'pg_class') ~ 'hitl_queue_guard_row'
          AND obj_description('public.hitl_queue'::regclass, 'pg_class') !~ 'RLS layer',
  'F-09: the hitl_queue comment names the row guard, not the v1 RLS rule');
SELECT ok(col_description('public.hitl_queue'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.hitl_queue'::regclass AND attname = 'approver_id')) ~ 'fao_hitl_decide'
          AND col_description('public.hitl_queue'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.hitl_queue'::regclass AND attname = 'approver_id')) !~ 'RLS WITH CHECK',
  'F-09: the approver_id comment describes fao_hitl_decide and the guard');
SELECT ok(col_description('public.hitl_queue'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.hitl_queue'::regclass AND attname = 'agent_invoker_id')) ~ 'hitl_no_self_approval'
          AND col_description('public.hitl_queue'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.hitl_queue'::regclass AND attname = 'agent_invoker_id')) !~ 'RLS prevents',
  'F-09: the agent_invoker_id comment describes the guard and the CHECK');

-- ============================================================================
-- F-19: tier, deadline and invoker from the registry and the session (AMBER, GREEN)
-- ============================================================================
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 145 tiers', true);
  UPDATE public.agent_registry SET risk_tier = 'AMBER', sla_max_hitl_resolution_hrs = 7 WHERE agent_id = 'fao_reserve_recon_v1';
  UPDATE public.agent_registry SET risk_tier = 'GREEN', sla_max_hitl_resolution_hrs = 5 WHERE agent_id = 'fao_ratelimit_test_v1';
END $$;
INSERT INTO v VALUES ('f19a', tests.start_run('aisha.okonkwo@finagent-os.demo', 'fao_reserve_recon_v1'));
INSERT INTO v VALUES ('f19a_claim', tests.claim(pg_temp.tok('f19a'), 'pgtap-145-amber'));
SELECT is(tests.append(jsonb_build_array(tests.started_event(pg_temp.c('f19a'), ARRAY['USDT']),
                                         tests.asset_event(pg_temp.c('f19a'), 'USDT', 'REQUIRE_HUMAN', 'STANDARD')))->>'ok', 'true', 'F-19: AMBER run records a review asset');
INSERT INTO v VALUES ('f19a_fin', tests.finalize(pg_temp.c('f19a')));
SELECT is(pg_temp.g('f19a_claim')->>'risk_tier' || '/' || (SELECT risk_tier::text FROM public.run_invocations WHERE correlation_id = pg_temp.c('f19a')),
  'AMBER/AMBER', 'F-19: AMBER from the registry into the claim result and the run');
SELECT is((SELECT string_agg(DISTINCT risk_tier::text, ',') FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('f19a')), 'AMBER',
  'F-19: every ledger row of the AMBER run carries AMBER');
SELECT is((SELECT risk_tier::text || '/' || (agent_invoker_id = tests.uid('aisha.okonkwo@finagent-os.demo'))::text
                  || '/' || (timeout_at = fao_private.clock() + interval '7 hours')::text
             FROM public.hitl_queue WHERE correlation_id = pg_temp.c('f19a')),
  'AMBER/true/true', 'F-19: the AMBER request has the registry tier, the session invoker and the registry deadline');
SELECT is((pg_temp.g('f19a_fin')->>'timeout_at')::timestamptz, fao_private.clock() + interval '7 hours', 'F-19: finalize reports the registry deadline');
INSERT INTO v VALUES ('f19g', tests.start_run('ratelimit@local.test', 'fao_ratelimit_test_v1'));
INSERT INTO v VALUES ('f19g_claim', tests.claim(pg_temp.tok('f19g'), 'pgtap-145-green'));
SELECT is(tests.append(jsonb_build_array(tests.started_event(pg_temp.c('f19g'), ARRAY['USDT']),
                                         tests.asset_event(pg_temp.c('f19g'), 'USDT', 'REQUIRE_HUMAN', 'STANDARD')))->>'ok', 'true', 'F-19: GREEN run records a review asset');
INSERT INTO v VALUES ('f19g_fin', tests.finalize(pg_temp.c('f19g')));
SELECT is(pg_temp.g('f19g_claim')->>'risk_tier' || '/' || (SELECT risk_tier::text FROM public.run_invocations WHERE correlation_id = pg_temp.c('f19g'))
          || '/' || (SELECT string_agg(DISTINCT risk_tier::text, ',') FROM public.shadow_ledger WHERE correlation_id = pg_temp.c('f19g')),
  'GREEN/GREEN/GREEN', 'F-19: GREEN from the registry into the claim, the run and the ledger');
SELECT is((SELECT risk_tier::text || '/' || (agent_invoker_id = tests.uid('ratelimit@local.test'))::text
                  || '/' || (timeout_at = fao_private.clock() + interval '5 hours')::text
             FROM public.hitl_queue WHERE correlation_id = pg_temp.c('f19g')),
  'GREEN/true/true', 'F-19: the GREEN request has the registry tier, the session invoker and the registry deadline');
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 145 tiers back', true);
  UPDATE public.agent_registry SET risk_tier = 'RED', sla_max_hitl_resolution_hrs = 24 WHERE agent_id = 'fao_reserve_recon_v1';
END $$;

-- ============================================================================
-- K2: the invoker is checked again at finalize (destructive, last)
-- ============================================================================
SELECT is(fao_private.code_message('INVOKER_NOT_ACTIVE') || '/' || fao_private.code_http('INVOKER_NOT_ACTIVE'),
  'The invoker is no longer authorised for this agent./409', 'K2: INVOKER_NOT_ACTIVE message and HTTP status');
INSERT INTO v VALUES ('k2a', jsonb_build_object('correlation_id', tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC'])));
INSERT INTO v VALUES ('k2c', jsonb_build_object('correlation_id', tests.make_run('aisha.okonkwo@finagent-os.demo', ARRAY['BTC'])));
INSERT INTO v VALUES ('k2b', jsonb_build_object('correlation_id', tests.make_run('ratelimit@local.test', ARRAY['BTC'], 'fao_ratelimit_test_v1')));
SELECT is((tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('k2a'), 'BTC')))->>'ok')
          || (tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('k2b'), 'BTC')))->>'ok')
          || (tests.append(jsonb_build_array(tests.asset_event(pg_temp.c('k2c'), 'BTC')))->>'ok'), 'truetruetrue', 'K2: three clean runs ready to commit');
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 145 revoke invoker', true);
  UPDATE public.fao_user_roles SET revoked_at = now()
   WHERE user_id = tests.uid('aisha.okonkwo@finagent-os.demo') AND role = 'invoker' AND revoked_at IS NULL;
END $$;
INSERT INTO v VALUES ('k2a_fin', tests.finalize(pg_temp.c('k2a')));
SELECT is(pg_temp.g('k2a_fin')->>'ok' || '/' || (pg_temp.g('k2a_fin')->>'code') || '/' || (pg_temp.g('k2a_fin')->>'http_status')
          || '/' || (pg_temp.g('k2a_fin')->>'state') || '/' || coalesce(pg_temp.g('k2a_fin')->>'committed_ledger_id', 'null'),
  'false/INVOKER_NOT_ACTIVE/409/FAILED/null', 'K2: a revoked invoker''s run is not committed (INVOKER_NOT_ACTIVE, 409)');
SELECT is(pg_temp.g('k2a_fin')->>'message', 'The invoker is no longer authorised for this agent.', 'K2: fixed message');
SELECT is(tests.run_state(pg_temp.c('k2a')) || '/' || tests.ledger_count(pg_temp.c('k2a'), 'COMMIT_BLOCKED') || '/' || tests.ledger_count(pg_temp.c('k2a'), 'COMMITTED'),
  'FAILED/1/0', 'K2: COMMIT_BLOCKED written and the run FAILED');
SELECT is((SELECT (inputs->>'code') || '/' || (inputs->>'reason') FROM public.shadow_ledger
            WHERE correlation_id = pg_temp.c('k2a') AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  'INVOKER_NOT_ACTIVE/INVOKER_NOT_ACTIVE', 'K2: COMMIT_BLOCKED carries inputs.code and inputs.reason');
SELECT is((SELECT code FROM public.fao_refusal_journal WHERE refusal_id = (pg_temp.g('k2a_fin')->>'ref')::bigint), 'INVOKER_NOT_ACTIVE',
  'K2: the refusal is journaled');
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 145 deactivate owner', true);
  UPDATE public.process_owners SET active = false WHERE id = tests.uid('ratelimit@local.test');
END $$;
INSERT INTO v VALUES ('k2b_fin', tests.finalize(pg_temp.c('k2b')));
SELECT is(pg_temp.g('k2b_fin')->>'code' || '/' || tests.run_state(pg_temp.c('k2b')), 'INVOKER_NOT_ACTIVE/FAILED',
  'K2: a deactivated invoker''s run is not committed');
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 145 deprecate', true);
  UPDATE public.agent_registry SET status = 'DEPRECATED' WHERE agent_id = 'fao_reserve_recon_v1';
END $$;
INSERT INTO v VALUES ('k2c_fin', tests.finalize(pg_temp.c('k2c')));
SELECT is(pg_temp.g('k2c_fin')->>'code' || '/' || (SELECT inputs->>'code' FROM public.shadow_ledger
                                                    WHERE correlation_id = pg_temp.c('k2c') AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  'AGENT_NOT_ACTIVE/AGENT_NOT_ACTIVE', 'K2: AGENT_NOT_ACTIVE is checked first when both apply');

SELECT * FROM finish();
ROLLBACK;
