-- ============================================================================
-- FinAgent OS pgTAP 141: fix round 1, HITL sweep escalation target
-- Controls: FAO-GOV-004 (the escalation target is never the invoker; when
-- escalation_to is the invoker the target falls back to the process owner;
-- when no eligible target exists the escalation is written with a NULL
-- target and reported in item_errors as NO_ESCALATION_TARGET, once),
-- FAO-GOV-007 (the notifier context never names the invoker as the target
-- and the invoker is never recorded as the recipient), and for B2
-- FAO-GOV-004 (fao_hitl_decide over HTTP accepts only a JSON body; since
-- IC-18 the media-type check is in fao_private.client_args).
-- Flagship agent fao_reserve_recon_v1 is owned by Sarah; seed escalation_to
-- for Sarah is Marcus. Each case sets Sarah's escalation_to before the sweep
-- that decides its target.
-- ============================================================================
BEGIN;
SELECT plan(40);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j::text)::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.corr(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr((SELECT (j::text)::bigint FROM v WHERE k = p_k)) $$;
CREATE FUNCTION pg_temp.rec(p_id bigint, p_kind text, p_level int, p_outcome text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format($q$SELECT public.fao_notification_record(%s::bigint, %L, %s, %L, 'slack', %L, %L)$q$,
    p_id, p_kind, p_level, p_outcome, CASE WHEN p_outcome = 'SENT' THEN '1730900000.0141' END, CASE WHEN p_outcome = 'FAILED' THEN 'pgtap 141 failure' END)) $$;
CREATE FUNCTION pg_temp.ctx(p_id bigint, p_kind text, p_level int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format('SELECT public.fao_notification_context(%s::bigint, %L, %s)', p_id, p_kind, p_level)) $$;
-- Sarah's escalation_to, set as the owner with a change reason (NULL clears it).
CREATE FUNCTION pg_temp.esc_to(p_email text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 141 escalation target case', true);
  UPDATE public.process_owners
     SET escalation_to = CASE WHEN p_email IS NULL THEN NULL ELSE tests.uid(p_email) END
   WHERE email = 'sarah.chen@finagent-os.demo';
END $$;
-- The level-1 HITL_ESCALATED target of a request, as jsonb (JSON null when NULL).
CREATE FUNCTION pg_temp.target(p_k text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT l.inputs->'target_owner_id' FROM public.shadow_ledger l
   WHERE l.correlation_id = pg_temp.corr(p_k) AND l.inputs->>'event_type' = 'HITL_ESCALATED' AND l.inputs->>'level' = '1'
   ORDER BY l.ledger_id DESC LIMIT 1 $$;
CREATE FUNCTION pg_temp.esc_count(p_k text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.shadow_ledger l
   WHERE l.correlation_id = pg_temp.corr(p_k) AND l.inputs->>'event_type' = 'HITL_ESCALATED' $$;
CREATE FUNCTION pg_temp.has_err(p_sweep text, p_step text, p_k text, p_sqlstate text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(pg_temp.g(p_sweep)->'item_errors', '[]'::jsonb)) e
                  WHERE e->>'step' = p_step AND e->>'id' = pg_temp.id(p_k)::text AND e->>'sqlstate' = p_sqlstate) $$;
CREATE FUNCTION pg_temp.any_err(p_sweep text, p_k text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(pg_temp.g(p_sweep)->'item_errors', '[]'::jsonb)) e
                  WHERE e->>'id' = pg_temp.id(p_k)::text) $$;
CREATE FUNCTION pg_temp.uidj(p_email text) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(tests.uid(p_email)::text) $$;

-- Requests at different clock times so each deadline (24 hours) falls in its
-- own sweep: A, E, F, G at 0; B at 10000; C at 20000; D at 30000.
-- Fix round 2 R12: a request with no SENT REQUESTED notice is escalated
-- (NOTIFICATION_FAILED) once the notice window (20 minutes at the default
-- notify_max_attempts) has passed since it was created. The TIMEOUT cases
-- (A, B, C, D) and the planted case G therefore get a SENT notice when they
-- are created, and the NOTIFICATION_FAILED cases E and F run at clock 600:
-- past the 5 minute renotify mark, inside the window, so each target is
-- still decided by the sweep of its own case.
SELECT tests.set_clock(0);
INSERT INTO v VALUES ('rA', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rE', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rF', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
INSERT INTO v VALUES ('rG', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('nA', pg_temp.rec(pg_temp.id('rA'), 'REQUESTED', 0, 'SENT'));
INSERT INTO v VALUES ('nG', pg_temp.rec(pg_temp.id('rG'), 'REQUESTED', 0, 'SENT'));
SELECT tests.set_clock(600);

-- Case E (NOTIFICATION_FAILED): escalation_to is the invoker (Aisha); falls back to the owner (Sarah)
SELECT pg_temp.esc_to('aisha.okonkwo@finagent-os.demo');
INSERT INTO v VALUES ('fE1', pg_temp.rec(pg_temp.id('rE'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('fE2', pg_temp.rec(pg_temp.id('rE'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('fE3', pg_temp.rec(pg_temp.id('rE'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('s1', tests.sweep());
SELECT ok(pg_temp.g('s1')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rE'), 'level', 1, 'reason', 'NOTIFICATION_FAILED')),
  'E: the NOTIFICATION_FAILED escalation is listed');
SELECT is(pg_temp.target('rE'), pg_temp.uidj('sarah.chen@finagent-os.demo'), 'E: escalation_to is the invoker, so the target falls back to the process owner');
SELECT ok(NOT pg_temp.any_err('s1', 'rE'), 'E: a fallback target is not an item error');

-- Case F (NOTIFICATION_FAILED): invoker is the owner and escalation_to is the owner; no eligible target
SELECT pg_temp.esc_to('sarah.chen@finagent-os.demo');
INSERT INTO v VALUES ('fF1', pg_temp.rec(pg_temp.id('rF'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('fF2', pg_temp.rec(pg_temp.id('rF'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('fF3', pg_temp.rec(pg_temp.id('rF'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('s2', tests.sweep());
SELECT ok(pg_temp.g('s2')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rF'), 'level', 1, 'reason', 'NOTIFICATION_FAILED')),
  'F: the escalation is still listed with no eligible target');
SELECT is(pg_temp.target('rF'), 'null'::jsonb, 'F: the target is NULL, never the invoker');
SELECT ok(pg_temp.has_err('s2', 'renotify', 'rF', 'NO_ESCALATION_TARGET'), 'F: reported in item_errors as NO_ESCALATION_TARGET');
INSERT INTO v VALUES ('s3', tests.sweep());
SELECT ok(NOT pg_temp.has_err('s3', 'renotify', 'rF', 'NO_ESCALATION_TARGET'), 'F: a later sweep does not report it again');
SELECT is(pg_temp.esc_count('rF'), 1::bigint, 'F: a later sweep writes no second escalation');
INSERT INTO v VALUES ('ctxF', pg_temp.ctx(pg_temp.id('rF'), 'ESCALATED', 1));
SELECT ok(pg_temp.g('ctxF')->>'send' = 'true' AND pg_temp.g('ctxF')->'target_name' = 'null'::jsonb, 'F: context is sendable and names no target');
SELECT ok(position('Sarah' IN (pg_temp.g('ctxF'))::text) = 0, 'F: context never names the invoker');

-- Case G: a planted escalation event naming the invoker (owner write through the
-- private helper) is not named by the context and not recorded as recipient
SELECT tests.as_owner();
INSERT INTO v VALUES ('planted', to_jsonb(fao_private.append_event(
  pg_temp.corr('rG'), 'HITL_ESCALATED',
  jsonb_build_object('hitl_id', pg_temp.id('rG'), 'level', 1,
                     'target_owner_id', tests.uid('aisha.okonkwo@finagent-os.demo'), 'reason', 'NOTIFICATION_FAILED'),
  'REQUIRE_HUMAN'::public.policy_outcome,
  (SELECT sub_tier FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rG')),
  format('FAO-GOV-004 hitl_id %s escalated to level 1 (%s)', pg_temp.id('rG'), 'NOTIFICATION_FAILED'),
  NULL, 'PENDING'::public.hitl_status, NULL, 'SUCCESS'::public.execution_status, NULL)));
INSERT INTO v VALUES ('ctxG', pg_temp.ctx(pg_temp.id('rG'), 'ESCALATED', 1));
SELECT ok(pg_temp.g('ctxG')->>'send' = 'true' AND pg_temp.g('ctxG')->'target_name' = 'null'::jsonb, 'G: a target equal to the invoker is not named');
SELECT ok(position('Aisha' IN (pg_temp.g('ctxG'))::text) = 0, 'G: context never names the invoker');
INSERT INTO v VALUES ('recG', pg_temp.rec(pg_temp.id('rG'), 'ESCALATED', 1, 'FAILED'));
SELECT ok(pg_temp.g('recG')->>'ok' = 'true'
          AND (SELECT recipient_owner_id FROM public.fao_notifications WHERE notification_id = (pg_temp.g('recG')->>'notification_id')::bigint) IS NULL,
  'G: the invoker is never recorded as the recipient');

SELECT tests.set_clock(10000);
INSERT INTO v VALUES ('rB', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
INSERT INTO v VALUES ('nB', pg_temp.rec(pg_temp.id('rB'), 'REQUESTED', 0, 'SENT'));
SELECT tests.set_clock(20000);
INSERT INTO v VALUES ('rC', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
INSERT INTO v VALUES ('nC', pg_temp.rec(pg_temp.id('rC'), 'REQUESTED', 0, 'SENT'));
SELECT tests.set_clock(30000);
INSERT INTO v VALUES ('rD', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
INSERT INTO v VALUES ('nD', pg_temp.rec(pg_temp.id('rD'), 'REQUESTED', 0, 'SENT'));

-- B2: over HTTP fao_hitl_decide accepts only a JSON body. PostgREST cuts a
-- form-encoded value at a NUL (%00) before the call, so form bodies are
-- refused; request.headers is set here as PostgREST sets it.
INSERT INTO v VALUES ('rH', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
CREATE FUNCTION pg_temp.decide_hdr(p_headers text, p_id text, p_notes text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM set_config('request.headers', p_headers, true);
  r := tests.decide_raw('sarah.chen@finagent-os.demo', p_id, 'APPROVED', p_notes);
  PERFORM set_config('request.headers', '', true);
  RETURN r;
END $$;
INSERT INTO v VALUES ('ii_before', to_jsonb(tests.journal_count('INVALID_INPUT')));
INSERT INTO v VALUES ('hForm', pg_temp.decide_hdr('{"content-type": "application/x-www-form-urlencoded"}', pg_temp.id('rH')::text, 'a'));
SELECT ok(pg_temp.g('hForm')->>'code' = 'INVALID_INPUT' AND pg_temp.g('hForm')->>'http_status' = '400', 'B2: a form-encoded decide is INVALID_INPUT');
SELECT is((SELECT decision::text || '/' || coalesce(decision_notes, '<null>') FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rH')), 'PENDING/<null>',
  'B2: the form-encoded decide leaves the row unchanged');
SELECT is(tests.journal_count('INVALID_INPUT') - (pg_temp.g('ii_before')::text)::bigint, 1::bigint, 'B2: the refusal is journaled');
SELECT is(tests.journal_row((pg_temp.g('hForm')->>'ref')::bigint)->'attempted'->>'invalid_body', 'media_type',
  'B2 (IC-18): the Content-Type check now sits in fao_private.client_args and is journaled as media_type');
SELECT is(pg_temp.decide_hdr('{"content-type": "text/plain"}', pg_temp.id('rH')::text, 'a')->>'code', 'INVALID_INPUT', 'B2: a text/plain decide is INVALID_INPUT');
SELECT is(pg_temp.decide_hdr('not json', pg_temp.id('rH')::text, 'a')->>'code', 'INVALID_INPUT', 'B2: unreadable request headers fail closed');
SELECT is(pg_temp.decide_hdr('{}', '999999999', 'a')->>'code', 'NOT_FOUND', 'B2: no content-type header passes the input check');
INSERT INTO v VALUES ('hJson', pg_temp.decide_hdr('{"content-type": "Application/JSON; charset=utf-8"}', pg_temp.id('rH')::text, 'b2 json notes'));
SELECT ok(pg_temp.g('hJson')->>'ok' = 'true' AND pg_temp.g('hJson')->>'decision' = 'APPROVED'
          AND (SELECT decision_notes FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rH')) = 'b2 json notes',
  'B2: a JSON body (any case, with charset) is decided as before');

-- Case A (TIMEOUT): escalation_to is the invoker (Aisha); falls back to the owner (Sarah)
SELECT pg_temp.esc_to('aisha.okonkwo@finagent-os.demo');
SELECT tests.set_clock(90000);
INSERT INTO v VALUES ('s4', tests.sweep());
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rA')), 'EXPIRED', 'A: the overdue request is EXPIRED');
SELECT is((SELECT (inputs->>'reason') || '/' || (inputs->>'target_owner_id') FROM public.shadow_ledger
            WHERE correlation_id = pg_temp.corr('rA') AND inputs->>'event_type' = 'HITL_ESCALATED'),
  'TIMEOUT/' || tests.uid('sarah.chen@finagent-os.demo')::text, 'A: TIMEOUT escalation falls back to the process owner, not the invoker');
SELECT ok(NOT pg_temp.any_err('s4', 'rA'), 'A: a fallback target is not an item error');
SELECT is(pg_temp.ctx(pg_temp.id('rA'), 'ESCALATED', 1)->>'target_name', 'Sarah Chen', 'A: context names the fallback target');
SELECT ok(pg_temp.esc_count('rE') = 1 AND pg_temp.esc_count('rF') = 1 AND pg_temp.esc_count('rG') = 1
          AND (SELECT count(*) FROM public.hitl_queue WHERE hitl_id IN (pg_temp.id('rE'), pg_temp.id('rF'), pg_temp.id('rG')) AND decision = 'EXPIRED') = 3,
  'E, F, G: expire with no second escalation');

-- Case B (TIMEOUT): the owner is the invoker but escalation_to (Marcus) is not
SELECT pg_temp.esc_to('marcus.patel@finagent-os.demo');
SELECT tests.set_clock(100000);
INSERT INTO v VALUES ('s5', tests.sweep());
SELECT is(pg_temp.target('rB'), pg_temp.uidj('marcus.patel@finagent-os.demo'), 'B: an escalation_to other than the invoker is kept');
SELECT ok(NOT pg_temp.any_err('s5', 'rB'), 'B: no item error');

-- Case C (TIMEOUT): owner is the invoker and escalation_to is the owner (self loop)
SELECT pg_temp.esc_to('sarah.chen@finagent-os.demo');
SELECT tests.set_clock(110000);
INSERT INTO v VALUES ('s6', tests.sweep());
SELECT ok((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rC')) = 'EXPIRED' AND tests.run_state(pg_temp.corr('rC')) = 'EXPIRED',
  'C: the request and its run still expire');
SELECT ok(pg_temp.target('rC') = 'null'::jsonb
          AND (SELECT inputs->>'reason' FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('rC') AND inputs->>'event_type' = 'HITL_ESCALATED') = 'TIMEOUT',
  'C: the TIMEOUT escalation has a NULL target, never the invoker');
SELECT ok(pg_temp.g('s6')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rC'), 'level', 1, 'reason', 'TIMEOUT')),
  'C: the escalation is still listed for the channel notice');
SELECT ok(pg_temp.has_err('s6', 'expire_request', 'rC', 'NO_ESCALATION_TARGET'), 'C: reported in item_errors as NO_ESCALATION_TARGET');
SELECT ok(tests.ledger_count(pg_temp.corr('rC'), 'COMMITTED') = 0
          AND (SELECT status::text || '/' || hitl_status::text || '/' || (inputs->>'committed') FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('rC') AND inputs->>'event_type' = 'HITL_EXPIRED') = 'FAILURE/EXPIRED/false',
  'C: no COMMITTED row; HITL_EXPIRED (FAILURE, committed false) is the expiry record (P3)');
INSERT INTO v VALUES ('ctxC', pg_temp.ctx(pg_temp.id('rC'), 'ESCALATED', 1));
SELECT ok(pg_temp.g('ctxC')->>'send' = 'true' AND pg_temp.g('ctxC')->'target_name' = 'null'::jsonb
          AND position('Sarah' IN (pg_temp.g('ctxC'))::text) = 0, 'C: context names no target and never the invoker');
INSERT INTO v VALUES ('recC', pg_temp.rec(pg_temp.id('rC'), 'ESCALATED', 1, 'SENT'));
SELECT ok((SELECT recipient_owner_id FROM public.fao_notifications WHERE notification_id = (pg_temp.g('recC')->>'notification_id')::bigint) IS NULL,
  'C: the SENT escalation notice has no recipient');

-- Case D (TIMEOUT): owner is the invoker and escalation_to is NULL
SELECT pg_temp.esc_to(NULL);
SELECT tests.set_clock(120000);
INSERT INTO v VALUES ('s7', tests.sweep());
SELECT is(pg_temp.target('rD'), 'null'::jsonb, 'D: no escalation_to and the owner is the invoker: NULL target');
SELECT ok(pg_temp.has_err('s7', 'expire_request', 'rD', 'NO_ESCALATION_TARGET'), 'D: reported in item_errors as NO_ESCALATION_TARGET');
INSERT INTO v VALUES ('s8', tests.sweep());
SELECT ok(NOT pg_temp.any_err('s8', 'rD') AND pg_temp.esc_count('rD') = 1, 'D: a later sweep neither reports it again nor escalates again');

-- Invariants over every request in this file (G was planted by the owner)
SELECT is((SELECT count(*) FROM public.shadow_ledger l JOIN public.hitl_queue h ON h.correlation_id = l.correlation_id
            WHERE h.hitl_id IN (pg_temp.id('rA'), pg_temp.id('rB'), pg_temp.id('rC'), pg_temp.id('rD'), pg_temp.id('rE'), pg_temp.id('rF'))
              AND l.inputs->>'event_type' = 'HITL_ESCALATED'
              AND l.inputs->>'target_owner_id' = h.agent_invoker_id::text), 0::bigint,
  'invariant: no sweep escalation targets the invoker');
SELECT is((SELECT count(*) FROM public.fao_notifications n JOIN public.hitl_queue h ON h.hitl_id = n.hitl_id
            WHERE h.hitl_id IN (pg_temp.id('rA'), pg_temp.id('rB'), pg_temp.id('rC'), pg_temp.id('rD'), pg_temp.id('rE'), pg_temp.id('rF'), pg_temp.id('rG'))
              AND n.recipient_owner_id = h.agent_invoker_id), 0::bigint,
  'invariant: the invoker is never a notification recipient');

SELECT * FROM finish();
ROLLBACK;
