-- ============================================================================
-- FinAgent OS pgTAP 160: dual approval, the decide algorithm
-- Controls:
--   FAO-GOV-004 (DA-1): a CRITICAL request on the flagship enforces the
--     registry threshold (2); a STANDARD request keeps one approval; requests
--     created before 0018 keep enforced_approvals 1.
--   FAO-GOV-004 (DA-2, DA-3): distinct eligible approvers, never the
--     invoker, one count per user; the approval that reaches
--     enforced_approvals decides; any one eligible rejection closes at once.
--   FAO-GOV-004 (DA-4): an approval counts, and a caller may decide, only
--     through a qualifying approver grant (unrevoked, covering the agent,
--     granted strictly before the request was created, not by the invoker;
--     for an approval, not only grants made by another approver of it).
--   FAO-GOV-001: the approval row, the decision, its ledger rows and the run
--     state commit together or not at all; refusals are journaled.
-- Users: A Aisha (invoker, approver), B Sarah (invoker, approver), C Marcus
-- (approver, admin), L ratelimit@local.test (owner row; approver grants are
-- made in the test), O outsider@local.test, R the MCP reader. "2 of 2" is a
-- CRITICAL flagship request invoked by A (tests.make_critical_request). A
-- test transaction has one now(), so a grant made here qualifies only with
-- an explicit earlier granted_at (tests.grant_approver). L's grants are
-- revoked at the end of each case; B's seed grant is restored after D13 with
-- an owner insert (granted_by NULL, older than every request here).
-- ============================================================================
BEGIN;
SELECT plan(133);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j#>>'{}')::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.rc(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr(pg_temp.id(p_k)) $$;
CREATE FUNCTION pg_temp.keys(p_j jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_j) AS k $$;
CREATE FUNCTION pg_temp.e(p text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE p WHEN 'A' THEN 'aisha.okonkwo@finagent-os.demo' WHEN 'B' THEN 'sarah.chen@finagent-os.demo'
                WHEN 'C' THEN 'marcus.patel@finagent-os.demo' WHEN 'L' THEN 'ratelimit@local.test'
                WHEN 'O' THEN 'outsider@local.test' WHEN 'R' THEN 'mcp.reader@finagent-os.demo' END $$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.uid(pg_temp.e(p)) $$;
CREATE FUNCTION pg_temp.uj(p text) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(pg_temp.u(p)::text) $$;
CREATE FUNCTION pg_temp.ids(p text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT coalesce(jsonb_agg(pg_temp.u(x) ORDER BY o), '[]'::jsonb) FROM unnest(p) WITH ORDINALITY AS t(x, o) $$;
CREATE FUNCTION pg_temp.uarr(p text[]) RETURNS uuid[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(pg_temp.u(x) ORDER BY o), ARRAY[]::uuid[]) FROM unnest(p) WITH ORDINALITY AS t(x, o) $$;
CREATE FUNCTION pg_temp.dec(p_who text, p_k text, p_decision text, p_notes text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.decide_raw(pg_temp.e(p_who), pg_temp.id(p_k)::text, p_decision, p_notes) $$;
CREATE FUNCTION pg_temp.get(p_who text, p_k text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.get_raw(pg_temp.e(p_who), pg_temp.id(p_k)::text) $$;
CREATE FUNCTION pg_temp.ch(p_j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(p_j->>'code', '<' || coalesce(p_j->>'error', 'none') || '>') || '/' || coalesce(p_j->>'http_status', '-') $$;
CREATE FUNCTION pg_temp.crit(p_k text, p_who text DEFAULT 'A') RETURNS void LANGUAGE sql AS $$
  INSERT INTO v VALUES (p_k, to_jsonb(tests.make_critical_request(pg_temp.e(p_who)))) $$;
-- Newest ledger row of an event type for a request
CREATE FUNCTION pg_temp.ev(p_k text, p_type text) RETURNS public.shadow_ledger LANGUAGE sql AS $$
  SELECT * FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc(p_k) AND inputs->>'event_type' = p_type
   ORDER BY ledger_id DESC LIMIT 1 $$;
CREATE FUNCTION pg_temp.nev(p_k text, p_type text) RETURNS bigint LANGUAGE sql AS $$
  SELECT tests.ledger_count(pg_temp.rc(p_k), p_type) $$;
CREATE FUNCTION pg_temp.req(p_k text) RETURNS public.hitl_queue LANGUAGE sql AS $$
  SELECT * FROM public.hitl_queue WHERE hitl_id = pg_temp.id(p_k) $$;
-- Approver ids of the approval rows of a request, in approval order
CREATE FUNCTION pg_temp.rows(p_k text) RETURNS uuid[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(a.approver_id ORDER BY a.approval_id), ARRAY[]::uuid[]) FROM public.hitl_approvals a WHERE a.hitl_id = pg_temp.id(p_k) $$;
CREATE FUNCTION pg_temp.jr(p_j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT (r->>'code') || '/' || (r->>'target_table') || '/' || (r->>'target_key') || '/' || (r->'attempted'->>'decision')
    FROM (SELECT tests.journal_row((p_j->>'ref')::bigint) AS r) x $$;
CREATE FUNCTION pg_temp.resolved_rat(p_k text, p_decision text, p_by text, p_invoker text, p_e int, p_c int) RETURNS text LANGUAGE sql AS $$
  SELECT format('FAO-GOV-004 hitl_id %s %s by approver %s; invoker %s; approvals enforced %s of configured %s',
                pg_temp.id(p_k), p_decision, pg_temp.u(p_by), pg_temp.u(p_invoker), p_e, p_c) $$;
CREATE FUNCTION pg_temp.recorded_rat(p_k text, p_n int, p_e int, p_by text, p_invoker text) RETURNS text LANGUAGE sql AS $$
  SELECT format('FAO-GOV-004 hitl_id %s approval %s of %s recorded by approver %s; invoker %s; awaiting further approval',
                pg_temp.id(p_k), p_n, p_e, pg_temp.u(p_by), pg_temp.u(p_invoker)) $$;
CREATE FUNCTION pg_temp.approvers_txt(p text[]) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(pg_temp.u(x)::text, ', ' ORDER BY o) FROM unnest(p) WITH ORDINALITY AS t(x, o) $$;
CREATE FUNCTION pg_temp.revoke_approver(p text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 160 revoke approver', true);
  UPDATE public.fao_user_roles SET revoked_at = now()
   WHERE user_id = pg_temp.u(p) AND role = 'approver' AND revoked_at IS NULL;
END $$;
CREATE FUNCTION pg_temp.admin_active(p text, p_active boolean) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as(pg_temp.e('C'), format($q$SELECT public.fao_admin_set_owner_active(json_build_object('p_user_id', %L, 'p_active', %L, 'p_reason', 'pgtap 160 owner active'))$q$,
                                              pg_temp.u(p), p_active::text)) $$;
CREATE FUNCTION pg_temp.admin_role(p text, p_grant boolean) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as(pg_temp.e('C'), format($q$SELECT public.fao_admin_set_role(json_build_object('p_user_id', %L, 'p_role', 'approver', 'p_agent_id', NULL, 'p_grant', %L, 'p_reason', 'pgtap 160 approver grant'))$q$,
                                              pg_temp.u(p), p_grant::text)) $$;
CREATE FUNCTION pg_temp.owner_active(p text, p_active boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 160 owner active ' || p_active::text, true);
  UPDATE public.process_owners SET active = p_active WHERE id = pg_temp.u(p);
END $$;
CREATE FUNCTION pg_temp.agent(p_status text, p_threshold int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 160 agent ' || p_status || ' ' || p_threshold, true);
  UPDATE public.agent_registry SET status = p_status::public.agent_status, approval_threshold = p_threshold
   WHERE agent_id = 'fao_reserve_recon_v1';
END $$;
CREATE FUNCTION pg_temp.hour_ago() RETURNS timestamptz LANGUAGE sql AS $$ SELECT now() - interval '1 hour' $$;

SELECT tests.set_clock(0);
-- About thirty flagship runs by Aisha in this transaction: lift the per-hour
-- run limit (the window counts runs requested in the last hour).
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 160 run limit', true);
  UPDATE public.agent_registry SET max_runs_per_hour = 60 WHERE agent_id = 'fao_reserve_recon_v1';
END $$;

-- ============================================================================
-- D1 to D6: a 2 of 2 request, partial approval, repeat, deciding approval
-- ============================================================================
SELECT pg_temp.crit('d1');
SELECT is((SELECT configured_approvals || '/' || enforced_approvals || '/' || sub_tier::text FROM pg_temp.req('d1')), '2/2/CRITICAL',
  'D1: a CRITICAL flagship request has configured_approvals 2 and enforced_approvals 2');
SELECT is((pg_temp.ev('d1', 'HITL_REQUESTED')).inputs->>'enforced_approvals', '2', 'D1: HITL_REQUESTED inputs.enforced_approvals is 2');

INSERT INTO v VALUES ('d2_j0', to_jsonb(tests.journal_total()));
INSERT INTO v VALUES ('d2', pg_temp.dec('B', 'd1', 'APPROVED', 'pgtap 160 first approval'));
SELECT is(pg_temp.g('d2')->>'code' || '/' || (pg_temp.g('d2')->>'http_status') || '/' || (pg_temp.g('d2')->>'ok') || '/' || (pg_temp.g('d2')->>'message'),
  'AWAITING_FURTHER_APPROVAL/200/true/Approval recorded. This request needs more approvals before it is decided.',
  'D2: the first approval of 2 of 2 is AWAITING_FURTHER_APPROVAL (200, ok) with the fixed message');
SELECT is(pg_temp.keys(pg_temp.g('d2')),
  ARRAY['approvals_received', 'approved_at', 'code', 'committed', 'committed_ledger_id', 'decided_at', 'decision', 'enforced_approvals', 'hitl_id', 'http_status', 'message', 'ok', 'ref'],
  'D2: the AWAITING_FURTHER_APPROVAL envelope has exactly its 13 keys');
SELECT ok(pg_temp.g('d2')->'approvals_received' = '1'::jsonb AND pg_temp.g('d2')->'enforced_approvals' = '2'::jsonb
          AND pg_temp.g('d2')->>'decision' = 'PENDING' AND pg_temp.g('d2')->'decided_at' = 'null'::jsonb
          AND pg_temp.g('d2')->'committed' = 'false'::jsonb AND pg_temp.g('d2')->'committed_ledger_id' = 'null'::jsonb
          AND pg_temp.g('d2')->'ref' = 'null'::jsonb AND (pg_temp.g('d2')->>'hitl_id')::bigint = pg_temp.id('d1'),
  'D2: approvals_received 1, enforced_approvals 2, decision PENDING, decided_at null, committed false, committed_ledger_id null, ref null');
SELECT ok((SELECT decision = 'PENDING' AND approver_id IS NULL AND decided_at IS NULL FROM pg_temp.req('d1')),
  'D3: the request stays PENDING with no approver and no decision time');
SELECT is(tests.run_state(pg_temp.rc('d1')), 'AWAITING_HITL', 'D3: the run stays AWAITING_HITL');
SELECT is((SELECT count(*)::text || '/' || min(a.approver_id::text) || '/' || bool_and(a.approved_at = fao_private.clock())::text || '/' || min(a.decision_notes)
             FROM public.hitl_approvals a WHERE a.hitl_id = pg_temp.id('d1')),
  '1/' || pg_temp.u('B')::text || '/true/pgtap 160 first approval',
  'D3: one approval row: B, approved_at the FinAgent clock, the notes as sent');
SELECT is((pg_temp.g('d2')->>'approved_at')::timestamptz, (SELECT approved_at FROM public.hitl_approvals WHERE hitl_id = pg_temp.id('d1')),
  'D3: the envelope approved_at is the approval row time');
SELECT is(pg_temp.nev('d1', 'HITL_APPROVAL_RECORDED'), 1::bigint, 'D3: one HITL_APPROVAL_RECORDED');
SELECT is(pg_temp.keys((pg_temp.ev('d1', 'HITL_APPROVAL_RECORDED')).inputs),
  ARRAY['agent_invoker_id', 'approver_id', 'approvers', 'configured_approvals', 'decision', 'decision_notes', 'enforced_approvals', 'event_type', 'hitl_id', 'sub_tier'],
  'D3: HITL_APPROVAL_RECORDED inputs keys are exactly event_type and the nine of 5.1');
SELECT ok((SELECT (e).inputs->'approvers' = pg_temp.ids(ARRAY['B']) AND (e).inputs->>'decision' = 'APPROVED'
                  AND (e).inputs->'approver_id' = pg_temp.uj('B') AND (e).inputs->'agent_invoker_id' = pg_temp.uj('A')
                  AND (e).inputs->'configured_approvals' = '2'::jsonb AND (e).inputs->'enforced_approvals' = '2'::jsonb
                  AND (e).inputs->>'sub_tier' = 'CRITICAL' AND (e).inputs->>'decision_notes' = 'pgtap 160 first approval'
                  AND ((e).inputs->>'hitl_id')::bigint = pg_temp.id('d1')
             FROM (SELECT pg_temp.ev('d1', 'HITL_APPROVAL_RECORDED') AS e) x),
  'D3: HITL_APPROVAL_RECORDED inputs: approvers [B], decision APPROVED, approver B, counts 2 and 2, invoker A, sub-tier, notes, id');
SELECT is((SELECT (e).policy_outcome::text || '/' || (e).policy_sub_tier::text || '/' || (e).status::text || '/' || (e).hitl_status::text || '/' || (e).hitl_approver_id::text
             FROM (SELECT pg_temp.ev('d1', 'HITL_APPROVAL_RECORDED') AS e) x),
  'REQUIRE_HUMAN/CRITICAL/SUCCESS/PENDING/' || pg_temp.u('B')::text,
  'D3: HITL_APPROVAL_RECORDED is REQUIRE_HUMAN, CRITICAL, SUCCESS, hitl_status PENDING, hitl_approver_id B');
SELECT is((pg_temp.ev('d1', 'HITL_APPROVAL_RECORDED')).policy_rationale, pg_temp.recorded_rat('d1', 1, 2, 'B', 'A'),
  'D3: HITL_APPROVAL_RECORDED rationale wording');
SELECT ok(pg_temp.nev('d1', 'HITL_RESOLVED') = 0 AND pg_temp.nev('d1', 'COMMITTED') = 0, 'D3: no HITL_RESOLVED and no COMMITTED after a partial approval');
SELECT is(tests.journal_total(), (pg_temp.g('d2_j0')#>>'{}')::bigint, 'D3: a partial approval is not journaled');

INSERT INTO v VALUES ('d4_l0', to_jsonb((SELECT count(*) FROM public.shadow_ledger)));
INSERT INTO v VALUES ('d4', pg_temp.dec('B', 'd1', 'APPROVED'));
SELECT is(pg_temp.g('d4')->>'code' || '/' || (pg_temp.g('d4')->>'http_status') || '/' || (pg_temp.g('d4')->>'ok') || '/' || (pg_temp.g('d4')->>'message'),
  'ALREADY_APPROVED/409/false/You have already approved this request.', 'D4: a repeat approval is ALREADY_APPROVED (409) with the fixed message');
SELECT is(pg_temp.keys(pg_temp.g('d4')), ARRAY['code', 'http_status', 'message', 'ok', 'ref'], 'D4: the refusal has the plain five keys');
SELECT is(pg_temp.jr(pg_temp.g('d4')), 'ALREADY_APPROVED/hitl_queue/' || pg_temp.id('d1') || '/APPROVED',
  'D4: journaled with code ALREADY_APPROVED, target hitl_queue, the id and attempted.decision APPROVED');
SELECT ok(tests.approval_count(pg_temp.id('d1')) = 1 AND (SELECT count(*) FROM public.shadow_ledger) = (pg_temp.g('d4_l0')#>>'{}')::bigint,
  'D4: still one approval row; the ledger is unchanged');

INSERT INTO v VALUES ('d5', pg_temp.dec('C', 'd1', 'APPROVED'));
SELECT is(pg_temp.ch(pg_temp.g('d5')) || '/' || (pg_temp.g('d5')->>'committed'), 'OK/200/true', 'D5: the second approval decides: OK, committed');
SELECT is(pg_temp.keys(pg_temp.g('d5')),
  ARRAY['code', 'committed', 'committed_ledger_id', 'decided_at', 'decision', 'hitl_id', 'http_status', 'message', 'ok', 'ref'],
  'D5: the deciding envelope keeps exactly the core 10 keys');
SELECT is((SELECT decision::text || '/' || approver_id::text FROM pg_temp.req('d1')), 'APPROVED/' || pg_temp.u('C')::text,
  'D5: the request is APPROVED with approver_id C');
SELECT is(pg_temp.rows('d1'), pg_temp.uarr(ARRAY['B', 'C']), 'D5: approval rows B then C by approval_id');
SELECT ok((SELECT (e).inputs->'approvers' = pg_temp.ids(ARRAY['B', 'C']) AND (e).inputs->'approver_id' = pg_temp.uj('C')
                  AND (e).inputs->'enforced_approvals' = '2'::jsonb
             FROM (SELECT pg_temp.ev('d1', 'HITL_RESOLVED') AS e) x),
  'D5: HITL_RESOLVED approvers [B, C], approver_id C, enforced_approvals 2');
SELECT is((pg_temp.ev('d1', 'HITL_RESOLVED')).policy_rationale,
  pg_temp.resolved_rat('d1', 'APPROVED', 'C', 'A', 2, 2) || '; approvers ' || pg_temp.approvers_txt(ARRAY['B', 'C']),
  'D5: HITL_RESOLVED rationale is the core text with approvals enforced 2 of configured 2, then both approvers in order');
SELECT is((SELECT (e).status::text || '/' || (e).hitl_approver_id::text FROM (SELECT pg_temp.ev('d1', 'COMMITTED') AS e) x),
  'SUCCESS/' || pg_temp.u('C')::text, 'D5: COMMITTED SUCCESS with hitl_approver_id C');
SELECT is(tests.run_state(pg_temp.rc('d1')), 'COMMITTED', 'D5: the run is COMMITTED');

SELECT is((SELECT string_agg(pg_temp.ch(pg_temp.dec(w, 'd1', d)), ',' ORDER BY w, d)
             FROM (VALUES ('A', 'APPROVED'), ('A', 'REJECTED'), ('B', 'APPROVED'), ('B', 'REJECTED'), ('C', 'APPROVED'), ('C', 'REJECTED')) x(w, d)),
  'ALREADY_DECIDED/410,ALREADY_DECIDED/410,ALREADY_DECIDED/410,ALREADY_DECIDED/410,ALREADY_DECIDED/410,ALREADY_DECIDED/410',
  'D6: after the decision, A, B and C get ALREADY_DECIDED (410) for either decision');

-- ============================================================================
-- D7 to D9: rejections (DA-2, C4)
-- ============================================================================
SELECT pg_temp.crit('d7');
INSERT INTO v VALUES ('d7r', pg_temp.dec('C', 'd7', 'REJECTED'));
SELECT is(pg_temp.ch(pg_temp.g('d7r')) || '/' || (pg_temp.g('d7r')->>'decision') || '/' || (pg_temp.g('d7r')->>'committed'), 'OK/200/REJECTED/true',
  'D7: a rejection before any approval closes the request at once');
SELECT is(tests.approval_count(pg_temp.id('d7')), 0::bigint, 'D7: a rejection writes no approval row');
SELECT is((pg_temp.ev('d7', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['C']), 'D7: HITL_RESOLVED approvers [C]');
SELECT is((pg_temp.ev('d7', 'HITL_RESOLVED')).policy_rationale,
  pg_temp.resolved_rat('d7', 'REJECTED', 'C', 'A', 2, 2) || '; approvals received 0 of 2 before the rejection',
  'D7: HITL_RESOLVED rationale ends approvals received 0 of 2 before the rejection');
SELECT is((pg_temp.ev('d7', 'COMMITTED')).status::text || '/' || tests.run_state(pg_temp.rc('d7')), 'ROLLED_BACK/COMMITTED',
  'D7: COMMITTED ROLLED_BACK; the run is COMMITTED');

SELECT pg_temp.crit('d8');
INSERT INTO v VALUES ('d8a', pg_temp.dec('B', 'd8', 'APPROVED'));
INSERT INTO v VALUES ('d8r', pg_temp.dec('C', 'd8', 'REJECTED'));
SELECT is(pg_temp.g('d8a')->>'code' || '/' || (pg_temp.g('d8r')->>'code') || '/' || (SELECT decision::text || '/' || approver_id::text FROM pg_temp.req('d8')),
  'AWAITING_FURTHER_APPROVAL/OK/REJECTED/' || pg_temp.u('C')::text, 'D8: B approves, then C rejects: REJECTED by C');
SELECT is((pg_temp.ev('d8', 'HITL_RESOLVED')).policy_rationale,
  pg_temp.resolved_rat('d8', 'REJECTED', 'C', 'A', 2, 2) || '; approvals received 1 of 2 before the rejection',
  'D8: HITL_RESOLVED rationale ends approvals received 1 of 2 before the rejection');
SELECT is((SELECT string_agg(t, ',' ORDER BY ledger_id) FROM (
             SELECT ledger_id, inputs->>'event_type' || CASE WHEN inputs->>'event_type' = 'COMMITTED' THEN ' ' || status::text ELSE '' END AS t
               FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('d8') ORDER BY ledger_id DESC LIMIT 3) x),
  'HITL_APPROVAL_RECORDED,HITL_RESOLVED,COMMITTED ROLLED_BACK', 'D8: ledger tail HITL_APPROVAL_RECORDED, HITL_RESOLVED, COMMITTED (ROLLED_BACK)');
SELECT is(pg_temp.rows('d8'), pg_temp.uarr(ARRAY['B']), 'D8: B''s approval row is kept');

SELECT pg_temp.crit('d9');
INSERT INTO v VALUES ('d9a', pg_temp.dec('B', 'd9', 'APPROVED'));
INSERT INTO v VALUES ('d9r', pg_temp.dec('B', 'd9', 'REJECTED'));
SELECT is(pg_temp.g('d9a')->>'code' || '/' || (pg_temp.g('d9r')->>'code') || '/' || (SELECT decision::text || '/' || approver_id::text FROM pg_temp.req('d9')),
  'AWAITING_FURTHER_APPROVAL/OK/REJECTED/' || pg_temp.u('B')::text, 'D9: the earlier approver may reject: REJECTED by B (C4)');
SELECT is((pg_temp.ev('d9', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['B']), 'D9: HITL_RESOLVED approvers [B] (the rejector alone)');

-- ============================================================================
-- D10, D11: the invoker and non-approvers
-- ============================================================================
SELECT pg_temp.crit('d10');
INSERT INTO v VALUES ('d10_j0', to_jsonb(tests.journal_count('SOD_SELF_APPROVAL')));
SELECT is(pg_temp.ch(pg_temp.dec('A', 'd10', 'APPROVED')) || ',' || pg_temp.ch(pg_temp.dec('A', 'd10', 'REJECTED')),
  'SOD_SELF_APPROVAL/403,SOD_SELF_APPROVAL/403', 'D10: the invoker gets SOD_SELF_APPROVAL for either decision');
SELECT ok(tests.approval_count(pg_temp.id('d10')) = 0 AND tests.journal_count('SOD_SELF_APPROVAL') = (pg_temp.g('d10_j0')#>>'{}')::bigint + 2,
  'D10: no approval row; two journal rows');
SELECT is(pg_temp.ch(pg_temp.dec('O', 'd10', 'APPROVED')) || ',' || pg_temp.ch(pg_temp.dec('R', 'd10', 'APPROVED')),
  'NOT_AUTHORISED/403,NOT_AUTHORISED/403', 'D11: the outsider and the reader get NOT_AUTHORISED');
SELECT is(tests.approval_count(pg_temp.id('d10')), 0::bigint, 'D11: no approval row');

-- ============================================================================
-- D12: a STANDARD request keeps one approval
-- ============================================================================
INSERT INTO v VALUES ('d12', to_jsonb(tests.make_request(pg_temp.e('A'))));
INSERT INTO v VALUES ('d12a', pg_temp.dec('B', 'd12', 'APPROVED'));
SELECT is(pg_temp.ch(pg_temp.g('d12a')) || '/' || (pg_temp.g('d12a')->>'committed') || '/' || array_to_string(pg_temp.keys(pg_temp.g('d12a')), ','),
  'OK/200/true/code,committed,committed_ledger_id,decided_at,decision,hitl_id,http_status,message,ok,ref',
  'D12: a STANDARD request is decided by one approval with the core key set');
SELECT ok(tests.approval_count(pg_temp.id('d12')) = 1 AND pg_temp.nev('d12', 'HITL_APPROVAL_RECORDED') = 0,
  'D12: one approval row and no HITL_APPROVAL_RECORDED');
SELECT ok((SELECT (e).inputs->'approvers' = pg_temp.ids(ARRAY['B']) AND (e).inputs->'enforced_approvals' = '1'::jsonb
             FROM (SELECT pg_temp.ev('d12', 'HITL_RESOLVED') AS e) x),
  'D12: HITL_RESOLVED approvers [B], enforced_approvals 1');
SELECT is((pg_temp.ev('d12', 'HITL_RESOLVED')).policy_rationale, pg_temp.resolved_rat('d12', 'APPROVED', 'B', 'A', 1, 2),
  'D12: HITL_RESOLVED rationale is exactly the core format (approvals enforced 1 of configured 2)');

-- ============================================================================
-- D29: seed grants qualify (granted_by NULL, older than the request)
-- ============================================================================
SELECT pg_temp.crit('d29');
SELECT is((SELECT count(*) FROM public.fao_user_roles r
            WHERE r.user_id IN (pg_temp.u('B'), pg_temp.u('C')) AND r.role = 'approver' AND r.revoked_at IS NULL
              AND r.granted_by IS NULL AND r.granted_at < (pg_temp.req('d29')).created_at),
  2::bigint, 'D29: B''s and C''s seed approver grants have granted_by NULL and granted_at before the request');
SELECT ok(fao_private.approver_qualifies(pg_temp.id('d29'), pg_temp.u('B'), true) AND fao_private.approver_qualifies(pg_temp.id('d29'), pg_temp.u('C'), true),
  'D29: B and C qualify (co-approver rule applied) before any approval');
INSERT INTO v VALUES ('d29b', pg_temp.dec('B', 'd29', 'APPROVED'));
INSERT INTO v VALUES ('d29c', pg_temp.dec('C', 'd29', 'APPROVED'));
SELECT is(pg_temp.g('d29b')->>'code' || '/' || (pg_temp.g('d29c')->>'code'), 'AWAITING_FURTHER_APPROVAL/OK', 'D29: B then C decide the request');
SELECT ok(fao_private.approver_qualifies(pg_temp.id('d29'), pg_temp.u('B'), true) AND fao_private.approver_qualifies(pg_temp.id('d29'), pg_temp.u('C'), true),
  'D29: B and C still qualify after both approved (NULL granted_by is never a co-approver)');
SELECT is(fao_private.approver_qualifies(pg_temp.id('d29'), pg_temp.u('A'), false), true, 'D29: the invoker''s own seed grant qualifies as a grant');
SELECT pg_temp.crit('d29x');
SELECT is(pg_temp.ch(pg_temp.dec('A', 'd29x', 'APPROVED')), 'SOD_SELF_APPROVAL/403', 'D29: the invoker is still refused SOD_SELF_APPROVAL (step 7 before step 10)');

-- ============================================================================
-- D13: an earlier approver's grant revoked; a re-grant never restores it
-- ============================================================================
SELECT pg_temp.crit('d13');
INSERT INTO v VALUES ('d13b', pg_temp.dec('B', 'd13', 'APPROVED'));
SELECT is(pg_temp.admin_role('B', false)->>'ok', 'true', 'D13 setup: C revokes B''s approver grant');
INSERT INTO v VALUES ('d13c', pg_temp.dec('C', 'd13', 'APPROVED'));
SELECT is(pg_temp.g('d13b')->>'code' || '/' || (pg_temp.g('d13c')->>'code') || '/' || (pg_temp.g('d13c')->>'approvals_received'),
  'AWAITING_FURTHER_APPROVAL/AWAITING_FURTHER_APPROVAL/1', 'D13: with B revoked, C''s approval is partial: approvals_received 1');
SELECT is((pg_temp.ev('d13', 'HITL_APPROVAL_RECORDED')).inputs->'approvers', pg_temp.ids(ARRAY['C']), 'D13: HITL_APPROVAL_RECORDED approvers [C]');
SELECT is((pg_temp.ev('d13', 'HITL_APPROVAL_RECORDED')).policy_rationale,
  pg_temp.recorded_rat('d13', 1, 2, 'C', 'A') || '; 1 earlier approvals no longer count', 'D13: the rationale ends 1 earlier approvals no longer count');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
INSERT INTO v VALUES ('d13l', pg_temp.dec('L', 'd13', 'APPROVED'));
SELECT is(pg_temp.ch(pg_temp.g('d13l')) || '/' || (pg_temp.g('d13l')->>'committed'), 'OK/200/true', 'D13: a further eligible approver L decides');
SELECT is((pg_temp.ev('d13', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['C', 'L']), 'D13: HITL_RESOLVED approvers [C, L]');
SELECT pg_temp.revoke_approver('L');
SELECT tests.grant_approver(pg_temp.e('B'), NULL, NULL, now() - interval '1 day');

-- ============================================================================
-- D14: an earlier approver deactivated, then reactivated (W12)
-- ============================================================================
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
SELECT pg_temp.crit('d14');
INSERT INTO v VALUES ('d14b', pg_temp.dec('B', 'd14', 'APPROVED'));
SELECT is(pg_temp.admin_active('B', false)->>'ok', 'true', 'D14 setup: C deactivates B');
INSERT INTO v VALUES ('d14c', pg_temp.dec('C', 'd14', 'APPROVED'));
SELECT is(pg_temp.g('d14c')->>'code' || '/' || (pg_temp.g('d14c')->>'approvals_received'), 'AWAITING_FURTHER_APPROVAL/1',
  'D14: with B deactivated, C''s approval is partial (1 of 2)');
SELECT is(pg_temp.admin_active('B', true)->>'ok', 'true', 'D14 setup: C reactivates B');
INSERT INTO v VALUES ('d14l', pg_temp.dec('L', 'd14', 'APPROVED'));
SELECT is(pg_temp.g('d14l')->>'code' || '/' || (pg_temp.g('d14l')->>'committed'), 'OK/true', 'D14: L decides');
SELECT is((pg_temp.ev('d14', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['B', 'C', 'L']),
  'D14: B counts again after reactivation: HITL_RESOLVED approvers [B, C, L]');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- D15, D16: the commit gates run only at the deciding call
-- ============================================================================
SELECT pg_temp.crit('d15');
INSERT INTO v VALUES ('d15b', pg_temp.dec('B', 'd15', 'APPROVED'));
SELECT pg_temp.agent('DEPRECATED', 2);
INSERT INTO v VALUES ('d15_j0', to_jsonb(tests.journal_count('AGENT_NOT_ACTIVE')));
INSERT INTO v VALUES ('d15c', pg_temp.dec('C', 'd15', 'APPROVED'));
SELECT pg_temp.agent('ACTIVE', 2);
SELECT is(pg_temp.g('d15b')->>'code' || '/' || pg_temp.ch(pg_temp.g('d15c')) || '/' || (pg_temp.g('d15c')->>'decision') || '/' || (pg_temp.g('d15c')->>'committed'),
  'AWAITING_FURTHER_APPROVAL/AGENT_NOT_ACTIVE/409/APPROVED/false', 'D15: the deciding approval of a deprecated agent''s request is AGENT_NOT_ACTIVE (409)');
SELECT is(pg_temp.keys(pg_temp.g('d15c')),
  ARRAY['code', 'committed', 'committed_ledger_id', 'decided_at', 'decision', 'hitl_id', 'http_status', 'message', 'ok', 'ref'], 'D15: the core 10 keys');
SELECT is((pg_temp.ev('d15', 'COMMIT_BLOCKED')).inputs->>'code' || '/' || tests.run_state(pg_temp.rc('d15')) || '/' || pg_temp.nev('d15', 'COMMITTED'),
  'AGENT_NOT_ACTIVE/FAILED/0', 'D15: COMMIT_BLOCKED inputs.code AGENT_NOT_ACTIVE; run FAILED; no COMMITTED');
SELECT ok((pg_temp.ev('d15', 'HITL_RESOLVED')).inputs->'approvers' = pg_temp.ids(ARRAY['B', 'C'])
          AND tests.journal_count('AGENT_NOT_ACTIVE') = (pg_temp.g('d15_j0')#>>'{}')::bigint + 1 AND pg_temp.g('d15c')->>'ref' IS NOT NULL,
  'D15: HITL_RESOLVED approvers [B, C]; the refusal is journaled');

SELECT pg_temp.crit('d16');
INSERT INTO v VALUES ('d16b', pg_temp.dec('B', 'd16', 'APPROVED'));
SELECT pg_temp.owner_active('A', false);
INSERT INTO v VALUES ('d16c', pg_temp.dec('C', 'd16', 'APPROVED'));
SELECT pg_temp.owner_active('A', true);
SELECT is(pg_temp.g('d16b')->>'code' || '/' || pg_temp.ch(pg_temp.g('d16c')) || '/' || (pg_temp.g('d16c')->>'decision') || '/' || (pg_temp.g('d16c')->>'committed'),
  'AWAITING_FURTHER_APPROVAL/INVOKER_NOT_ACTIVE/409/APPROVED/false', 'D16: with the invoker deactivated, the deciding approval is INVOKER_NOT_ACTIVE (409)');
SELECT is((pg_temp.ev('d16', 'COMMIT_BLOCKED')).inputs->>'reason' || '/' || tests.run_state(pg_temp.rc('d16')) || '/' || array_length(pg_temp.keys(pg_temp.g('d16c')), 1),
  'INVOKER_NOT_ACTIVE/FAILED/10', 'D16: COMMIT_BLOCKED inputs.reason INVOKER_NOT_ACTIVE; run FAILED; the core 10 keys');

-- ============================================================================
-- D17: the deadline passes after a partial approval
-- ============================================================================
SELECT pg_temp.crit('d17');
INSERT INTO v VALUES ('d17b', pg_temp.dec('B', 'd17', 'APPROVED'));
SELECT tests.set_clock(90000);
INSERT INTO v VALUES ('d17c', pg_temp.dec('C', 'd17', 'APPROVED'));
SELECT tests.set_clock(0);
SELECT is(pg_temp.g('d17b')->>'code' || '/' || pg_temp.ch(pg_temp.g('d17c')) || '/' || tests.approval_count(pg_temp.id('d17')),
  'AWAITING_FURTHER_APPROVAL/EXPIRED/410/1', 'D17: after the deadline the second approval is EXPIRED (410); still one approval row');

-- ============================================================================
-- D18: threshold 3, CRITICAL (3 of 3)
-- ============================================================================
SELECT pg_temp.agent('ACTIVE', 3);
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
SELECT pg_temp.crit('d18');
SELECT pg_temp.agent('ACTIVE', 2);
INSERT INTO v VALUES ('d18b', pg_temp.dec('B', 'd18', 'APPROVED'));
SELECT is((pg_temp.ev('d18', 'HITL_APPROVAL_RECORDED')).policy_rationale, pg_temp.recorded_rat('d18', 1, 3, 'B', 'A'), 'D18: the first approval is approval 1 of 3');
INSERT INTO v VALUES ('d18c', pg_temp.dec('C', 'd18', 'APPROVED'));
SELECT is((pg_temp.ev('d18', 'HITL_APPROVAL_RECORDED')).policy_rationale, pg_temp.recorded_rat('d18', 2, 3, 'C', 'A'), 'D18: the second approval is approval 2 of 3');
INSERT INTO v VALUES ('d18l', pg_temp.dec('L', 'd18', 'APPROVED'));
SELECT is((SELECT configured_approvals || '/' || enforced_approvals FROM pg_temp.req('d18')) || '/' || (pg_temp.g('d18b')->>'code') || '/' || (pg_temp.g('d18c')->>'code')
          || '/' || (pg_temp.g('d18l')->>'code') || '/' || pg_temp.nev('d18', 'HITL_APPROVAL_RECORDED'),
  '3/3/AWAITING_FURTHER_APPROVAL/AWAITING_FURTHER_APPROVAL/OK/2', 'D18: 3 of 3: two partial approvals, then L decides; two HITL_APPROVAL_RECORDED');
SELECT is((pg_temp.ev('d18', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['B', 'C', 'L']), 'D18: HITL_RESOLVED approvers [B, C, L]');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- D19: legacy PENDING CRITICAL request with enforced_approvals 1 (3.4)
-- ============================================================================
SELECT pg_temp.crit('d19');
ALTER TABLE public.hitl_queue DISABLE TRIGGER hitl_queue_guard_row;
UPDATE public.hitl_queue SET enforced_approvals = 1 WHERE hitl_id = pg_temp.id('d19');
ALTER TABLE public.hitl_queue ENABLE TRIGGER hitl_queue_guard_row;
SELECT is((SELECT count(*) FROM public.hitl_queue WHERE decision = 'PENDING' AND sub_tier = 'CRITICAL' AND enforced_approvals < configured_approvals),
  1::bigint, 'D19: the 0018 legacy report query counts the one legacy request');
INSERT INTO v VALUES ('d19b', pg_temp.dec('B', 'd19', 'APPROVED'));
SELECT is(pg_temp.ch(pg_temp.g('d19b')) || '/' || (pg_temp.g('d19b')->>'committed') || '/' || tests.approval_count(pg_temp.id('d19')),
  'OK/200/true/1', 'D19: a legacy request is decided by its first approval (one approval row)');
SELECT is((pg_temp.ev('d19', 'HITL_RESOLVED')).policy_rationale, pg_temp.resolved_rat('d19', 'APPROVED', 'B', 'A', 1, 2),
  'D19: HITL_RESOLVED rationale is exactly the core format (approvals enforced 1 of configured 2)');

-- ============================================================================
-- D20: atomicity
-- ============================================================================
CREATE FUNCTION tests.pgtap_160_raise() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'pgtap 160 forced failure on %', NEW.inputs->>'event_type'; END $$;
SELECT pg_temp.crit('d20');
INSERT INTO v VALUES ('d20_l0', to_jsonb(tests.ledger_count(pg_temp.rc('d20'))));
CREATE TRIGGER pgtap_160_fail BEFORE INSERT ON public.shadow_ledger FOR EACH ROW
  WHEN (NEW.inputs->>'event_type' = 'HITL_APPROVAL_RECORDED') EXECUTE FUNCTION tests.pgtap_160_raise();
INSERT INTO v VALUES ('d20a', pg_temp.dec('B', 'd20', 'APPROVED'));
DROP TRIGGER pgtap_160_fail ON public.shadow_ledger;
SELECT ok(pg_temp.g('d20a') ? 'error' AND tests.approval_count(pg_temp.id('d20')) = 0
          AND (pg_temp.req('d20')).decision = 'PENDING' AND tests.ledger_count(pg_temp.rc('d20')) = (pg_temp.g('d20_l0')#>>'{}')::bigint,
  'D20: a failure writing HITL_APPROVAL_RECORDED rolls back the approval row; request PENDING; no new ledger row');
INSERT INTO v VALUES ('d20b', pg_temp.dec('B', 'd20', 'APPROVED'));
SELECT is(pg_temp.g('d20b')->>'code', 'AWAITING_FURTHER_APPROVAL', 'D20: without the trigger the same call records the approval');
CREATE TRIGGER pgtap_160_fail BEFORE INSERT ON public.shadow_ledger FOR EACH ROW
  WHEN (NEW.inputs->>'event_type' = 'HITL_RESOLVED') EXECUTE FUNCTION tests.pgtap_160_raise();
INSERT INTO v VALUES ('d20c', pg_temp.dec('C', 'd20', 'APPROVED'));
DROP TRIGGER pgtap_160_fail ON public.shadow_ledger;
SELECT ok(pg_temp.g('d20c') ? 'error' AND tests.approval_count(pg_temp.id('d20')) = 1
          AND (pg_temp.req('d20')).decision = 'PENDING' AND tests.run_state(pg_temp.rc('d20')) = 'AWAITING_HITL'
          AND pg_temp.nev('d20', 'HITL_RESOLVED') = 0,
  'D20: a failure writing HITL_RESOLVED rolls back C''s approval row and the decision (count stays 1)');

-- ============================================================================
-- D21: broken audit chain at the deciding call
-- ============================================================================
SELECT pg_temp.crit('d21');
INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, inputs, policy_outcome, policy_rationale, status)
SELECT r.correlation_id, r.execution_id, r.agent_id, r.risk_tier, jsonb_build_object('event_type', 'ASSET_RECONCILED', 'asset', 'SOL', 'ratio', 1.0),
       'ALLOW', 'pgtap 160 stray duplicate row (owner-side tampered chain, as 070)', 'SUCCESS'
  FROM public.run_invocations r WHERE r.correlation_id = pg_temp.rc('d21');
INSERT INTO v VALUES ('d21b', pg_temp.dec('B', 'd21', 'APPROVED'));
INSERT INTO v VALUES ('d21c', pg_temp.dec('C', 'd21', 'APPROVED'));
SELECT is(pg_temp.g('d21b')->>'code' || '/' || (pg_temp.g('d21c')->>'code') || '/' || (pg_temp.g('d21c')->>'ok') || '/' || (pg_temp.g('d21c')->>'committed'),
  'AWAITING_FURTHER_APPROVAL/AUDIT_CHAIN_MISMATCH/true/false', 'D21: B partial, then C gets AUDIT_CHAIN_MISMATCH (ok, not committed)');
SELECT is(pg_temp.nev('d21', 'COMMIT_BLOCKED') || '/' || pg_temp.nev('d21', 'COMMITTED') || '/' || tests.run_state(pg_temp.rc('d21')), '1/0/FAILED',
  'D21: COMMIT_BLOCKED, no COMMITTED, run FAILED');

-- ============================================================================
-- D22: the two new codes
-- ============================================================================
SELECT is(fao_private.code_message('AWAITING_FURTHER_APPROVAL') || '/' || fao_private.code_http('AWAITING_FURTHER_APPROVAL'),
  'Approval recorded. This request needs more approvals before it is decided./200', 'D22: AWAITING_FURTHER_APPROVAL message and 200');
SELECT is(fao_private.code_message('ALREADY_APPROVED') || '/' || fao_private.code_http('ALREADY_APPROVED'),
  'You have already approved this request./409', 'D22: ALREADY_APPROVED message and 409');
SELECT is((fao_private.refuse('pgtap:160', 'hitl_queue', '1', '{}'::jsonb, 'ALREADY_APPROVED', false))->>'http_status', '409',
  'D22: refuse(..., ALREADY_APPROVED) gives 409');

-- ============================================================================
-- D23: restore case (W23): a repeat approval decides once both count again
-- ============================================================================
SELECT pg_temp.crit('d23');
INSERT INTO v VALUES ('d23b', pg_temp.dec('B', 'd23', 'APPROVED'));
SELECT is(pg_temp.admin_active('B', false)->>'ok', 'true', 'D23 setup: C deactivates B');
INSERT INTO v VALUES ('d23c', pg_temp.dec('C', 'd23', 'APPROVED'));
SELECT is(pg_temp.g('d23c')->>'code' || '/' || (pg_temp.g('d23c')->>'approvals_received'), 'AWAITING_FURTHER_APPROVAL/1', 'D23: C''s approval is partial, 1 of 2');
INSERT INTO v VALUES ('d23c2', pg_temp.dec('C', 'd23', 'APPROVED'));
SELECT is(pg_temp.ch(pg_temp.g('d23c2')) || '/' || pg_temp.jr(pg_temp.g('d23c2')) || '/' || tests.approval_count(pg_temp.id('d23')),
  'ALREADY_APPROVED/409/ALREADY_APPROVED/hitl_queue/' || pg_temp.id('d23') || '/APPROVED/2', 'D23: C again before the restore: ALREADY_APPROVED, journaled; two approval rows');
SELECT is(pg_temp.admin_active('B', true)->>'ok', 'true', 'D23 setup: C reactivates B');
INSERT INTO v VALUES ('d23g', pg_temp.get('C', 'd23'));
SELECT is((pg_temp.g('d23g')->'request'->>'approvals_received') || '/' || (pg_temp.g('d23g')->'request'->>'viewer_has_approved'), '2/true',
  'D23: fao_hitl_get by C: approvals_received 2, viewer_has_approved true');
INSERT INTO v VALUES ('d23c3', pg_temp.dec('C', 'd23', 'APPROVED'));
SELECT is(pg_temp.ch(pg_temp.g('d23c3')) || '/' || (pg_temp.g('d23c3')->>'committed') || '/' || array_to_string(pg_temp.keys(pg_temp.g('d23c3')), ','),
  'OK/200/true/code,committed,committed_ledger_id,decided_at,decision,hitl_id,http_status,message,ok,ref', 'D23: C''s repeat approval now decides with the core 10 keys');
SELECT is(tests.approval_count(pg_temp.id('d23')) || '/' || (SELECT decision::text || '/' || approver_id::text FROM pg_temp.req('d23')),
  '2/APPROVED/' || pg_temp.u('C')::text, 'D23: no new approval row; request APPROVED by C');
SELECT ok((SELECT (e).inputs->'approvers' = pg_temp.ids(ARRAY['B', 'C']) AND (e).inputs->'approver_id' = pg_temp.uj('C')
             FROM (SELECT pg_temp.ev('d23', 'HITL_RESOLVED') AS e) x),
  'D23: HITL_RESOLVED approvers [B, C], approver_id C');
SELECT is((pg_temp.ev('d23', 'HITL_RESOLVED')).policy_rationale,
  pg_temp.resolved_rat('d23', 'APPROVED', 'C', 'A', 2, 2) || '; approvers ' || pg_temp.approvers_txt(ARRAY['B', 'C']), 'D23: HITL_RESOLVED rationale');
SELECT is((pg_temp.ev('d23', 'COMMITTED')).status::text || '/' || tests.run_state(pg_temp.rc('d23')), 'SUCCESS/COMMITTED', 'D23: COMMITTED SUCCESS; run COMMITTED');

-- ============================================================================
-- D24: bounded lock wait (C18), source and setting
-- ============================================================================
SELECT is((SELECT (length(s) - length(replace(s, $s$set_config('lock_timeout', '2s', true)$s$, ''))) / length($s$set_config('lock_timeout', '2s', true)$s$)
             FROM (SELECT pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure) AS s) x),
  1, 'D24: fao_hitl_decide sets lock_timeout 2s exactly once');
SELECT is((SELECT (length(s) - length(replace(s, 'EXCEPTION WHEN lock_not_available', ''))) / length('EXCEPTION WHEN lock_not_available')
             FROM (SELECT pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure) AS s) x),
  2, 'D24: fao_hitl_decide catches lock_not_available twice (step 4 and step 9)');
SELECT is((SELECT proconfig FROM pg_proc WHERE oid = 'public.fao_hitl_decide(json)'::regprocedure), ARRAY['search_path=""'],
  'D24: fao_hitl_decide has no SET clause beyond search_path');
INSERT INTO v VALUES ('d24_lt', to_jsonb(current_setting('lock_timeout')));
SELECT set_config('lock_timeout', '7s', true);
SELECT pg_temp.crit('d24');
INSERT INTO v VALUES ('d24b', pg_temp.dec('B', 'd24', 'APPROVED'));
INSERT INTO v VALUES ('d24t1', to_jsonb(current_setting('lock_timeout')));
INSERT INTO v VALUES ('d24b2', pg_temp.dec('B', 'd24', 'APPROVED'));
INSERT INTO v VALUES ('d24t2', to_jsonb(current_setting('lock_timeout')));
INSERT INTO v VALUES ('d24c', pg_temp.dec('C', 'd24', 'APPROVED'));
INSERT INTO v VALUES ('d24t3', to_jsonb(current_setting('lock_timeout')));
SELECT set_config('lock_timeout', pg_temp.g('d24_lt')#>>'{}', true);
SELECT is(pg_temp.g('d24b')->>'code' || '/' || (pg_temp.g('d24t1')#>>'{}') || ',' || (pg_temp.g('d24b2')->>'code') || '/' || (pg_temp.g('d24t2')#>>'{}')
          || ',' || (pg_temp.g('d24c')->>'code') || '/' || (pg_temp.g('d24t3')#>>'{}'),
  'AWAITING_FURTHER_APPROVAL/7s,ALREADY_APPROVED/7s,OK/7s', 'D24: lock_timeout is restored after a partial, an ALREADY_APPROVED and a deciding call');

-- ============================================================================
-- D25: DA-4, a grant made after the request opened (W26)
-- ============================================================================
SELECT pg_temp.crit('d25');
SELECT is((pg_temp.req('d25')).created_at, now(), 'D25 setup: the request was created at the transaction start');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, now());
INSERT INTO v VALUES ('d25a', pg_temp.dec('L', 'd25', 'APPROVED'));
INSERT INTO v VALUES ('d25r', pg_temp.dec('L', 'd25', 'REJECTED'));
SELECT is(pg_temp.ch(pg_temp.g('d25a')) || ',' || pg_temp.ch(pg_temp.g('d25r')), 'NOT_AUTHORISED/403,NOT_AUTHORISED/403',
  'D25: a grant with granted_at equal to created_at does not qualify: NOT_AUTHORISED for approve and reject');
SELECT ok(pg_temp.keys(pg_temp.g('d25a')) = ARRAY['code', 'http_status', 'message', 'ok', 'ref'] AND pg_temp.keys(pg_temp.g('d25r')) = ARRAY['code', 'http_status', 'message', 'ok', 'ref'],
  'D25: both refusals have the plain five keys');
SELECT is(pg_temp.jr(pg_temp.g('d25a')) || ',' || pg_temp.jr(pg_temp.g('d25r')),
  'NOT_AUTHORISED/hitl_queue/' || pg_temp.id('d25') || '/APPROVED,NOT_AUTHORISED/hitl_queue/' || pg_temp.id('d25') || '/REJECTED',
  'D25: two journal rows, attempted.decision as sent');
SELECT is(tests.approval_count(pg_temp.id('d25')) || '/' || (pg_temp.req('d25')).decision::text, '0/PENDING', 'D25: no approval row; the request stays PENDING');
SELECT pg_temp.revoke_approver('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, (pg_temp.req('d25')).created_at - interval '1 microsecond');
INSERT INTO v VALUES ('d25b', pg_temp.dec('L', 'd25', 'APPROVED'));
SELECT is(pg_temp.g('d25b')->>'code' || '/' || (pg_temp.g('d25b')->>'approvals_received'), 'AWAITING_FURTHER_APPROVAL/1',
  'D25: a grant one microsecond before created_at qualifies (1 of 2)');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- D26: DA-4, a grant made by the invoker (W27)
-- ============================================================================
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('A'), pg_temp.hour_ago());
SELECT pg_temp.crit('d26');
SELECT is(pg_temp.ch(pg_temp.dec('L', 'd26', 'APPROVED')) || ',' || pg_temp.ch(pg_temp.dec('L', 'd26', 'REJECTED')) || ',' || tests.approval_count(pg_temp.id('d26')),
  'NOT_AUTHORISED/403,NOT_AUTHORISED/403,0', 'D26: a grant made by the invoker A does not qualify on A''s request; no approval row');
SELECT pg_temp.crit('d26b', 'B');
SELECT is(pg_temp.dec('L', 'd26b', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'D26: the same grant qualifies on a request invoked by B');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- D27: DA-4, co-approver, approver first (W28)
-- ============================================================================
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('C'), pg_temp.hour_ago());
SELECT pg_temp.crit('d27');
INSERT INTO v VALUES ('d27l', pg_temp.dec('L', 'd27', 'APPROVED'));
SELECT is(pg_temp.g('d27l')->>'code' || '/' || (pg_temp.g('d27l')->>'approvals_received'), 'AWAITING_FURTHER_APPROVAL/1',
  'D27: L (granted by C) approves first and counts: 1 of 2');
INSERT INTO v VALUES ('d27c', pg_temp.dec('C', 'd27', 'APPROVED'));
SELECT is(pg_temp.g('d27c')->>'code' || '/' || (pg_temp.g('d27c')->>'approvals_received'), 'AWAITING_FURTHER_APPROVAL/1',
  'D27: C approves: L stops counting, the count is recomputed: still 1');
SELECT is((pg_temp.ev('d27', 'HITL_APPROVAL_RECORDED')).inputs->'approvers', pg_temp.ids(ARRAY['C']), 'D27: HITL_APPROVAL_RECORDED approvers [C]');
SELECT is((pg_temp.ev('d27', 'HITL_APPROVAL_RECORDED')).policy_rationale,
  pg_temp.recorded_rat('d27', 1, 2, 'C', 'A') || '; 1 earlier approvals no longer count', 'D27: the rationale ends 1 earlier approvals no longer count');
SELECT is(fao_private.counted_approvals(pg_temp.id('d27')), pg_temp.uarr(ARRAY['C']), 'D27: counted_approvals is [C]');
INSERT INTO v VALUES ('d27l2', pg_temp.dec('L', 'd27', 'APPROVED'));
SELECT is(pg_temp.ch(pg_temp.g('d27l2')) || '/' || pg_temp.jr(pg_temp.g('d27l2')), 'NOT_AUTHORISED/403/NOT_AUTHORISED/hitl_queue/' || pg_temp.id('d27') || '/APPROVED',
  'D27: L''s repeat approval is NOT_AUTHORISED (not ALREADY_APPROVED), journaled');
INSERT INTO v VALUES ('d27b', pg_temp.dec('B', 'd27', 'APPROVED'));
SELECT is(pg_temp.g('d27b')->>'code' || '/' || (pg_temp.g('d27b')->>'committed'), 'OK/true', 'D27: B decides');
SELECT is((pg_temp.ev('d27', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['C', 'B']), 'D27: HITL_RESOLVED approvers [C, B]');
SELECT is((pg_temp.ev('d27', 'HITL_RESOLVED')).policy_rationale,
  pg_temp.resolved_rat('d27', 'APPROVED', 'B', 'A', 2, 2) || '; approvers ' || pg_temp.approvers_txt(ARRAY['C', 'B']) || '; 1 earlier approvals no longer count',
  'D27: HITL_RESOLVED rationale names C, B and one approval that no longer counts');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- D28: DA-4, co-approver, granter first (W29)
-- ============================================================================
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('C'), pg_temp.hour_ago());
SELECT pg_temp.crit('d28');
INSERT INTO v VALUES ('d28c', pg_temp.dec('C', 'd28', 'APPROVED'));
INSERT INTO v VALUES ('d28l', pg_temp.dec('L', 'd28', 'APPROVED'));
SELECT is(pg_temp.g('d28c')->>'code' || '/' || pg_temp.ch(pg_temp.g('d28l')) || '/' || pg_temp.jr(pg_temp.g('d28l')) || '/' || tests.approval_count(pg_temp.id('d28')),
  'AWAITING_FURTHER_APPROVAL/NOT_AUTHORISED/403/NOT_AUTHORISED/hitl_queue/' || pg_temp.id('d28') || '/APPROVED/1',
  'D28: after C approved, L (granted by C) may not approve: NOT_AUTHORISED, journaled; one approval row');
SELECT is(pg_temp.get('L', 'd28')->'request'->>'viewer_can_decide', 'true', 'D28: fao_hitl_get gives L viewer_can_decide true (L may still reject)');
INSERT INTO v VALUES ('d28r', pg_temp.dec('L', 'd28', 'REJECTED'));
SELECT is(pg_temp.g('d28r')->>'code' || '/' || (SELECT decision::text || '/' || approver_id::text FROM pg_temp.req('d28')), 'OK/REJECTED/' || pg_temp.u('L')::text,
  'D28: L''s rejection closes the request (the co-approver rule applies to approvals only)');
SELECT is((pg_temp.ev('d28', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['L']), 'D28: HITL_RESOLVED approvers [L]');
SELECT is((pg_temp.ev('d28', 'HITL_RESOLVED')).policy_rationale,
  pg_temp.resolved_rat('d28', 'REJECTED', 'L', 'A', 2, 2) || '; approvals received 1 of 2 before the rejection', 'D28: HITL_RESOLVED rationale');
SELECT is((pg_temp.ev('d28', 'COMMITTED')).status::text, 'ROLLED_BACK', 'D28: COMMITTED ROLLED_BACK');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- D30: DA-4, one disqualified and one qualifying grant (W30)
-- ============================================================================
SELECT tests.grant_approver(pg_temp.e('L'), NULL, pg_temp.u('A'), pg_temp.hour_ago());
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
SELECT pg_temp.crit('d30a');
INSERT INTO v VALUES ('d30al', pg_temp.dec('L', 'd30a', 'APPROVED'));
INSERT INTO v VALUES ('d30ac', pg_temp.dec('C', 'd30a', 'APPROVED'));
SELECT is(pg_temp.g('d30al')->>'code' || '/' || (pg_temp.g('d30al')->>'approvals_received') || '/' || (pg_temp.g('d30ac')->>'code'),
  'AWAITING_FURTHER_APPROVAL/1/OK', 'D30 (a): L with a grant by the invoker and a qualifying grant counts; C decides');
SELECT is((pg_temp.ev('d30a', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['L', 'C']), 'D30 (a): HITL_RESOLVED approvers [L, C]');
SELECT pg_temp.revoke_approver('L');
SELECT tests.grant_approver(pg_temp.e('L'), NULL, pg_temp.u('C'), pg_temp.hour_ago());
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
SELECT pg_temp.crit('d30b');
INSERT INTO v VALUES ('d30bc', pg_temp.dec('C', 'd30b', 'APPROVED'));
INSERT INTO v VALUES ('d30bl', pg_temp.dec('L', 'd30b', 'APPROVED'));
SELECT is(pg_temp.g('d30bc')->>'code' || '/' || (pg_temp.g('d30bl')->>'code') || '/' || (pg_temp.g('d30bl')->>'committed'),
  'AWAITING_FURTHER_APPROVAL/OK/true', 'D30 (b): L with a grant by C (who approved) and a qualifying grant decides after C');
SELECT is((pg_temp.ev('d30b', 'HITL_RESOLVED')).inputs->'approvers', pg_temp.ids(ARRAY['C', 'L']), 'D30 (b): HITL_RESOLVED approvers [C, L]');
SELECT pg_temp.revoke_approver('L');

-- ============================================================================
-- D31: DA-4, revoke then grant again while PENDING (W31); last, because it
-- leaves B with only a grant made by C inside this transaction
-- ============================================================================
SELECT pg_temp.crit('d31');
INSERT INTO v VALUES ('d31b', pg_temp.dec('B', 'd31', 'APPROVED'));
SELECT is(pg_temp.admin_role('B', false)->>'ok', 'true', 'D31 setup: C revokes B''s grant');
SELECT is(pg_temp.admin_role('B', true)->>'ok', 'true', 'D31 setup: C grants it again (granted_by C, granted_at the request''s own time)');
INSERT INTO v VALUES ('d31c', pg_temp.dec('C', 'd31', 'APPROVED'));
SELECT is(pg_temp.g('d31b')->>'code' || '/' || (pg_temp.g('d31c')->>'code') || '/' || (pg_temp.g('d31c')->>'approvals_received'),
  'AWAITING_FURTHER_APPROVAL/AWAITING_FURTHER_APPROVAL/1', 'D31: the re-grant does not restore B: C''s approval is partial, 1 of 2');
SELECT is(pg_temp.ch(pg_temp.dec('B', 'd31', 'APPROVED')) || ',' || pg_temp.ch(pg_temp.dec('B', 'd31', 'REJECTED')), 'NOT_AUTHORISED/403,NOT_AUTHORISED/403',
  'D31: B''s later approve and reject are NOT_AUTHORISED');
INSERT INTO v VALUES ('d31g', pg_temp.get('B', 'd31'));
SELECT is((pg_temp.g('d31g')->'request'->>'viewer_can_decide') || '/' || (pg_temp.g('d31g')->'request'->>'viewer_has_approved'), 'false/true',
  'D31: fao_hitl_get by B: viewer_can_decide false, viewer_has_approved true');

SELECT * FROM finish();
ROLLBACK;
