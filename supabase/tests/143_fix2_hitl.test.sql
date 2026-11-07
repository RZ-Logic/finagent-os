-- ============================================================================
-- FinAgent OS pgTAP 143: fix round 2, HITL read scope, agent activation and
-- the notice bound
-- Controls: FAO-GOV-004 (R02: fao_hitl_get gives the decision view only to
-- an approver for the agent, the invoker or an admin; every member still
-- reads the row through the hitl_queue read policy, build spec 2.12; a caller
-- with no role learns nothing), FAO-GOV-014 and FAO-GOV-004 (R10: an agent
-- cannot be made ACTIVE without both SLAs, so an ACTIVE agent can always
-- open a request), FAO-GOV-007 (R12: a request with no SENT notice is
-- escalated once the notice window has passed, even when the notifier never
-- recorded an attempt, and escalation notices are not relisted after the
-- window; the window is 5 minutes times notify_max_attempts + 1, 20 minutes
-- at the default of 3).
-- Clock offsets used: 0, 600 (inside the window), 1500 (past it), then past
-- the 24 hour deadline. created_at and ledger times are now(), the FinAgent
-- clock is now() plus the offset, so an offset is exactly an age.
-- ============================================================================
BEGIN;
SELECT plan(48);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j::text)::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.corr(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr((SELECT (j::text)::bigint FROM v WHERE k = p_k)) $$;
CREATE FUNCTION pg_temp.rec(p_id bigint, p_kind text, p_level int, p_outcome text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format($q$SELECT public.fao_notification_record(%s::bigint, %L, %s, %L, 'slack', %L, %L)$q$,
    p_id, p_kind, p_level, p_outcome, CASE WHEN p_outcome = 'SENT' THEN '1730900000.0143' END, CASE WHEN p_outcome = 'FAILED' THEN 'pgtap 143 failure' END)) $$;
CREATE FUNCTION pg_temp.has_id(p_list jsonb, p_id bigint) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_list, '[]'::jsonb)) e WHERE e->>'hitl_id' = p_id::text) $$;
CREATE FUNCTION pg_temp.esc_count(p_k text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM public.shadow_ledger l
   WHERE l.correlation_id = pg_temp.corr(p_k) AND l.inputs->>'event_type' = 'HITL_ESCALATED' $$;
CREATE FUNCTION pg_temp.marcus(p_sql text) RETURNS jsonb LANGUAGE sql AS $$ SELECT tests.jsonb_as('marcus.patel@finagent-os.demo', p_sql) $$;
-- fao_admin_set_agent as Marcus with a status only.
CREATE FUNCTION pg_temp.set_status(p_who text, p_agent text, p_status text, p_reason text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as(p_who, format($q$SELECT public.fao_admin_set_agent(json_build_object('p_agent_id', %L, 'p_status', %L, 'p_ai_advisory_enabled', NULL, 'p_max_runs_per_hour', NULL, 'p_reason', %L))$q$,
    p_agent, p_status, p_reason)) $$;
-- Owner edit of an agent's SLAs (the audited direct edit path).
CREATE FUNCTION pg_temp.set_sla(p_agent text, p_hrs int, p_secs int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 143 SLA owner edit', true);
  UPDATE public.agent_registry SET sla_max_hitl_resolution_hrs = p_hrs, sla_max_execution_seconds = p_secs WHERE agent_id = p_agent;
END $$;

SELECT tests.set_clock(0);

-- ---------------------------------------------------------------------------
-- R02: fao_hitl_get is the decision view, not a read barrier
-- ---------------------------------------------------------------------------
INSERT INTO v VALUES ('r02', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rl_get', tests.get_raw('ratelimit@local.test', pg_temp.id('r02')::text));
SELECT ok(pg_temp.g('rl_get')->>'code' = 'NOT_AUTHORISED' AND pg_temp.g('rl_get')->>'http_status' = '403' AND NOT pg_temp.g('rl_get') ? 'request',
  'R02: a member with no right to the row gets NOT_AUTHORISED and no request data from fao_hitl_get');
SELECT is(tests.value_as('ratelimit@local.test', format('SELECT count(*) FROM public.hitl_queue WHERE hitl_id = %s', pg_temp.id('r02'))), '1',
  'R02: the same member reads the row through the hitl_queue read policy (spec 2.12, recorded in KNOWN-LIMITS)');
SELECT is(tests.get_raw('ratelimit@local.test', '999999999999')->>'code', 'NOT_FOUND',
  'R02: for that member a missing id is NOT_FOUND (existence is already visible through the read policy)');
SELECT ok(tests.get_raw('mcp.reader@finagent-os.demo', pg_temp.id('r02')::text)->>'code' = 'NOT_AUTHORISED'
          AND tests.value_as('mcp.reader@finagent-os.demo', format('SELECT count(*) FROM public.hitl_queue WHERE hitl_id = %s', pg_temp.id('r02'))) = '1',
  'R02: the reader gets no decision view but reads the row (spec 6.6 110_rls)');
INSERT INTO v VALUES ('out_get', tests.get_raw('outsider@local.test', pg_temp.id('r02')::text));
INSERT INTO v VALUES ('out_miss', tests.get_raw('outsider@local.test', '999999999999'));
SELECT is(pg_temp.g('out_get') - 'ref', pg_temp.g('out_miss') - 'ref',
  'R02: a caller with no role gets the same body for an existing and a missing id');
SELECT is(tests.value_as('outsider@local.test', format('SELECT count(*) FROM public.hitl_queue WHERE hitl_id = %s', pg_temp.id('r02'))), '0',
  'R02: a caller with no role reads no row directly');
INSERT INTO v VALUES ('sarah_get', tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('r02')::text));
SELECT ok(pg_temp.g('sarah_get')->>'ok' = 'true' AND (pg_temp.g('sarah_get')->'request'->>'viewer_can_decide')::boolean
          AND NOT (pg_temp.g('sarah_get')->'request'->>'viewer_is_invoker')::boolean,
  'R02: an approver for the agent gets the decision view');
SELECT ok((tests.get_raw('aisha.okonkwo@finagent-os.demo', pg_temp.id('r02')::text)->'request'->>'viewer_is_invoker')::boolean,
  'R02: the invoker gets the view with viewer_is_invoker');

-- ---------------------------------------------------------------------------
-- R10: no ACTIVE agent without both SLAs
-- ---------------------------------------------------------------------------
INSERT INTO v VALUES ('ii0', to_jsonb(tests.journal_count('INVALID_INPUT')));
INSERT INTO v VALUES ('act0', pg_temp.set_status('marcus.patel@finagent-os.demo', 'fao_close_orchestrator_v1', 'ACTIVE', 'pgtap 143 go live no sla'));
SELECT ok(pg_temp.g('act0')->>'code' = 'INVALID_INPUT' AND pg_temp.g('act0')->>'http_status' = '400' AND pg_temp.g('act0')->>'ok' = 'false',
  'R10: ACTIVE for an agent with no SLAs is INVALID_INPUT');
SELECT is((SELECT status::text FROM public.agent_registry WHERE agent_id = 'fao_close_orchestrator_v1'), 'STUB_DOCUMENTED',
  'R10: the refused activation changes nothing');
SELECT is(tests.journal_count('INVALID_INPUT') - (pg_temp.g('ii0')::text)::bigint, 1::bigint, 'R10: the refusal is journaled once');
SELECT ok((tests.journal_row((pg_temp.g('act0')->>'ref')::bigint)->>'entry_point') = 'rpc:fao_admin_set_agent'
          AND NOT (tests.journal_row((pg_temp.g('act0')->>'ref')::bigint)->'attempted') ? 'invalid_body'
          AND (tests.journal_row((pg_temp.g('act0')->>'ref')::bigint)->'attempted'->>'status') = 'ACTIVE',
  'R10: the journal row is the field rule (no invalid_body) with the attempted status');
SELECT is((SELECT count(*) FROM public.fao_admin_audit WHERE reason LIKE '%pgtap 143 go live no sla%'), 0::bigint, 'R10: no audit row for the refused change');

SELECT pg_temp.set_sla('fao_close_orchestrator_v1', 24, NULL);
SELECT is(pg_temp.set_status('marcus.patel@finagent-os.demo', 'fao_close_orchestrator_v1', 'ACTIVE', 'pgtap 143 hitl sla only')->>'code', 'INVALID_INPUT',
  'R10: the HITL SLA alone is not enough (no execution SLA)');
SELECT pg_temp.set_sla('fao_close_orchestrator_v1', NULL, 300);
SELECT is(pg_temp.set_status('marcus.patel@finagent-os.demo', 'fao_close_orchestrator_v1', 'ACTIVE', 'pgtap 143 exec sla only')->>'code', 'INVALID_INPUT',
  'R10: the execution SLA alone is not enough (no HITL SLA)');
SELECT is(pg_temp.set_status('sarah.chen@finagent-os.demo', 'fao_close_orchestrator_v1', 'ACTIVE', 'pgtap 143 not admin')->>'code', 'NOT_AUTHORISED',
  'R10: a non-admin is refused before the SLA check');
SELECT is(pg_temp.set_status('marcus.patel@finagent-os.demo', 'fao_no_such_agent', 'ACTIVE', 'pgtap 143 missing')->>'code', 'NOT_FOUND',
  'R10: a missing agent is NOT_FOUND before the SLA check');
SELECT is(pg_temp.set_status('marcus.patel@finagent-os.demo', 'fao_treasury_monitor_v1', 'DEPRECATED', 'pgtap 143 deprecate')->>'ok', 'true',
  'R10: a status other than ACTIVE needs no SLA');
SELECT is(pg_temp.set_status('marcus.patel@finagent-os.demo', 'fao_reserve_recon_v1', 'ACTIVE', 'pgtap 143 flagship stays active')->>'ok', 'true',
  'R10: an agent with both SLAs can be set ACTIVE');

SELECT pg_temp.set_sla('fao_close_orchestrator_v1', 24, 300);
INSERT INTO v VALUES ('act1', pg_temp.set_status('marcus.patel@finagent-os.demo', 'fao_close_orchestrator_v1', 'ACTIVE', 'pgtap 143 go live with sla'));
SELECT ok(pg_temp.g('act1')->>'ok' = 'true' AND pg_temp.g('act1')->'after'->>'status' = 'ACTIVE'
          AND pg_temp.g('act1')->'before'->>'status' = 'STUB_DOCUMENTED',
  'R10: with both SLAs set the agent becomes ACTIVE');
SELECT is((SELECT count(*) FROM public.fao_admin_audit WHERE reason LIKE '%pgtap 143 go live with sla%'), 1::bigint, 'R10: the activation is audited');
INSERT INTO v VALUES ('rCO', to_jsonb(tests.make_run('sarah.chen@finagent-os.demo', ARRAY['USDT'], 'fao_close_orchestrator_v1')));
SELECT ok(tests.append(jsonb_build_array(tests.asset_event((pg_temp.g('rCO')#>>'{}')::uuid, 'USDT', 'REQUIRE_HUMAN', 'STANDARD')))->>'ok' = 'true'
          AND (tests.finalize((pg_temp.g('rCO')#>>'{}')::uuid)->>'hitl_required')::boolean,
  'R10: the activated agent opens a request (the R10 failure scenario no longer raises)');

-- ---------------------------------------------------------------------------
-- R12: the notice window
-- ---------------------------------------------------------------------------
-- rN: no attempt ever recorded; rM: one FAILED attempt, then nothing;
-- rS: SENT; rP: SENT, with a level-1 escalation and no notice attempt;
-- rX: SENT, left to expire.
SELECT tests.set_clock(0);
INSERT INTO v VALUES ('rN', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rM', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rS', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rP', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rX', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('fM', pg_temp.rec(pg_temp.id('rM'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('sS', pg_temp.rec(pg_temp.id('rS'), 'REQUESTED', 0, 'SENT'));
INSERT INTO v VALUES ('sP', pg_temp.rec(pg_temp.id('rP'), 'REQUESTED', 0, 'SENT'));
INSERT INTO v VALUES ('sX', pg_temp.rec(pg_temp.id('rX'), 'REQUESTED', 0, 'SENT'));
SELECT tests.as_owner();
INSERT INTO v VALUES ('plantP', to_jsonb(fao_private.append_event(
  pg_temp.corr('rP'), 'HITL_ESCALATED',
  jsonb_build_object('hitl_id', pg_temp.id('rP'), 'level', 1,
                     'target_owner_id', tests.uid('marcus.patel@finagent-os.demo'), 'reason', 'NOTIFICATION_FAILED'),
  'REQUIRE_HUMAN'::public.policy_outcome,
  (SELECT sub_tier FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rP')),
  format('FAO-GOV-004 hitl_id %s escalated to level 1 (%s)', pg_temp.id('rP'), 'NOTIFICATION_FAILED'),
  NULL, 'PENDING'::public.hitl_status, NULL, 'SUCCESS'::public.execution_status, NULL)));

-- Clock 0: nothing is due yet except rM's failed attempt
INSERT INTO v VALUES ('s0', tests.sweep());
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s0')->'renotify', pg_temp.id('rN')) AND NOT pg_temp.has_id(pg_temp.g('s0')->'escalations', pg_temp.id('rN')),
  'R12: a young request with no attempt is neither renotified nor escalated');
SELECT ok(pg_temp.g('s0')->'renotify' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rM'), 'attempt', 2)),
  'R12: a FAILED attempt inside the window is renotified with the next attempt');
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s0')->'escalations', pg_temp.id('rP')), 'R12: an escalation younger than 5 minutes with no attempt is not listed yet');

-- Clock 600: inside the window, spec 3.7 behaviour is unchanged
SELECT tests.set_clock(600);
INSERT INTO v VALUES ('s1', tests.sweep());
SELECT ok(pg_temp.g('s1')->'renotify' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rN'), 'attempt', 1)),
  'R12: inside the window a request with no attempt is renotified as attempt 1');
SELECT is(pg_temp.esc_count('rN'), 0::bigint, 'R12: inside the window it is not escalated');
SELECT ok(pg_temp.g('s1')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rP'), 'level', 1, 'reason', 'NOTIFICATION_FAILED')),
  'R12: inside the window an escalation with no notice attempt is listed again');
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s1')->'renotify', pg_temp.id('rS')) AND NOT pg_temp.has_id(pg_temp.g('s1')->'escalations', pg_temp.id('rS')),
  'R12: a SENT request is neither renotified nor escalated');

-- Clock 1500: past the window
SELECT tests.set_clock(1500);
INSERT INTO v VALUES ('s2', tests.sweep());
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s2')->'renotify', pg_temp.id('rN')), 'R12: past the window a request with no attempt is not renotified');
SELECT ok(pg_temp.g('s2')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rN'), 'level', 1, 'reason', 'NOTIFICATION_FAILED')),
  'R12: past the window a request whose notifier never recorded an attempt is escalated');
SELECT is((SELECT (inputs->>'reason') || '/' || hitl_status::text || '/' || (inputs->>'target_owner_id') FROM public.shadow_ledger
            WHERE correlation_id = pg_temp.corr('rN') AND inputs->>'event_type' = 'HITL_ESCALATED'),
  'NOTIFICATION_FAILED/PENDING/' || tests.uid('marcus.patel@finagent-os.demo')::text,
  'R12: one HITL_ESCALATED, reason NOTIFICATION_FAILED, hitl_status PENDING, target from escalation_to');
SELECT ok(pg_temp.g('s2')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rM'), 'level', 1, 'reason', 'NOTIFICATION_FAILED'))
          AND NOT pg_temp.has_id(pg_temp.g('s2')->'renotify', pg_temp.id('rM')),
  'R12: past the window a request with failures below notify_max_attempts is escalated, not renotified');
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s2')->'escalations', pg_temp.id('rP')), 'R12: past the window an escalation with no notice attempt is not listed again');
SELECT is(pg_temp.esc_count('rS'), 0::bigint, 'R12: a SENT request is never escalated by the window');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rN')), 'PENDING', 'R12: the escalation leaves the request PENDING');

INSERT INTO v VALUES ('s3', tests.sweep());
SELECT ok(pg_temp.esc_count('rN') = 1 AND pg_temp.esc_count('rM') = 1, 'R12: a later sweep writes no second escalation');
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s3')->'renotify', pg_temp.id('rN')) AND NOT pg_temp.has_id(pg_temp.g('s3')->'escalations', pg_temp.id('rN'))
          AND NOT pg_temp.has_id(pg_temp.g('s3')->'renotify', pg_temp.id('rM')) AND NOT pg_temp.has_id(pg_temp.g('s3')->'escalations', pg_temp.id('rM')),
  'R12: a later sweep lists neither request again');

-- Past the deadline: the TIMEOUT notice of an expired request is bounded too
SELECT tests.set_clock(86500);
INSERT INTO v VALUES ('s4', tests.sweep());
SELECT ok(pg_temp.has_id(pg_temp.g('s4')->'expired_requests', pg_temp.id('rX'))
          AND pg_temp.g('s4')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('rX'), 'level', 1, 'reason', 'TIMEOUT')),
  'R12: the overdue request expires and its TIMEOUT escalation is listed once (step 3)');
SELECT ok((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('rN')) = 'EXPIRED' AND pg_temp.esc_count('rN') = 1,
  'R12: the escalated request expires without a second escalation');
SELECT tests.set_clock(86600);
INSERT INTO v VALUES ('s5', tests.sweep());
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s5')->'escalations', pg_temp.id('rX')),
  'R12: the expired request''s TIMEOUT notice, never recorded, is not relisted once the window has passed');
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s5')->'escalations', pg_temp.id('rN')) AND NOT pg_temp.has_id(pg_temp.g('s5')->'escalations', pg_temp.id('rM')),
  'R12: expired requests are not relisted either');

-- Notifier context and record still work after a window escalation
SELECT is(tests.jsonb_as('fao_workflow', format('SELECT public.fao_notification_context(%s::bigint, %L, %s)', pg_temp.id('rM'), 'ESCALATED', 1))->>'target_name', 'Marcus Patel',
  'R12: the window escalation names its target for the notifier');
SELECT ok(pg_temp.rec(pg_temp.id('rM'), 'ESCALATED', 1, 'SENT')->>'ok' = 'true', 'R12: its escalation notice can be recorded as SENT');

-- ---------------------------------------------------------------------------
-- R11 (closed by IC-18): a form-encoded admin call is refused, not cut.
-- Over HTTP PostgREST cannot route a form body to the one json parameter
-- (404); the media type check in client_args is the defence in depth, set
-- here as PostgREST sets request.headers.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.form_call(p_rpc text, p_body json) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM set_config('request.headers', '{"content-type": "application/x-www-form-urlencoded"}', true);
  r := tests.rpc_body('marcus.patel@finagent-os.demo', p_rpc, p_body);
  PERFORM set_config('request.headers', '', true);
  RETURN r;
END $$;
INSERT INTO v VALUES ('lc_before', to_jsonb((SELECT count(*) FROM public.shadow_ledger WHERE inputs->>'event_type' = 'CORRECTION')));
INSERT INTO v VALUES ('form_lc', pg_temp.form_call('fao_ledger_correct',
  json_build_object('p_ledger_id', (SELECT max(ledger_id)::text FROM public.shadow_ledger), 'p_reason', 'duplicate')));
SELECT ok(pg_temp.g('form_lc')->>'code' = 'INVALID_INPUT'
          AND tests.journal_row((pg_temp.g('form_lc')->>'ref')::bigint)->'attempted'->>'invalid_body' = 'media_type'
          AND (SELECT count(*) FROM public.shadow_ledger WHERE inputs->>'event_type' = 'CORRECTION') = (pg_temp.g('lc_before')::text)::bigint,
  'R11: a form-encoded fao_ledger_correct is INVALID_INPUT (media_type) and writes no CORRECTION');
INSERT INTO v VALUES ('form_ag', pg_temp.form_call('fao_admin_set_agent',
  json_build_object('p_agent_id', 'fao_reserve_recon_v1', 'p_status', NULL, 'p_ai_advisory_enabled', NULL, 'p_max_runs_per_hour', '9', 'p_reason', 'pgtap 143 form')));
SELECT ok(pg_temp.g('form_ag')->>'code' = 'INVALID_INPUT'
          AND (SELECT count(*) FROM public.fao_admin_audit WHERE reason LIKE '%pgtap 143 form%') = 0,
  'R11: a form-encoded admin change is INVALID_INPUT and not audited');

-- Invariants over the requests of this file
SELECT is((SELECT count(*) FROM public.shadow_ledger l JOIN public.hitl_queue h ON h.correlation_id = l.correlation_id
            WHERE h.hitl_id IN (pg_temp.id('rN'), pg_temp.id('rM'), pg_temp.id('rS'), pg_temp.id('rX'))
              AND l.inputs->>'event_type' = 'HITL_ESCALATED'
              AND l.inputs->>'target_owner_id' = h.agent_invoker_id::text), 0::bigint,
  'invariant: no escalation targets the invoker');
SELECT ok(pg_temp.esc_count('rN') = 1 AND pg_temp.esc_count('rM') = 1 AND pg_temp.esc_count('rS') = 1 AND pg_temp.esc_count('rX') = 1
          AND (SELECT inputs->>'reason' FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('rS') AND inputs->>'event_type' = 'HITL_ESCALATED') = 'TIMEOUT',
  'invariant: one escalation per request (window for rN and rM, TIMEOUT at expiry for rS and rX)');

SELECT * FROM finish();
ROLLBACK;
