-- ============================================================================
-- FinAgent OS pgTAP 020: fao_hitl_decide
-- Controls: FAO-GOV-004 (session identity, segregation of duties, approver
-- role, decision recorded with HITL_RESOLVED and COMMITTED in one call),
-- FAO-GOV-001 (refusals journaled with actor and attempt).
-- ============================================================================
BEGIN;
SELECT plan(48);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
INSERT INTO v VALUES ('req', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('req2', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('req3', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('journal_before', to_jsonb(tests.journal_total()));

-- Refusals (12 journaled)
INSERT INTO v VALUES ('sod', tests.decide_raw('aisha.okonkwo@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED'));
INSERT INTO v VALUES ('outsider', tests.decide_raw('outsider@local.test', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED'));
INSERT INTO v VALUES ('nonapprover', tests.decide_raw('ratelimit@local.test', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED'));
INSERT INTO v VALUES ('missing', tests.decide_raw('sarah.chen@finagent-os.demo', '999999999', 'APPROVED'));
INSERT INTO v VALUES ('anon', tests.decide_raw('anon', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED'));
INSERT INTO v VALUES ('bad_id', tests.decide_raw('sarah.chen@finagent-os.demo', 'abc', 'APPROVED'));
INSERT INTO v VALUES ('zero_id', tests.decide_raw('sarah.chen@finagent-os.demo', '0', 'APPROVED'));
INSERT INTO v VALUES ('bad_decision', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'MAYBE'));
INSERT INTO v VALUES ('lower_decision', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'approved'));
INSERT INTO v VALUES ('expired_decision', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'EXPIRED'));
INSERT INTO v VALUES ('long_notes', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED', repeat('n', 2001)));
INSERT INTO v VALUES ('ctrl_notes', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED', E'bad\u0001note'));
INSERT INTO v VALUES ('journal_after', to_jsonb(tests.journal_total()));

SELECT is((SELECT j->>'code' FROM v WHERE k = 'sod'), 'SOD_SELF_APPROVAL', 'the invoker deciding their own request gets SOD_SELF_APPROVAL');
SELECT is((SELECT (j->>'http_status')::int FROM v WHERE k = 'sod'), 403, 'SOD_SELF_APPROVAL is 403');
SELECT is((SELECT j->>'message' FROM v WHERE k = 'sod'), 'You cannot decide a run you started.', 'fixed message for SOD_SELF_APPROVAL');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = (SELECT (j::text)::bigint FROM v WHERE k = 'req')), 'PENDING', 'the row stays PENDING after the self-approval attempt');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'outsider'), 'NOT_AUTHORISED', 'Outsider gets NOT_AUTHORISED');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'nonapprover'), 'NOT_AUTHORISED', 'an owner without the approver role gets NOT_AUTHORISED');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'missing'), 'NOT_FOUND', 'a missing id gets NOT_FOUND');
SELECT is((SELECT (j->>'http_status')::int FROM v WHERE k = 'missing'), 404, 'NOT_FOUND is 404');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'anon'), 'NO_SESSION', 'anon gets NO_SESSION');
SELECT is((SELECT (j->>'http_status')::int FROM v WHERE k = 'anon'), 401, 'NO_SESSION is 401');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'bad_id'), 'INVALID_INPUT', 'non-numeric id text is INVALID_INPUT');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'zero_id'), 'INVALID_INPUT', 'id 0 is INVALID_INPUT');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'bad_decision'), 'INVALID_INPUT', 'unknown decision text is INVALID_INPUT');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'lower_decision'), 'INVALID_INPUT', 'lower-case decision is INVALID_INPUT');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'expired_decision'), 'INVALID_INPUT', 'EXPIRED is not a decision a caller may make');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'long_notes'), 'INVALID_INPUT', 'notes over 2000 characters are INVALID_INPUT');
SELECT is((SELECT j->>'code' FROM v WHERE k = 'ctrl_notes'), 'INVALID_INPUT', 'control characters in notes are INVALID_INPUT');
SELECT is((SELECT (j->>'http_status')::int FROM v WHERE k = 'ctrl_notes'), 400, 'INVALID_INPUT is 400');

-- Each refusal adds exactly one journal row
SELECT is((SELECT (j::text)::bigint FROM v WHERE k = 'journal_after') - (SELECT (j::text)::bigint FROM v WHERE k = 'journal_before'), 12::bigint,
  'twelve refusals add exactly twelve journal rows');
SELECT is((SELECT count(DISTINCT (j->>'ref')) FROM v WHERE k IN ('sod','outsider','nonapprover','missing','anon','bad_id','zero_id','bad_decision','lower_decision','expired_decision','long_notes','ctrl_notes') AND j->>'ref' IS NOT NULL),
  12::bigint, 'each refusal returns its own journal reference');

-- The journal row of the self-approval refusal
SELECT is((tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->>'actor_uid')::uuid, tests.uid('aisha.okonkwo@finagent-os.demo'), 'journal actor is the caller from the session');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->>'db_role', 'authenticated', 'journal db role');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->>'session_role', session_user::text, 'journal session role');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->>'entry_point', 'rpc:fao_hitl_decide', 'journal entry point');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->>'target_table', 'hitl_queue', 'journal target table');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->>'target_key', (SELECT j::text FROM v WHERE k = 'req'), 'journal target key is the id');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->'attempted'->>'decision', 'APPROVED', 'journal attempt holds the decision');
SELECT is(tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'sod'))->>'code', 'SOD_SELF_APPROVAL', 'journal code');
SELECT ok((tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'anon'))->>'actor_uid') IS NULL
          AND tests.journal_row((SELECT (j->>'ref')::bigint FROM v WHERE k = 'anon'))->>'db_role' = 'anon',
  'the anonymous refusal is journaled with no actor and db role anon');

-- Success: Sarah approves Aisha's request
INSERT INTO v VALUES ('approve', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED', 'looks right'));
INSERT INTO v VALUES ('corr', to_jsonb(tests.request_corr((SELECT (j::text)::bigint FROM v WHERE k = 'req'))));

SELECT is((SELECT j->>'ok' FROM v WHERE k = 'approve'), 'true', 'the approval succeeds');
SELECT is((SELECT j->>'committed' FROM v WHERE k = 'approve'), 'true', 'the run is committed');
SELECT is((SELECT j->>'decision' FROM v WHERE k = 'approve'), 'APPROVED', 'result carries the decision');
SELECT is((SELECT approver_id FROM public.hitl_queue WHERE hitl_id = (SELECT (j::text)::bigint FROM v WHERE k = 'req')), tests.uid('sarah.chen@finagent-os.demo'), 'the approver is the caller from the session');
SELECT is(tests.ledger_count((SELECT (j#>>'{}')::uuid FROM v WHERE k = 'corr'), 'HITL_RESOLVED'), 1::bigint, 'exactly one HITL_RESOLVED');
SELECT is((SELECT inputs->'approvers' FROM public.shadow_ledger WHERE correlation_id = (SELECT (j#>>'{}')::uuid FROM v WHERE k = 'corr') AND inputs->>'event_type' = 'HITL_RESOLVED'),
  jsonb_build_array(tests.uid('sarah.chen@finagent-os.demo')), 'HITL_RESOLVED approvers[] holds the approver');
SELECT is((SELECT (inputs->>'enforced_approvals')::int FROM public.shadow_ledger WHERE correlation_id = (SELECT (j#>>'{}')::uuid FROM v WHERE k = 'corr') AND inputs->>'event_type' = 'HITL_RESOLVED'),
  1, 'HITL_RESOLVED enforced_approvals = 1');
SELECT is(tests.ledger_count((SELECT (j#>>'{}')::uuid FROM v WHERE k = 'corr'), 'COMMITTED'), 1::bigint, 'exactly one COMMITTED');
SELECT is((SELECT hitl_approver_id FROM public.shadow_ledger WHERE correlation_id = (SELECT (j#>>'{}')::uuid FROM v WHERE k = 'corr') AND inputs->>'event_type' = 'COMMITTED'),
  tests.uid('sarah.chen@finagent-os.demo'), 'COMMITTED names the approver');
SELECT is((SELECT ledger_id FROM public.shadow_ledger WHERE correlation_id = (SELECT (j#>>'{}')::uuid FROM v WHERE k = 'corr') AND inputs->>'event_type' = 'COMMITTED'),
  (SELECT (j->>'committed_ledger_id')::bigint FROM v WHERE k = 'approve'), 'committed_ledger_id is the COMMITTED row');

-- REJECTED gives ROLLED_BACK
INSERT INTO v VALUES ('reject', tests.decide_raw('marcus.patel@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req2'), 'REJECTED'));
SELECT is((SELECT status::text FROM public.shadow_ledger WHERE correlation_id = tests.request_corr((SELECT (j::text)::bigint FROM v WHERE k = 'req2')) AND inputs->>'event_type' = 'COMMITTED'),
  'ROLLED_BACK', 'a rejection commits with status ROLLED_BACK');
SELECT is((SELECT hitl_status::text FROM public.shadow_ledger WHERE correlation_id = tests.request_corr((SELECT (j::text)::bigint FROM v WHERE k = 'req2')) AND inputs->>'event_type' = 'COMMITTED'),
  'REJECTED', 'the rejected COMMITTED row carries hitl_status REJECTED');

-- Workflow and service roles cannot decide; the old function is retired
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'SELECT public.fao_hitl_decide(''1'', ''APPROVED'')')$$, '42501', NULL, 'fao_workflow cannot execute fao_hitl_decide');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'SELECT public.fao_hitl_decide(''1'', ''APPROVED'')')$$, '42501', NULL, 'service_role cannot execute fao_hitl_decide');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'SELECT public.fao_hitl_resolve(1, ''APPROVED'', NULL, NULL)')$$, '42501', NULL, 'fao_workflow cannot execute fao_hitl_resolve');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'SELECT public.fao_hitl_resolve(1, ''APPROVED'', NULL, NULL)')$$, '42501', NULL, 'service_role cannot execute fao_hitl_resolve');
SELECT throws_ok($$SELECT public.fao_hitl_resolve(1, 'APPROVED', NULL, NULL)$$, '42501', 'FAO-GOV-004 fao_hitl_resolve is superseded by fao_hitl_decide', 'fao_hitl_resolve raises the superseded message for the owner');

-- Owner updates without the right session are refused by the row guard
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now() WHERE hitl_id = %s$$,
                        tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'req3')),
  '42501', NULL, 'an owner UPDATE to APPROVED with no session is refused');
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', tests.uid('aisha.okonkwo@finagent-os.demo'), 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', tests.uid('aisha.okonkwo@finagent-os.demo')::text, true);
END $$;
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = agent_invoker_id, decided_at = now() WHERE hitl_id = %s$$,
                        (SELECT j::text FROM v WHERE k = 'req3')),
  '42501', NULL, 'an owner UPDATE naming the invoker as approver (with the invoker''s claims) is refused');
SELECT tests.as_owner();

SELECT * FROM finish();
ROLLBACK;
