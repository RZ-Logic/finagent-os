-- ============================================================================
-- FinAgent OS pgTAP 110: row-level security and read paths
-- Controls: FAO-GOV-004 (only members read requests; the request page gives
-- the same refusal for existing, decided and missing ids), FAO-GOV-001
-- (journal, audit, notifications and settings readable by admin and reader
-- only, also against members with other roles), FAO-GOV-015
-- (the reader user is read-only).
-- ============================================================================
BEGIN;
SELECT plan(53);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.n(p_who text, p_rel text) RETURNS bigint LANGUAGE sql AS $$
  SELECT tests.value_as(p_who, format('SELECT count(*) FROM %s', p_rel))::bigint $$;
CREATE FUNCTION pg_temp.own(p_rel text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint; BEGIN EXECUTE format('SELECT count(*) FROM %s', p_rel) INTO n; RETURN n; END $$;

-- Data in every table
INSERT INTO v VALUES ('pending', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('decided', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('decide', tests.decide_raw('sarah.chen@finagent-os.demo', pg_temp.g('decided')::text, 'APPROVED'));
INSERT INTO v VALUES ('sent', tests.jsonb_as('fao_workflow', format($$SELECT public.fao_notification_record(%s::bigint, 'REQUESTED', 0, 'SENT', 'slack', 'ts1', NULL)$$, pg_temp.g('pending')::text)));
INSERT INTO v VALUES ('refusal', tests.decide_raw('anon', '1', 'APPROVED'));
SELECT ok(pg_temp.own('public.fao_admin_audit') > 0 AND pg_temp.own('public.fao_notifications') > 0 AND pg_temp.own('public.fao_refusal_journal') > 0
          AND pg_temp.own('public.fao_settings') > 0,
  'setup: every read table has rows');

-- Outsider sees nothing
SELECT is(pg_temp.n('outsider@local.test', 'public.hitl_queue'), 0::bigint, 'Outsider sees no hitl_queue rows');
SELECT is(pg_temp.n('outsider@local.test', 'public.shadow_ledger'), 0::bigint, 'Outsider sees no shadow_ledger rows');
SELECT is(pg_temp.n('outsider@local.test', 'public.run_invocations'), 0::bigint, 'Outsider sees no run_invocations rows');
SELECT is(pg_temp.n('outsider@local.test', 'public.fao_refusal_journal'), 0::bigint, 'Outsider sees no journal rows');
SELECT is(pg_temp.n('outsider@local.test', 'public.fao_admin_audit'), 0::bigint, 'Outsider sees no audit rows');
SELECT is(pg_temp.n('outsider@local.test', 'public.fao_notifications'), 0::bigint, 'Outsider sees no notification rows');
SELECT is(pg_temp.n('outsider@local.test', 'public.fao_settings'), 0::bigint, 'Outsider sees no settings rows');
SELECT is(pg_temp.n('outsider@local.test', 'public.fao_run_summary'), 0::bigint, 'Outsider sees no fao_run_summary rows');

-- Members see requests, ledger and runs
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.hitl_queue'), pg_temp.own('public.hitl_queue'), 'a member sees hitl_queue');
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.shadow_ledger'), pg_temp.own('public.shadow_ledger'), 'a member sees shadow_ledger');
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.run_invocations'), pg_temp.own('public.run_invocations'), 'a member sees run_invocations');

-- R24 (FAO-GOV-001, FAO-GOV-015): journal, audit, notifications and settings
-- are admin or reader only; a member with a role but neither of those sees
-- none of them (Outsider alone cannot tell this from the member predicate)
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.fao_refusal_journal'), 0::bigint, 'R24: Sarah (invoker and approver) sees no journal rows');
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.fao_admin_audit'), 0::bigint, 'R24: Sarah (invoker and approver) sees no audit rows');
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.fao_notifications'), 0::bigint, 'R24: Sarah (invoker and approver) sees no notification rows');
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.fao_settings'), 0::bigint, 'R24: Sarah (invoker and approver) sees no settings rows');
SELECT is(pg_temp.n('aisha.okonkwo@finagent-os.demo', 'public.fao_refusal_journal'), 0::bigint, 'R24: Aisha (invoker) sees no journal rows');
SELECT is(pg_temp.n('aisha.okonkwo@finagent-os.demo', 'public.fao_admin_audit'), 0::bigint, 'R24: Aisha (invoker) sees no audit rows');
SELECT is(pg_temp.n('aisha.okonkwo@finagent-os.demo', 'public.fao_notifications'), 0::bigint, 'R24: Aisha (invoker) sees no notification rows');
SELECT is(pg_temp.n('aisha.okonkwo@finagent-os.demo', 'public.fao_settings'), 0::bigint, 'R24: Aisha (invoker) sees no settings rows');
SELECT is(pg_temp.n('ratelimit@local.test', 'public.fao_refusal_journal'), 0::bigint, 'R24: the rate-limit owner (invoker, not approver) sees no journal rows');
SELECT is(pg_temp.n('ratelimit@local.test', 'public.fao_admin_audit'), 0::bigint, 'R24: the rate-limit owner (invoker, not approver) sees no audit rows');
SELECT is(pg_temp.n('ratelimit@local.test', 'public.fao_notifications'), 0::bigint, 'R24: the rate-limit owner (invoker, not approver) sees no notification rows');
SELECT is(pg_temp.n('ratelimit@local.test', 'public.fao_settings'), 0::bigint, 'R24: the rate-limit owner (invoker, not approver) sees no settings rows');

-- The reader sees every read table and the summary view
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.hitl_queue'), pg_temp.own('public.hitl_queue'), 'reader sees hitl_queue');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.shadow_ledger'), pg_temp.own('public.shadow_ledger'), 'reader sees shadow_ledger');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.run_invocations'), pg_temp.own('public.run_invocations'), 'reader sees run_invocations');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.fao_refusal_journal'), pg_temp.own('public.fao_refusal_journal'), 'reader sees the journal');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.fao_admin_audit'), pg_temp.own('public.fao_admin_audit'), 'reader sees the audit');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.fao_notifications'), pg_temp.own('public.fao_notifications'), 'reader sees notifications');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.fao_settings'), pg_temp.own('public.fao_settings'), 'reader sees settings');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.fao_user_roles'), pg_temp.own('public.fao_user_roles'), 'reader sees every role row');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.fao_run_summary'), pg_temp.own('public.fao_run_summary'), 'reader sees fao_run_summary');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.agent_registry'), pg_temp.own('public.agent_registry'), 'reader sees agent_registry');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.process_owners'), pg_temp.own('public.process_owners'), 'reader sees process_owners');
SELECT is(pg_temp.n('mcp.reader@finagent-os.demo', 'public.materiality_thresholds'), pg_temp.own('public.materiality_thresholds'), 'reader sees materiality_thresholds');

-- The reader cannot write or call workflow RPCs
SELECT throws_ok($$SELECT tests.do_as('mcp.reader@finagent-os.demo', 'UPDATE public.fao_settings SET value = ''x'' WHERE key = ''notify_max_attempts''')$$, '42501', NULL, 'reader cannot update settings');
SELECT throws_ok($$SELECT tests.do_as('mcp.reader@finagent-os.demo', 'UPDATE public.agent_registry SET max_runs_per_hour = 1')$$, '42501', NULL, 'reader cannot update agent_registry');
SELECT throws_ok($$SELECT tests.do_as('mcp.reader@finagent-os.demo', 'DELETE FROM public.hitl_queue')$$, '42501', NULL, 'reader cannot delete from hitl_queue');
SELECT throws_ok($$SELECT tests.do_as('mcp.reader@finagent-os.demo', 'SELECT public.fao_run_claim(''x'', ''y'', ''fao_reserve_recon_v1'')')$$, '42501', NULL, 'reader cannot execute fao_run_claim');
SELECT throws_ok($$SELECT tests.do_as('mcp.reader@finagent-os.demo', 'SELECT public.fao_maintenance_sweep()')$$, '42501', NULL, 'reader cannot execute fao_maintenance_sweep');
SELECT is(tests.decide_raw('mcp.reader@finagent-os.demo', pg_temp.g('pending')::text, 'APPROVED')->>'code', 'NOT_AUTHORISED', 'reader cannot decide');

-- fao_hitl_get gives one refusal body for existing, decided and missing ids
INSERT INTO v VALUES ('g_out_p', tests.get_raw('outsider@local.test', pg_temp.g('pending')::text));
INSERT INTO v VALUES ('g_out_d', tests.get_raw('outsider@local.test', pg_temp.g('decided')::text));
INSERT INTO v VALUES ('g_out_m', tests.get_raw('outsider@local.test', '999999999'));
INSERT INTO v VALUES ('g_rd_p', tests.get_raw('mcp.reader@finagent-os.demo', pg_temp.g('pending')::text));
INSERT INTO v VALUES ('g_rd_d', tests.get_raw('mcp.reader@finagent-os.demo', pg_temp.g('decided')::text));
INSERT INTO v VALUES ('g_rd_m', tests.get_raw('mcp.reader@finagent-os.demo', '999999999'));
SELECT ok(pg_temp.g('g_out_p')->>'code' = 'NOT_AUTHORISED' AND (pg_temp.g('g_out_p')->>'http_status')::int = 403, 'get: Outsider on an existing id is 403 NOT_AUTHORISED');
SELECT is(pg_temp.g('g_out_d') - 'ref', pg_temp.g('g_out_p') - 'ref', 'get: Outsider on a decided id gets the same body');
SELECT is(pg_temp.g('g_out_m') - 'ref', pg_temp.g('g_out_p') - 'ref', 'get: Outsider on a missing id gets the same body');
SELECT is(pg_temp.g('g_rd_p') - 'ref', pg_temp.g('g_out_p') - 'ref', 'get: the reader on an existing id gets the same body');
SELECT is(pg_temp.g('g_rd_d') - 'ref', pg_temp.g('g_out_p') - 'ref', 'get: the reader on a decided id gets the same body');
SELECT is(pg_temp.g('g_rd_m') - 'ref', pg_temp.g('g_out_p') - 'ref', 'get: the reader on a missing id gets the same body');

-- Members get the request with the right viewer flags
INSERT INTO v VALUES ('g_sarah', tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.g('pending')::text));
INSERT INTO v VALUES ('g_aisha', tests.get_raw('aisha.okonkwo@finagent-os.demo', pg_temp.g('pending')::text));
SELECT ok(pg_temp.g('g_sarah')->'request'->>'viewer_can_decide' = 'true' AND pg_temp.g('g_sarah')->'request'->>'viewer_is_invoker' = 'false', 'get: an approver may decide');
SELECT ok(pg_temp.g('g_aisha')->'request'->>'viewer_can_decide' = 'false' AND pg_temp.g('g_aisha')->'request'->>'viewer_is_invoker' = 'true', 'get: the invoker sees the request but may not decide');

-- fao_user_roles shows a member only their own rows
SELECT is(tests.value_as('sarah.chen@finagent-os.demo', format('SELECT count(*) FROM public.fao_user_roles WHERE user_id <> %L', tests.uid('sarah.chen@finagent-os.demo')))::bigint,
  0::bigint, 'a member sees no other user''s role rows');
SELECT is(pg_temp.n('sarah.chen@finagent-os.demo', 'public.fao_user_roles'),
  (SELECT count(*) FROM public.fao_user_roles WHERE user_id = tests.uid('sarah.chen@finagent-os.demo')), 'a member sees all of their own role rows');
SELECT is(pg_temp.n('marcus.patel@finagent-os.demo', 'public.fao_user_roles'), pg_temp.own('public.fao_user_roles'), 'an admin sees every role row');

SELECT * FROM finish();
ROLLBACK;
