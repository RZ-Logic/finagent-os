-- ============================================================================
-- FinAgent OS pgTAP 090: fao_maintenance_sweep and the notification RPCs
-- Controls: FAO-GOV-004 (timeouts, one escalation, no decision after the
-- deadline), FAO-GOV-007 (notification context, record, renotify limit),
-- FAO-GOV-008 (stale and expired runs), FAO-GOV-015 (drift and clock offset
-- reported and journaled once).
-- ============================================================================
BEGIN;
SELECT plan(56);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j::text)::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.corr(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr((SELECT (j::text)::bigint FROM v WHERE k = p_k)) $$;
CREATE FUNCTION pg_temp.rec(p_id bigint, p_kind text, p_level int, p_outcome text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format($q$SELECT public.fao_notification_record(%s::bigint, %L, %s, %L, 'slack', %L, %L)$q$,
    p_id, p_kind, p_level, p_outcome, CASE WHEN p_outcome = 'SENT' THEN '1730900000.0001' END, CASE WHEN p_outcome = 'FAILED' THEN 'pgtap failure' END)) $$;
CREATE FUNCTION pg_temp.ctx(p_id bigint, p_kind text, p_level int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format('SELECT public.fao_notification_context(%s::bigint, %L, %s)', p_id, p_kind, p_level)) $$;
CREATE FUNCTION pg_temp.has_id(p_list jsonb, p_id bigint) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_list, '[]'::jsonb)) e WHERE e->>'hitl_id' = p_id::text) $$;
CREATE FUNCTION pg_temp.has_uuid(p_list jsonb, p_id uuid) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_list, '[]'::jsonb)) e WHERE e #>> '{}' = p_id::text) $$;

-- Phase 0, clock 0: set up requests and runs
INSERT INTO v VALUES ('r1', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('r2', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('r3', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('r4', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('r5', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('r6', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('r7', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rd', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('rd_decide', tests.decide_raw('sarah.chen@finagent-os.demo', pg_temp.id('rd')::text, 'APPROVED'));
INSERT INTO v VALUES ('unclaimed', tests.start_run('sarah.chen@finagent-os.demo'));

-- Notification context
INSERT INTO v VALUES ('ctx6', pg_temp.ctx(pg_temp.id('r6'), 'REQUESTED', 0));
SELECT is(pg_temp.g('ctx6')->>'send', 'true', 'context: a fresh pending request is sendable');
SELECT is(pg_temp.g('ctx6')->'approver_candidates', '[{"name": "Marcus Patel"}, {"name": "Sarah Chen"}]'::jsonb,
  'context: approver candidates are the active approvers by name, without the invoker');
SELECT ok(position('Aisha' IN (pg_temp.g('ctx6'))::text) = 0, 'context: the invoker is never named');
SELECT is(pg_temp.g('ctx6')->>'approval_url', (SELECT approval_url FROM public.hitl_queue WHERE hitl_id = pg_temp.id('r6')), 'context: approval_url is the stored one');
SELECT is(pg_temp.g('ctx6')->>'slack_channel_id', (SELECT value FROM public.fao_settings WHERE key = 'slack_channel_id'), 'context: Slack channel from settings');
SELECT is(pg_temp.g('ctx6')->>'slack_api_base_url', (SELECT value FROM public.fao_settings WHERE key = 'slack_api_base_url'), 'context: Slack base URL from settings');
SELECT ok(pg_temp.ctx(pg_temp.id('r6'), 'ESCALATED', 1)->>'code' = 'NOT_PENDING' AND pg_temp.ctx(pg_temp.id('r6'), 'ESCALATED', 1)->>'send' = 'false',
  'context: ESCALATED without an escalation event is NOT_PENDING');
SELECT ok(pg_temp.ctx(pg_temp.id('rd'), 'REQUESTED', 0)->>'code' = 'NOT_PENDING', 'context: a decided request is NOT_PENDING');
SELECT ok(pg_temp.ctx(999999999, 'REQUESTED', 0)->>'code' = 'NOT_FOUND' AND pg_temp.ctx(999999999, 'REQUESTED', 0)->>'ok' = 'false', 'context: a missing request is NOT_FOUND');
SELECT ok(pg_temp.ctx(pg_temp.id('r6'), 'REQUESTED', 1) ? 'error', 'context: a kind and level outside the contract raises');

-- Notification record: duplicate SENT
INSERT INTO v VALUES ('sent5', pg_temp.rec(pg_temp.id('r5'), 'REQUESTED', 0, 'SENT'));
INSERT INTO v VALUES ('sent5b', pg_temp.rec(pg_temp.id('r5'), 'REQUESTED', 0, 'SENT'));
SELECT ok(pg_temp.g('sent5')->>'ok' = 'true' AND pg_temp.g('sent5')->>'notification_id' IS NOT NULL AND pg_temp.g('sent5')->>'attempt' = '1', 'record: first SENT is recorded as attempt 1');
SELECT ok(pg_temp.g('sent5b')->>'code' = 'ALREADY_SENT' AND pg_temp.g('sent5b')->>'ok' = 'true', 'record: a duplicate SENT returns ALREADY_SENT');
SELECT is((SELECT count(*) FROM public.fao_notifications WHERE hitl_id = pg_temp.id('r5') AND outcome = 'SENT'), 1::bigint, 'record: one SENT row');
SELECT is((SELECT policy_rationale FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r5') AND inputs->>'event_type' = 'NOTIFICATION_SENT'),
  format('FAO-GOV-007 REQUESTED notification SENT for hitl_id %s (attempt 1)', pg_temp.id('r5')), 'record: one NOTIFICATION_SENT with the 2.10 wording');
SELECT ok(pg_temp.ctx(pg_temp.id('r5'), 'REQUESTED', 0)->>'code' = 'ALREADY_SENT' AND pg_temp.ctx(pg_temp.id('r5'), 'REQUESTED', 0)->>'send' = 'false', 'context: after SENT it is ALREADY_SENT');
SELECT ok(pg_temp.rec(pg_temp.id('r5'), 'DECIDED', 0, 'SENT') ? 'error', 'record: an unknown kind raises');

-- Renotify at clock 0: no attempt and young is not listed; a FAILED attempt is
INSERT INTO v VALUES ('fail4', pg_temp.rec(pg_temp.id('r4'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('s0', tests.sweep());
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s0')->'renotify', pg_temp.id('r3')), 'renotify: a request with no attempt is not listed before 5 minutes');
SELECT ok(pg_temp.g('s0')->'renotify' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('r4'), 'attempt', 2)), 'renotify: a request with a FAILED attempt is listed with the next attempt');
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s0')->'renotify', pg_temp.id('r5')), 'renotify: a sent request is not listed');

-- Phase 1, clock 301: renotify limit, stale run
INSERT INTO v VALUES ('stale', to_jsonb(tests.make_run('sarah.chen@finagent-os.demo', ARRAY['BTC'])));
SELECT tests.set_clock(301);
INSERT INTO v VALUES ('s1', tests.sweep());
SELECT ok(pg_temp.g('s1')->'renotify' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('r3'), 'attempt', 1)), 'renotify: after 5 minutes a request with no attempt is listed');
SELECT ok(pg_temp.has_uuid(pg_temp.g('s1')->'failed_runs', (pg_temp.g('stale')#>>'{}')::uuid), 'stale RUNNING run is listed in failed_runs');
SELECT is(tests.run_state((pg_temp.g('stale')#>>'{}')::uuid), 'FAILED', 'stale RUNNING run is FAILED');
SELECT is((SELECT inputs->>'source' || '/' || (inputs->>'failed_node') || '/' || (inputs->>'stage') FROM public.shadow_ledger
           WHERE correlation_id = (pg_temp.g('stale')#>>'{}')::uuid AND inputs->>'event_type' = 'FAILED'),
  'sweep/timeout/before_request', 'stale run: FAILED written by the sweep');

INSERT INTO v VALUES ('f3a', pg_temp.rec(pg_temp.id('r3'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('s2', tests.sweep());
SELECT ok(pg_temp.g('s2')->'renotify' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('r3'), 'attempt', 2)), 'renotify: listed again after one failure');
INSERT INTO v VALUES ('f3b', pg_temp.rec(pg_temp.id('r3'), 'REQUESTED', 0, 'FAILED'));
INSERT INTO v VALUES ('f3c', pg_temp.rec(pg_temp.id('r3'), 'REQUESTED', 0, 'FAILED'));
SELECT is(pg_temp.g('f3c')->>'attempt', '3', 'record: attempts count up');
INSERT INTO v VALUES ('s3', tests.sweep());
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s3')->'renotify', pg_temp.id('r3')), 'renotify: not listed after notify_max_attempts failures');
SELECT ok(pg_temp.g('s3')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('r3'), 'level', 1, 'reason', 'NOTIFICATION_FAILED')),
  'renotify limit: one NOTIFICATION_FAILED escalation is listed');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r3') AND inputs->>'event_type' = 'HITL_ESCALATED'), 1::bigint,
  'renotify limit: one HITL_ESCALATED event');
SELECT is((SELECT inputs->>'reason' || '/' || hitl_status::text FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r3') AND inputs->>'event_type' = 'HITL_ESCALATED'),
  'NOTIFICATION_FAILED/PENDING', 'renotify limit: escalation reason NOTIFICATION_FAILED with hitl_status PENDING');
INSERT INTO v VALUES ('s4', tests.sweep());
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r3') AND inputs->>'event_type' = 'HITL_ESCALATED'), 1::bigint,
  'renotify limit: a later sweep writes no second escalation');
SELECT ok(pg_temp.ctx(pg_temp.id('r3'), 'ESCALATED', 1)->>'send' = 'true', 'context: ESCALATED is sendable once the escalation exists');
SELECT is(pg_temp.ctx(pg_temp.id('r3'), 'ESCALATED', 1)->>'target_name', 'Marcus Patel', 'context: ESCALATED names the escalation target');

-- Phase 2, clock 700: an expired REQUESTED run
SELECT tests.set_clock(700);
INSERT INTO v VALUES ('s5', tests.sweep());
SELECT ok(pg_temp.has_uuid(pg_temp.g('s5')->'expired_runs', (pg_temp.g('unclaimed')->>'correlation_id')::uuid), 'an expired REQUESTED run is listed in expired_runs');
SELECT is(tests.run_state((pg_temp.g('unclaimed')->>'correlation_id')::uuid), 'EXPIRED', 'the expired REQUESTED run is EXPIRED');
SELECT is(tests.ledger_count((pg_temp.g('unclaimed')->>'correlation_id')::uuid), 0::bigint, 'an expired REQUESTED run writes no ledger row');

-- Phase 3, clock 25 hours: deadline passed
SELECT tests.set_clock(90000);
INSERT INTO v VALUES ('r2_decide', tests.decide_raw('sarah.chen@finagent-os.demo', pg_temp.id('r2')::text, 'APPROVED'));
SELECT is(pg_temp.g('r2_decide')->>'code', 'EXPIRED', 'a decision after the deadline returns EXPIRED');
SELECT is((pg_temp.g('r2_decide')->>'http_status')::int, 410, 'EXPIRED is 410');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('r2')), 'PENDING', 'the late decision leaves the row unchanged');

CREATE FUNCTION tests.pgtap_raise_for_hitl() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.hitl_id = TG_ARGV[0]::bigint THEN RAISE EXCEPTION 'pgtap broken item'; END IF;
  RETURN NEW;
END $$;
DO $$ BEGIN
  EXECUTE format('CREATE TRIGGER pgtap_broken_item BEFORE UPDATE ON public.hitl_queue FOR EACH ROW EXECUTE FUNCTION tests.pgtap_raise_for_hitl(%L)', pg_temp.id('r7'));
END $$;
INSERT INTO v VALUES ('s6', tests.sweep());
DROP TRIGGER pgtap_broken_item ON public.hitl_queue;

SELECT ok(pg_temp.has_id(pg_temp.g('s6')->'expired_requests', pg_temp.id('r1')), 'sweep: the overdue request is listed in expired_requests');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('r1')), 'EXPIRED', 'sweep: the overdue request is EXPIRED');
SELECT is((SELECT inputs->>'source' FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r1') AND inputs->>'event_type' = 'HITL_EXPIRED'), 'sweep', 'sweep: one HITL_EXPIRED from the sweep');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r1') AND inputs->>'event_type' = 'HITL_ESCALATED'), 1::bigint, 'sweep: one HITL_ESCALATED');
SELECT is((SELECT inputs->>'reason' || '/' || (inputs->>'target_owner_id') FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r1') AND inputs->>'event_type' = 'HITL_ESCALATED'),
  'TIMEOUT/' || tests.uid('marcus.patel@finagent-os.demo')::text, 'sweep: escalation reason TIMEOUT, target from escalation_to');
SELECT ok(pg_temp.g('s6')->'escalations' @> jsonb_build_array(jsonb_build_object('hitl_id', pg_temp.id('r1'), 'level', 1, 'reason', 'TIMEOUT')), 'sweep: the TIMEOUT escalation is listed');
SELECT is((SELECT status::text || '/' || hitl_status::text || '/' || (inputs->>'decision') FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r1') AND inputs->>'event_type' = 'COMMITTED'),
  'FAILURE/EXPIRED/EXPIRED', 'sweep: COMMITTED with FAILURE for the expired request');
SELECT is(tests.run_state(pg_temp.corr('r1')), 'EXPIRED', 'sweep: the run of the expired request is EXPIRED');
SELECT ok(EXISTS (SELECT 1 FROM jsonb_array_elements(pg_temp.g('s6')->'item_errors') e WHERE e->>'id' = pg_temp.id('r7')::text), 'sweep: the broken item lands in item_errors');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('r7')), 'PENDING', 'sweep: the broken item is left as it was');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('r2')), 'EXPIRED', 'sweep: other items complete despite the broken one');

INSERT INTO v VALUES ('s7', tests.sweep());
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.corr('r1') AND inputs->>'event_type' = 'HITL_ESCALATED'), 1::bigint, 'second sweep: no second escalation');
SELECT ok(NOT pg_temp.has_id(pg_temp.g('s7')->'expired_requests', pg_temp.id('r1')), 'second sweep: the request is not expired again');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = pg_temp.id('r7')), 'EXPIRED', 'second sweep: the formerly broken item now expires');

-- Phase 4: clock offset and planted grant are reported and journaled once
SELECT tests.set_clock(91111);
INSERT INTO v VALUES ('tc_before', to_jsonb(tests.journal_count('TEST_CLOCK_SET')));
INSERT INTO v VALUES ('s8', tests.sweep());
INSERT INTO v VALUES ('s9', tests.sweep());
SELECT is((pg_temp.g('s9')->>'clock_offset_seconds')::int, 91111, 'sweep reports the clock offset');
SELECT is(tests.journal_count('TEST_CLOCK_SET') - (pg_temp.g('tc_before')::text)::bigint, 1::bigint, 'the clock offset is journaled once');

GRANT SELECT ON public.fao_settings TO anon;
INSERT INTO v VALUES ('gd_before', to_jsonb(tests.journal_count('GRANTS_DRIFT')));
INSERT INTO v VALUES ('s10', tests.sweep());
INSERT INTO v VALUES ('s11', tests.sweep());
REVOKE SELECT ON public.fao_settings FROM anon;
SELECT ok((pg_temp.g('s10')->>'grants_drift')::boolean AND (pg_temp.g('s11')->>'grants_drift')::boolean, 'sweep reports a planted extra grant');
SELECT is(tests.journal_count('GRANTS_DRIFT') - (pg_temp.g('gd_before')::text)::bigint, 1::bigint, 'the drift is journaled once');

SELECT * FROM finish();
ROLLBACK;
