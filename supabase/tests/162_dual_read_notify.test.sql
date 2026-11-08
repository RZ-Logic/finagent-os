-- ============================================================================
-- FinAgent OS pgTAP 162: dual approval, read view, notices, sweep and the
-- run summary view
-- Controls:
--   FAO-GOV-004, FAO-GOV-007: fao_hitl_get adds approvals_received (counted)
--     and viewer_has_approved (raw) to the full form only; the short forms
--     and every top-level key set stay; viewer_can_decide needs a qualifying
--     approver grant (DA-4); reads never write.
--   FAO-GOV-007: fao_notification_context send:true adds
--     enforced_approvals, approvals_received and approved_by (counted
--     approvers by name, never the invoker); every send:false envelope
--     keeps its keys.
--   FAO-GOV-004: a partially approved request expires like any PENDING
--     request (no COMMITTED, approval rows kept, HITL_EXPIRED unchanged).
--   FAO-GOV-015, FAO-GOV-008: fao_run_summary adds enforced_approvals and
--     approvals_recorded after the 18 core columns; read-only for everyone.
-- Users as in 160 (A Aisha invoker, B Sarah, C Marcus, L ratelimit).
-- Clock: 0 for the reads and notices, then 90000 (past the 24 hour
-- deadline) for the sweep cases.
-- ============================================================================
BEGIN;
SELECT plan(53);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j#>>'{}')::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.rc(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr(pg_temp.id(p_k)) $$;
CREATE FUNCTION pg_temp.keys(p_j jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_j) AS k $$;
CREATE FUNCTION pg_temp.e(p text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE p WHEN 'A' THEN 'aisha.okonkwo@finagent-os.demo' WHEN 'B' THEN 'sarah.chen@finagent-os.demo'
                WHEN 'C' THEN 'marcus.patel@finagent-os.demo' WHEN 'L' THEN 'ratelimit@local.test' END $$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.uid(pg_temp.e(p)) $$;
CREATE FUNCTION pg_temp.dec(p_who text, p_k text, p_decision text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.decide_raw(pg_temp.e(p_who), pg_temp.id(p_k)::text, p_decision) $$;
CREATE FUNCTION pg_temp.get(p_who text, p_k text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.get_raw(pg_temp.e(p_who), pg_temp.id(p_k)::text) $$;
CREATE FUNCTION pg_temp.crit(p_k text, p_who text DEFAULT 'A') RETURNS void LANGUAGE sql AS $$
  INSERT INTO v VALUES (p_k, to_jsonb(tests.make_critical_request(pg_temp.e(p_who)))) $$;
CREATE FUNCTION pg_temp.ctx(p_id bigint, p_kind text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format('SELECT public.fao_notification_context(%s::bigint, %L, %s)', p_id, p_kind,
                                               CASE WHEN p_kind = 'REQUESTED' THEN 0 ELSE 1 END)) $$;
CREATE FUNCTION pg_temp.rec_sent(p_id bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format($q$SELECT public.fao_notification_record(%s::bigint, 'REQUESTED', 0, 'SENT', 'slack', '1730900000.0162', NULL)$q$, p_id)) $$;
CREATE FUNCTION pg_temp.revoke_approver(p text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 162 revoke approver', true);
  UPDATE public.fao_user_roles SET revoked_at = now()
   WHERE user_id = pg_temp.u(p) AND role = 'approver' AND revoked_at IS NULL;
END $$;
CREATE FUNCTION pg_temp.can(p_who text, p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT (r->>'code') || '/' || (r->'request'->>'viewer_can_decide') || '/' || array_length(pg_temp.keys(r->'request'), 1)
    FROM (SELECT pg_temp.get(p_who, p_k) AS r) x $$;
CREATE FUNCTION pg_temp.hour_ago() RETURNS timestamptz LANGUAGE sql AS $$ SELECT now() - interval '1 hour' $$;

SELECT tests.set_clock(0);
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 162 run limit', true);
  UPDATE public.agent_registry SET max_runs_per_hour = 60 WHERE agent_id = 'fao_reserve_recon_v1';
END $$;

-- ============================================================================
-- R1 to R3, R5: fao_hitl_get on a 2 of 2 request
-- ============================================================================
SELECT pg_temp.crit('r1');
INSERT INTO v VALUES ('r1b', pg_temp.get('B', 'r1'));
SELECT is(pg_temp.keys(pg_temp.g('r1b')), ARRAY['code', 'commit_blocked_reason', 'committed', 'http_status', 'message', 'ok', 'ref', 'request'],
  'R1: the full form keeps exactly its top-level keys');
SELECT is(pg_temp.keys(pg_temp.g('r1b')->'request'),
  ARRAY['agent_id', 'agent_name', 'approvals_received', 'configured_approvals', 'created_at', 'decided_at', 'decision', 'enforced_approvals',
        'escalated_assets', 'hitl_id', 'invoker_name', 'policy_rationale', 'risk_tier', 'sub_tier', 'timeout_at', 'viewer_can_decide',
        'viewer_has_approved', 'viewer_is_invoker'],
  'R1: request holds exactly the 16 core keys plus approvals_received and viewer_has_approved');
SELECT is((pg_temp.g('r1b')->'request'->'approvals_received')::text || '/' || (pg_temp.g('r1b')->'request'->'viewer_has_approved')::text
          || '/' || (pg_temp.g('r1b')->'request'->>'enforced_approvals'), '0/false/2', 'R1: approvals_received 0, viewer_has_approved false (enforced 2)');

INSERT INTO v VALUES ('r2d', pg_temp.dec('B', 'r1', 'APPROVED'));
INSERT INTO v VALUES ('r2b', pg_temp.get('B', 'r1'));
INSERT INTO v VALUES ('r2c', pg_temp.get('C', 'r1'));
INSERT INTO v VALUES ('r2a', pg_temp.get('A', 'r1'));
SELECT is(pg_temp.g('r2d')->>'code', 'AWAITING_FURTHER_APPROVAL', 'R2 setup: B approves (partial)');
SELECT is((pg_temp.g('r2b')->'request'->>'approvals_received') || '/' || (pg_temp.g('r2b')->'request'->>'viewer_has_approved') || '/' || (pg_temp.g('r2b')->'request'->>'viewer_can_decide'),
  '1/true/true', 'R2: B reads approvals_received 1, viewer_has_approved true, viewer_can_decide true');
SELECT is((pg_temp.g('r2c')->'request'->>'approvals_received') || '/' || (pg_temp.g('r2c')->'request'->>'viewer_has_approved'), '1/false',
  'R2: C reads 1 and false');
SELECT is((pg_temp.g('r2a')->'request'->>'approvals_received') || '/' || (pg_temp.g('r2a')->'request'->>'viewer_is_invoker'), '1/true',
  'R2: the invoker A reads 1 with viewer_is_invoker true');

INSERT INTO v VALUES ('r5_n', to_jsonb((SELECT count(*) FROM public.hitl_approvals)::text || '/' || (SELECT count(*) FROM public.shadow_ledger)::text));
SELECT pg_temp.get('A', 'r1');
SELECT pg_temp.get('B', 'r1');
SELECT pg_temp.get('C', 'r1');
SELECT is((SELECT count(*) FROM public.hitl_approvals)::text || '/' || (SELECT count(*) FROM public.shadow_ledger)::text, pg_temp.g('r5_n')#>>'{}',
  'R5: three reads change no approval row and no ledger row');

INSERT INTO v VALUES ('r3d', pg_temp.dec('C', 'r1', 'APPROVED'));
INSERT INTO v VALUES ('r3g', pg_temp.get('B', 'r1'));
SELECT is(pg_temp.g('r3d')->>'code' || '/' || (pg_temp.g('r3g')->>'code'), 'OK/ALREADY_DECIDED', 'R3: after the decision the read is ALREADY_DECIDED');
SELECT is(pg_temp.keys(pg_temp.g('r3g')->'request'), ARRAY['decided_at', 'decision', 'hitl_id'], 'R3: request keys stay exactly decided_at, decision, hitl_id');
SELECT is(pg_temp.keys(pg_temp.g('r3g')), ARRAY['code', 'commit_blocked_reason', 'committed', 'http_status', 'message', 'ok', 'ref', 'request'],
  'R3: top-level keys exactly as R1');

-- ============================================================================
-- R6 to R8: fao_notification_context
-- ============================================================================
SELECT pg_temp.crit('r6');
INSERT INTO v VALUES ('r6c', pg_temp.ctx(pg_temp.id('r6'), 'REQUESTED'));
SELECT is(pg_temp.keys(pg_temp.g('r6c')),
  ARRAY['agent_id', 'agent_name', 'approval_url', 'approvals_received', 'approved_by', 'approver_candidates', 'code', 'enforced_approvals', 'escalated_assets',
        'hitl_id', 'http_status', 'kind', 'level', 'message', 'ok', 'ref', 'risk_tier', 'send', 'slack_api_base_url', 'slack_channel_id', 'sub_tier',
        'target_name', 'timeout_at'],
  'R6: send:true keeps every core key and gains exactly enforced_approvals, approvals_received and approved_by');
SELECT is((pg_temp.g('r6c')->>'send') || '/' || (pg_temp.g('r6c')->>'enforced_approvals') || '/' || (pg_temp.g('r6c')->>'approvals_received') || '/' || (pg_temp.g('r6c')->'approved_by')::text,
  'true/2/0/[]', 'R6: a fresh 2 of 2: send true, enforced 2, received 0, approved_by []');
SELECT is(pg_temp.g('r6c')->'approver_candidates', '[{"name": "Marcus Patel"}, {"name": "Sarah Chen"}]'::jsonb,
  'R6: approver_candidates as in the core (active approvers, never the invoker, by name)');
SELECT is(pg_temp.dec('B', 'r6', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'R7 setup: B approves');
INSERT INTO v VALUES ('r7c', pg_temp.ctx(pg_temp.id('r6'), 'REQUESTED'));
SELECT is((pg_temp.g('r7c')->>'approvals_received') || '/' || (pg_temp.g('r7c')->'approved_by')::text, '1/[{"name": "Sarah Chen"}]',
  'R7: approvals_received 1, approved_by [Sarah Chen]');
SELECT is(position('Aisha' IN pg_temp.g('r7c')::text), 0, 'R7: the invoker''s name appears nowhere in the result');
-- R8: the send:false envelopes keep their core keys
SELECT is(pg_temp.keys(pg_temp.ctx(pg_temp.id('r1'), 'REQUESTED')), ARRAY['code', 'hitl_id', 'http_status', 'kind', 'level', 'message', 'ok', 'ref', 'send'],
  'R8: NOT_PENDING has exactly its core keys');
SELECT is(pg_temp.ctx(pg_temp.id('r1'), 'REQUESTED')->>'code', 'NOT_PENDING', 'R8: a decided request is NOT_PENDING');
SELECT is(pg_temp.rec_sent(pg_temp.id('r6'))->>'ok', 'true', 'R8 setup: a SENT REQUESTED notice');
SELECT is(pg_temp.ctx(pg_temp.id('r6'), 'REQUESTED')->>'code' || '/' || array_to_string(pg_temp.keys(pg_temp.ctx(pg_temp.id('r6'), 'REQUESTED')), ','),
  'ALREADY_SENT/code,hitl_id,http_status,kind,level,message,ok,ref,send', 'R8: ALREADY_SENT has exactly its core keys');
SELECT is(pg_temp.ctx(999999999999, 'REQUESTED')->>'code' || '/' || array_to_string(pg_temp.keys(pg_temp.ctx(999999999999, 'REQUESTED')), ','),
  'NOT_FOUND/code,hitl_id,http_status,kind,level,message,ok,ref,send', 'R8: NOT_FOUND has exactly its core keys');

-- ============================================================================
-- R9: viewer_can_decide under DA-4 (2 of 2 invoked by A)
-- ============================================================================
SELECT pg_temp.crit('r9');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, now());
SELECT is(pg_temp.can('L', 'r9'), 'OK/false/18', 'R9: false for L whose only grant has granted_at equal to created_at');
SELECT pg_temp.revoke_approver('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('A'), pg_temp.hour_ago());
SELECT is(pg_temp.can('L', 'r9'), 'OK/false/18', 'R9: false for L whose only grant was made by the invoker A');
SELECT pg_temp.revoke_approver('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
SELECT is(pg_temp.can('L', 'r9'), 'OK/true/18', 'R9: true for L with a grant made an hour before, granted_by NULL');
SELECT pg_temp.revoke_approver('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('C'), pg_temp.hour_ago());
SELECT is(pg_temp.dec('C', 'r9', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'R9 setup: C approves');
SELECT is(pg_temp.can('L', 'r9'), 'OK/true/18', 'R9: true for L whose only grant was made by C after C approved (L may still reject)');
SELECT is(pg_temp.keys(pg_temp.get('L', 'r9')), ARRAY['code', 'commit_blocked_reason', 'committed', 'http_status', 'message', 'ok', 'ref', 'request'],
  'R9: the full-form top-level keys stay as R1');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- R10: after the D27 pattern (L granted by C approves, then C approves)
-- ============================================================================
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('C'), pg_temp.hour_ago());
SELECT pg_temp.crit('r10');
SELECT is(pg_temp.dec('L', 'r10', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'R10 setup: L (granted by C) approves');
SELECT is(pg_temp.dec('C', 'r10', 'APPROVED')->>'approvals_received', '1', 'R10 setup: C approves; L stops counting');
INSERT INTO v VALUES ('r10c', pg_temp.ctx(pg_temp.id('r10'), 'REQUESTED'));
SELECT is((pg_temp.g('r10c')->>'approvals_received') || '/' || (pg_temp.g('r10c')->'approved_by')::text, '1/[{"name": "Marcus Patel"}]',
  'R10: notification context approvals_received 1, approved_by [Marcus Patel]');
INSERT INTO v VALUES ('r10g', pg_temp.get('L', 'r10'));
SELECT is((pg_temp.g('r10g')->'request'->>'approvals_received') || '/' || (pg_temp.g('r10g')->'request'->>'viewer_has_approved'), '1/true',
  'R10: fao_hitl_get approvals_received 1; L viewer_has_approved true (raw)');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- V1 setup: a STANDARD decided run and a run without a request
-- ============================================================================
INSERT INTO v VALUES ('vs', to_jsonb(tests.make_request(pg_temp.e('A'))));
SELECT is(pg_temp.dec('B', 'vs', 'APPROVED')->>'code', 'OK', 'V1 setup: a STANDARD run decided by B');
INSERT INTO v VALUES ('vclean', to_jsonb(tests.make_run(pg_temp.e('A'), ARRAY['ETH'])));
SELECT tests.append(jsonb_build_array(tests.asset_event((pg_temp.g('vclean')#>>'{}')::uuid, 'ETH')));
SELECT is(tests.finalize((pg_temp.g('vclean')#>>'{}')::uuid)->>'state', 'COMMITTED', 'V1 setup: a clean run committed without a request');

-- ============================================================================
-- X1 to X4, R4: expiry of a partially approved request
-- ============================================================================
SELECT pg_temp.crit('x1');
SELECT is(pg_temp.dec('B', 'x1', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'X1 setup: B approves (1 of 2)');
SELECT tests.set_clock(90000);
INSERT INTO v VALUES ('x1s', tests.sweep());
SELECT ok((SELECT decision = 'EXPIRED' AND approver_id IS NULL FROM public.hitl_queue WHERE hitl_id = pg_temp.id('x1')),
  'X1: the sweep expires the partially approved request; approver_id NULL');
SELECT is((SELECT pg_temp.keys(inputs) FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('x1') AND inputs->>'event_type' = 'HITL_EXPIRED'),
  ARRAY['committed', 'event_type', 'expired_at', 'hitl_id', 'run_state', 'source', 'timeout_at'], 'X1: HITL_EXPIRED keys exactly as the core');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('x1') AND inputs->>'event_type' = 'HITL_ESCALATED'
             AND inputs->>'level' = '1' AND inputs->>'reason' = 'TIMEOUT'), 1::bigint, 'X1: one HITL_ESCALATED TIMEOUT');
SELECT is(tests.ledger_count(pg_temp.rc('x1'), 'COMMITTED') || '/' || tests.approval_count(pg_temp.id('x1')) || '/' || tests.run_state(pg_temp.rc('x1')),
  '0/1/EXPIRED', 'X1: no COMMITTED; the approval row is kept; run EXPIRED');
INSERT INTO v VALUES ('x2', pg_temp.ctx(pg_temp.id('x1'), 'ESCALATED'));
SELECT is((pg_temp.g('x2')->>'send') || '/' || (pg_temp.g('x2')->>'enforced_approvals') || '/' || (pg_temp.g('x2')->>'approvals_received') || '/' || (pg_temp.g('x2')->'approved_by')::text,
  'true/2/1/[{"name": "Sarah Chen"}]', 'X2: ESCALATED context: enforced 2, received 1, approved_by [Sarah Chen]');
INSERT INTO v VALUES ('x3', pg_temp.dec('C', 'x1', 'APPROVED'));
SELECT is((pg_temp.g('x3')->>'code') || '/' || (pg_temp.g('x3')->>'http_status') || '/' || tests.approval_count(pg_temp.id('x1')), 'EXPIRED/410/1',
  'X3: C''s approval after expiry is EXPIRED (410); still one approval row');
SELECT is(pg_temp.keys(pg_temp.g('x1s')),
  ARRAY['clock_offset_seconds', 'code', 'escalations', 'expired_requests', 'expired_runs', 'failed_runs', 'grants_drift', 'http_status', 'item_errors',
        'message', 'ok', 'ref', 'renotify'],
  'X4: the sweep result has exactly its core keys');
INSERT INTO v VALUES ('r4', pg_temp.get('B', 'x1'));
SELECT is(pg_temp.g('r4')->>'code' || '/' || array_to_string(pg_temp.keys(pg_temp.g('r4')->'request'), ','), 'EXPIRED/decided_at,decision,hitl_id',
  'R4: after a partial approval and expiry: EXPIRED with request keys decided_at, decision, hitl_id');
SELECT is(pg_temp.keys(pg_temp.g('r4')), ARRAY['code', 'commit_blocked_reason', 'committed', 'http_status', 'message', 'ok', 'ref', 'request'],
  'R4: top-level keys exactly as R1');
SELECT tests.set_clock(0);

-- ============================================================================
-- V1, V2: fao_run_summary
-- ============================================================================
SELECT is((SELECT array_agg(column_name::text || ' ' || data_type::text ORDER BY ordinal_position) FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = 'fao_run_summary'),
  ARRAY['correlation_id uuid', 'agent_id text', 'invoker_id uuid', 'invoked_via text', 'run_state text', 'started_at timestamp with time zone',
        'latest_event_at timestamp with time zone', 'event_count bigint', 'hitl_id bigint', 'hitl_decision text', 'decided_at timestamp with time zone',
        'approver_id uuid', 'latest_committed_outcome text', 'latest_committed_status text', 'committed_count bigint', 'commit_blocked boolean',
        'correction_count bigint', 'has_run_record boolean', 'enforced_approvals integer', 'approvals_recorded bigint'],
  'V1: the 18 core columns in order, then enforced_approvals int and approvals_recorded bigint');
SELECT is((SELECT enforced_approvals || '/' || approvals_recorded || '/' || approver_id::text FROM public.fao_run_summary WHERE correlation_id = pg_temp.rc('r1')),
  '2/2/' || pg_temp.u('C')::text, 'V1: a decided 2 of 2 run: 2 and 2; approver_id the deciding user');
SELECT is((SELECT enforced_approvals || '/' || approvals_recorded || '/' || approver_id::text FROM public.fao_run_summary WHERE correlation_id = pg_temp.rc('vs')),
  '1/1/' || pg_temp.u('B')::text, 'V1: a STANDARD run: 1 and 1');
SELECT ok((SELECT enforced_approvals IS NULL AND approvals_recorded IS NULL FROM public.fao_run_summary WHERE correlation_id = (pg_temp.g('vclean')#>>'{}')::uuid),
  'V1: a run without a request: NULL and NULL');
SELECT is((SELECT hitl_decision || '/' || enforced_approvals || '/' || approvals_recorded FROM public.fao_run_summary WHERE correlation_id = pg_temp.rc('x1')),
  'EXPIRED/2/1', 'V1: the X1 run: EXPIRED, 2 and 1');
SELECT ok((SELECT 'security_invoker=true' = ANY (c.reloptions) FROM pg_class c WHERE c.oid = 'public.fao_run_summary'::regclass),
  'V2: the view keeps security_invoker=true');
SELECT is((SELECT count(*) FROM pg_trigger t WHERE t.tgrelid = 'public.fao_run_summary'::regclass AND t.tgname = 'fao_run_summary_read_only'), 1::bigint,
  'V2: the INSTEAD OF trigger fao_run_summary_read_only stays');
SELECT is((SELECT string_agg(tests.sqlstate_as(w, 'DELETE FROM public.fao_run_summary'), ',' ORDER BY w)
             FROM unnest(ARRAY['anon', pg_temp.e('B'), 'fao_workflow', 'service_role']) w),
  '42501,42501,42501,42501', 'V2: the view refuses writes for every client role');
SELECT ok(tests.error_as('owner', 'DELETE FROM public.fao_run_summary') IS NOT NULL, 'V2: the owner is refused too (INSTEAD OF trigger)');

SELECT * FROM finish();
ROLLBACK;
