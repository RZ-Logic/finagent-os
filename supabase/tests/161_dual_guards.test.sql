-- ============================================================================
-- FinAgent OS pgTAP 161: dual approval, table, guards, RLS and grants
-- Controls:
--   FAO-GOV-004: hitl_approvals is written only by fao_hitl_decide; its row
--     guard holds for every role, the owner included (signed-in approver,
--     the approver is the session user, PENDING before the deadline, run
--     awaiting a decision, never the invoker, approver role, a qualifying
--     approver grant (DA-4), the FinAgent clock, valid notes); rows are
--     append-only. The hitl_queue guard requires enforced_approvals counted
--     approvals for APPROVED and a qualifying grant for REJECTED, and the
--     DA-1 counts at INSERT.
--   FAO-GOV-001: append-only evidence; the Writer cannot append or forge the
--     new event type or its keys.
--   FAO-GOV-015: SELECT for authenticated only, under RLS; no other client
--     privilege; the drift check covers the new table.
-- Owner probes set request.jwt claims without switching role, as 030 does,
-- so the guards see a signed-in user while the statement guard passes.
-- Owner caveat: the guards judge the user that auth.uid() names. An
-- owner-class session that sets its own JWT claims passes as that user;
-- the owner is outside the control (FAO-GOV-001).
-- Users as in 160 (A Aisha invoker, B Sarah, C Marcus, L ratelimit, O
-- outsider, R reader). L's grants are made per case and revoked after it.
-- ============================================================================
BEGIN;
SELECT plan(103);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j#>>'{}')::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.rc(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr(pg_temp.id(p_k)) $$;
CREATE FUNCTION pg_temp.e(p text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE p WHEN 'A' THEN 'aisha.okonkwo@finagent-os.demo' WHEN 'B' THEN 'sarah.chen@finagent-os.demo'
                WHEN 'C' THEN 'marcus.patel@finagent-os.demo' WHEN 'L' THEN 'ratelimit@local.test'
                WHEN 'O' THEN 'outsider@local.test' WHEN 'R' THEN 'mcp.reader@finagent-os.demo' END $$;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.uid(pg_temp.e(p)) $$;
CREATE FUNCTION pg_temp.uarr(p text[]) RETURNS uuid[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(pg_temp.u(x) ORDER BY o), ARRAY[]::uuid[]) FROM unnest(p) WITH ORDINALITY AS t(x, o) $$;
CREATE FUNCTION pg_temp.dec(p_who text, p_k text, p_decision text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.decide_raw(pg_temp.e(p_who), pg_temp.id(p_k)::text, p_decision) $$;
CREATE FUNCTION pg_temp.crit(p_k text, p_who text DEFAULT 'A') RETURNS void LANGUAGE sql AS $$
  INSERT INTO v VALUES (p_k, to_jsonb(tests.make_critical_request(pg_temp.e(p_who)))) $$;
-- Runs p_sql as the owner with the claims of p_who (NULL: no claims) inside
-- a subtransaction; NULL when it succeeds (the change stays), else
-- '<SQLSTATE> <message>'.
CREATE FUNCTION pg_temp.err(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_err text := NULL;
BEGIN
  PERFORM tests.as_owner();
  IF p_who IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', pg_temp.u(p_who), 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', pg_temp.u(p_who)::text, true);
  END IF;
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  PERFORM tests.as_owner();
  RETURN v_err;
END $$;
-- An approval row insert for request p_k by approver p_who
CREATE FUNCTION pg_temp.ins(p_k text, p_who text, p_at text DEFAULT 'fao_private.clock()', p_notes text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT format('INSERT INTO public.hitl_approvals (hitl_id, approver_id, approved_at, decision_notes) VALUES (%s, %L, %s, %L)',
                pg_temp.id(p_k), pg_temp.u(p_who), p_at, p_notes) $$;
CREATE FUNCTION pg_temp.msg(p_text text, p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT '42501 FAO-GOV-004: ' || p_text || ' (hitl_id ' || pg_temp.id(p_k) || ')' $$;
CREATE FUNCTION pg_temp.decide_sql(p_k text, p_decision text, p_who text) RETURNS text LANGUAGE sql AS $$
  SELECT format('UPDATE public.hitl_queue SET decision = %L, approver_id = %L, decided_at = now() WHERE hitl_id = %s',
                p_decision, pg_temp.u(p_who), pg_temp.id(p_k)) $$;
CREATE FUNCTION pg_temp.revoke_all(p text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 161 revoke grants', true);
  UPDATE public.fao_user_roles SET revoked_at = now()
   WHERE user_id = pg_temp.u(p) AND role IN ('approver', 'admin', 'reader') AND revoked_at IS NULL;
END $$;
CREATE FUNCTION pg_temp.grant_role(p text, p_role text, p_agent text, p_by uuid, p_at timestamptz) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 161 grant ' || p_role, true);
  INSERT INTO public.fao_user_roles (user_id, role, agent_id, granted_by, granted_at, reason)
  VALUES (pg_temp.u(p), p_role::public.fao_app_role, p_agent, p_by, p_at, 'pgtap 161 grant ' || p_role);
END $$;
CREATE FUNCTION pg_temp.owner_active(p text, p_active boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 161 owner active ' || p_active::text, true);
  UPDATE public.process_owners SET active = p_active WHERE id = pg_temp.u(p);
END $$;
CREATE FUNCTION pg_temp.q(p_k text, p_who text, p_rule boolean) RETURNS boolean LANGUAGE sql AS $$
  SELECT fao_private.approver_qualifies(pg_temp.id(p_k), pg_temp.u(p_who), p_rule) $$;
CREATE FUNCTION pg_temp.hour_ago() RETURNS timestamptz LANGUAGE sql AS $$ SELECT now() - interval '1 hour' $$;

SELECT tests.set_clock(0);
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 161 run limit', true);
  UPDATE public.agent_registry SET max_runs_per_hour = 60 WHERE agent_id IN ('fao_reserve_recon_v1', 'fao_ratelimit_test_v1');
END $$;

-- ============================================================================
-- G1: table, columns, constraints, FKs, RLS, policy
-- ============================================================================
SELECT has_table('public', 'hitl_approvals', 'G1: hitl_approvals exists');
SELECT results_eq(
  $$SELECT column_name::text COLLATE "default", data_type::text COLLATE "default", is_nullable::text COLLATE "default" FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'hitl_approvals' ORDER BY ordinal_position$$,
  $$VALUES ('approval_id', 'bigint', 'NO'), ('hitl_id', 'bigint', 'NO'), ('approver_id', 'uuid', 'NO'),
           ('approved_at', 'timestamp with time zone', 'NO'), ('decision_notes', 'text', 'YES')$$,
  'G1: columns, types and NOT NULL in order');
SELECT col_is_pk('public', 'hitl_approvals', 'approval_id', 'G1: approval_id is the primary key');
SELECT is((SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid = 'public.hitl_approvals'::regclass AND c.conname = 'hitl_approvals_one_per_approver'),
  'UNIQUE (hitl_id, approver_id)', 'G1: hitl_approvals_one_per_approver is UNIQUE (hitl_id, approver_id)');
SELECT is((SELECT c.contype::text FROM pg_constraint c WHERE c.conrelid = 'public.hitl_approvals'::regclass AND c.conname = 'hitl_approvals_notes_length'),
  'c', 'G1: hitl_approvals_notes_length is a CHECK');
SELECT is((SELECT string_agg(c.conname || ' ' || c.confrelid::regclass::text || ' ' || c.confdeltype::text, ', ' ORDER BY c.conname)
             FROM pg_constraint c WHERE c.conrelid = 'public.hitl_approvals'::regclass AND c.contype = 'f'),
  'hitl_approvals_approver_id_fkey process_owners r, hitl_approvals_hitl_id_fkey hitl_queue r',
  'G1: both FKs exist under their names, to process_owners and hitl_queue, ON DELETE RESTRICT');
SELECT is((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.hitl_approvals'::regclass), true, 'G1: RLS is enabled');
SELECT is((SELECT p.cmd || ' ' || array_to_string(p.roles, ',') || ' ' || p.permissive FROM pg_policies p
            WHERE p.schemaname = 'public' AND p.tablename = 'hitl_approvals' AND p.policyname = 'FAO members read hitl_approvals'),
  'SELECT authenticated PERMISSIVE', 'G1: the member read policy exists for SELECT to authenticated');
SELECT is((SELECT count(*) FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = 'hitl_approvals'), 1::bigint,
  'G1: no other policy (no write policy)');

-- ============================================================================
-- G2: direct writes by every client role
-- ============================================================================
SELECT pg_temp.crit('g2');
SELECT is(pg_temp.dec('B', 'g2', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'G2 setup: one approval row through the RPC');
SELECT is((SELECT string_agg(w || ':' || tests.sqlstate_as(w, format('INSERT INTO public.hitl_approvals (hitl_id, approver_id, approved_at) VALUES (%s, %L, now())',
                                                                        pg_temp.id('g2'), pg_temp.u('C'))), ',' ORDER BY w)
             FROM unnest(ARRAY[pg_temp.e('A'), pg_temp.e('B'), pg_temp.e('C'), pg_temp.e('O'), pg_temp.e('R'), 'anon', 'fao_workflow', 'service_role']) w),
  (SELECT string_agg(w || ':42501', ',' ORDER BY w)
     FROM unnest(ARRAY[pg_temp.e('A'), pg_temp.e('B'), pg_temp.e('C'), pg_temp.e('O'), pg_temp.e('R'), 'anon', 'fao_workflow', 'service_role']) w),
  'G2: direct INSERT on hitl_approvals is 42501 for A, B, C, O, R, anon, fao_workflow and service_role');
SELECT is((SELECT string_agg(w || ':' || tests.sqlstate_as(w, format('UPDATE public.hitl_approvals SET decision_notes = ''x'' WHERE hitl_id = %s', pg_temp.id('g2'))), ',' ORDER BY w)
             FROM unnest(ARRAY[pg_temp.e('A'), pg_temp.e('B'), pg_temp.e('C'), pg_temp.e('O'), pg_temp.e('R'), 'anon', 'fao_workflow', 'service_role']) w),
  (SELECT string_agg(w || ':42501', ',' ORDER BY w)
     FROM unnest(ARRAY[pg_temp.e('A'), pg_temp.e('B'), pg_temp.e('C'), pg_temp.e('O'), pg_temp.e('R'), 'anon', 'fao_workflow', 'service_role']) w),
  'G2: direct UPDATE on hitl_approvals is 42501 for every client role');
SELECT is((SELECT string_agg(w || ':' || tests.sqlstate_as(w, format('DELETE FROM public.hitl_approvals WHERE hitl_id = %s', pg_temp.id('g2'))), ',' ORDER BY w)
             FROM unnest(ARRAY[pg_temp.e('A'), pg_temp.e('B'), pg_temp.e('C'), pg_temp.e('O'), pg_temp.e('R'), 'anon', 'fao_workflow', 'service_role']) w),
  (SELECT string_agg(w || ':42501', ',' ORDER BY w)
     FROM unnest(ARRAY[pg_temp.e('A'), pg_temp.e('B'), pg_temp.e('C'), pg_temp.e('O'), pg_temp.e('R'), 'anon', 'fao_workflow', 'service_role']) w),
  'G2: direct DELETE on hitl_approvals is 42501 for every client role');
SELECT is(tests.approval_count(pg_temp.id('g2')), 1::bigint, 'G2: the approval row is unchanged');

-- ============================================================================
-- G3: the row guard, every rule, for the owner
-- ============================================================================
SELECT pg_temp.crit('g3');
SELECT is(pg_temp.err(NULL, pg_temp.ins('g3', 'B')), pg_temp.msg('an approval needs a signed-in approver', 'g3'), 'G3: owner with no session: refused');
SELECT is(pg_temp.err('B', pg_temp.ins('g3', 'C')), pg_temp.msg('the approver must be the signed-in user', 'g3'), 'G3: B''s claims with approver C: refused');
SELECT is(pg_temp.err('A', pg_temp.ins('g3', 'A')), pg_temp.msg('segregation of duties: the invoker cannot approve their own run', 'g3'), 'G3: the invoker A: refused');
SELECT is(pg_temp.err('R', pg_temp.ins('g3', 'R')), pg_temp.msg('the approver does not hold the approver role for this agent', 'g3'), 'G3: the reader R: refused');
INSERT INTO v VALUES ('g3d', to_jsonb(tests.make_request(pg_temp.e('A'))));
SELECT is(pg_temp.dec('C', 'g3d', 'APPROVED')->>'code', 'OK', 'G3 setup: a decided request');
SELECT is(pg_temp.err('B', pg_temp.ins('g3d', 'B')), pg_temp.msg('approvals are recorded only for a PENDING request before its deadline', 'g3d'), 'G3: a decided request: refused');
SELECT tests.set_clock(90000);
SELECT is(pg_temp.err('B', pg_temp.ins('g3', 'B')), pg_temp.msg('approvals are recorded only for a PENDING request before its deadline', 'g3'), 'G3: past the deadline: refused');
SELECT tests.set_clock(0);
SELECT is(pg_temp.err('B', pg_temp.ins('g3', 'B', $$fao_private.clock() - interval '1 second'$$)), pg_temp.msg('the approval time must be the FinAgent clock', 'g3'),
  'G3: approved_at not the FinAgent clock: refused');
SELECT is(pg_temp.err('B', pg_temp.ins('g3', 'B', 'fao_private.clock()', E'bad\u0001notes')), pg_temp.msg('approval notes are not valid', 'g3'),
  'G3: notes with a control character: refused');
SELECT pg_temp.crit('g3r');
ALTER TABLE public.run_invocations DISABLE TRIGGER run_invocations_guard_row;
UPDATE public.run_invocations SET state = 'FAILED' WHERE correlation_id = pg_temp.rc('g3r');
ALTER TABLE public.run_invocations ENABLE TRIGGER run_invocations_guard_row;
SELECT is(pg_temp.err('B', pg_temp.ins('g3r', 'B')), pg_temp.msg('approvals are recorded only while the run awaits a decision', 'g3r'), 'G3: the run is FAILED: refused');
-- DA-4
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, now());
SELECT is(pg_temp.err('L', pg_temp.ins('g3', 'L')), pg_temp.msg('the approver holds no qualifying approver grant for this request', 'g3'),
  'G3: L''s only grant made in the test at now() (equal to created_at): refused (DA-4)');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('A'), pg_temp.hour_ago());
SELECT is(pg_temp.err('L', pg_temp.ins('g3', 'L')), pg_temp.msg('the approver holds no qualifying approver grant for this request', 'g3'),
  'G3: L''s only grant made by the invoker A: refused (DA-4)');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('C'), pg_temp.hour_ago());
SELECT is(pg_temp.err('C', pg_temp.ins('g3', 'C')), NULL, 'G3 setup: C''s approval row (owner with C''s claims)');
SELECT is(pg_temp.err('L', pg_temp.ins('g3', 'L')), pg_temp.msg('the approver holds no qualifying approver grant for this request', 'g3'),
  'G3: L''s only grant made by C while C has an approval row: refused (DA-4)');
SELECT pg_temp.revoke_all('L');

-- ============================================================================
-- G4, G5: a valid owner insert, the unique key, no change or delete
-- ============================================================================
SELECT pg_temp.crit('g4');
SELECT is(pg_temp.err('B', pg_temp.ins('g4', 'B')), NULL, 'G4: owner with B''s claims inserts a valid row');
SELECT matches(pg_temp.err('B', pg_temp.ins('g4', 'B')), '^23505 ', 'G4: the same row again fails on the unique key (23505)');
SELECT matches(pg_temp.err(NULL, format('UPDATE public.hitl_approvals SET decision_notes = ''x'' WHERE hitl_id = %s', pg_temp.id('g4'))),
  '^42501 FAO-GOV-004: approvals cannot be changed or deleted \(approval_id [0-9]+\)$', 'G5: owner UPDATE of an approval row is refused');
SELECT matches(pg_temp.err(NULL, format('DELETE FROM public.hitl_approvals WHERE hitl_id = %s', pg_temp.id('g4'))),
  '^42501 FAO-GOV-004: approvals cannot be changed or deleted \(approval_id [0-9]+\)$', 'G5: owner DELETE of an approval row is refused');
SELECT is(pg_temp.err(NULL, 'TRUNCATE public.hitl_approvals'), '42501 FAO-GOV-001: TRUNCATE is not permitted on hitl_approvals', 'G5: owner TRUNCATE is refused');
SELECT is(pg_temp.err(NULL, 'TRUNCATE public.hitl_approvals CASCADE'), '42501 FAO-GOV-001: TRUNCATE is not permitted on hitl_approvals', 'G5: owner TRUNCATE CASCADE is refused');
SELECT is(tests.approval_count(pg_temp.id('g4')), 1::bigint, 'G5: the row is still there');

-- ============================================================================
-- G6: the hitl_queue row guard for decisions
-- ============================================================================
SELECT pg_temp.crit('g6');
SELECT is(pg_temp.err('C', pg_temp.decide_sql('g6', 'APPROVED', 'C')),
  pg_temp.msg('an approval decision needs the enforced number of counted approvals, the approver''s among them', 'g6'), 'G6: APPROVED with no approval row: refused');
SELECT is(pg_temp.dec('B', 'g6', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'G6 setup: B''s approval row');
SELECT is(pg_temp.err('C', pg_temp.decide_sql('g6', 'APPROVED', 'C')),
  pg_temp.msg('an approval decision needs the enforced number of counted approvals, the approver''s among them', 'g6'), 'G6: B''s row only, approver C: refused');
SELECT is(pg_temp.err('B', pg_temp.decide_sql('g6', 'APPROVED', 'B')),
  pg_temp.msg('an approval decision needs the enforced number of counted approvals, the approver''s among them', 'g6'), 'G6: B''s row only, approver B (1 of 2): refused');
SELECT is(pg_temp.err('C', pg_temp.ins('g6', 'C')), NULL, 'G6 setup: C''s approval row (owner with C''s claims)');
SELECT is(pg_temp.err('C', pg_temp.decide_sql('g6', 'APPROVED', 'C')), NULL, 'G6: rows B and C, approver C: passes (control)');
SELECT pg_temp.crit('g6r');
SELECT is(pg_temp.err('C', pg_temp.decide_sql('g6r', 'REJECTED', 'C')), NULL, 'G6: REJECTED with no approval row: passes (control)');
SELECT pg_temp.crit('g6l');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('A'), pg_temp.hour_ago());
SELECT is(pg_temp.err('L', pg_temp.decide_sql('g6l', 'REJECTED', 'L')),
  pg_temp.msg('the approver holds no qualifying approver grant for this request', 'g6l'), 'G6: REJECTED by L whose only grant was made by the invoker: refused (DA-4)');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('C'), pg_temp.hour_ago());
SELECT is(pg_temp.dec('C', 'g6l', 'APPROVED')->>'code', 'AWAITING_FURTHER_APPROVAL', 'G6 setup: C''s approval row on the request');
SELECT is(pg_temp.err('L', pg_temp.decide_sql('g6l', 'REJECTED', 'L')), NULL,
  'G6: REJECTED by L whose only grant was made by C, with C''s row present: passes (no co-approver rule for a rejection)');
SELECT pg_temp.revoke_all('L');

-- ============================================================================
-- G7: hitl_queue INSERT counts (DA-1)
-- ============================================================================
CREATE FUNCTION pg_temp.req_ins(p_corr uuid, p_sub text, p_conf int, p_enf int) RETURNS text LANGUAGE sql AS $$
  SELECT format($q$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, sub_tier, policy_rationale, timeout_at, configured_approvals, enforced_approvals)
                   VALUES (%L, 'fao_reserve_recon_v1', %L, 'RED', %L, 'pgtap 161 owner insert', now() + interval '1 day', %s, %s)$q$,
                p_corr, pg_temp.u('A'), p_sub, p_conf, p_enf) $$;
INSERT INTO v VALUES ('g7run', to_jsonb(tests.make_run(pg_temp.e('A'), ARRAY['SOL'])));
SELECT is(pg_temp.err(NULL, pg_temp.req_ins((pg_temp.g('g7run')#>>'{}')::uuid, 'STANDARD', 2, 2)),
  '42501 FAO-GOV-004: a request must record the registry approval threshold and enforce it only for CRITICAL review', 'G7: STANDARD with enforced_approvals 2: refused');
SELECT is(pg_temp.err(NULL, pg_temp.req_ins((pg_temp.g('g7run')#>>'{}')::uuid, 'CRITICAL', 1, 1)),
  '42501 FAO-GOV-004: a request must record the registry approval threshold and enforce it only for CRITICAL review', 'G7: flagship with configured_approvals 1: refused');
SELECT is(pg_temp.err(NULL, pg_temp.req_ins((pg_temp.g('g7run')#>>'{}')::uuid, 'CRITICAL', 2, 1)),
  '42501 FAO-GOV-004: a request must record the registry approval threshold and enforce it only for CRITICAL review', 'G7: CRITICAL with enforced_approvals 1: refused');
SELECT is(pg_temp.err(NULL, pg_temp.req_ins(pg_temp.rc('g6'), 'STANDARD', 2, 2)),
  '42501 FAO-GOV-004: a request needs a RUNNING run record with the same agent, invoker and tier', 'G7: an INSERT that breaks an earlier rule (run not RUNNING) keeps the earlier message');
SELECT is(pg_temp.err(NULL, pg_temp.req_ins((pg_temp.g('g7run')#>>'{}')::uuid, 'CRITICAL', 2, 2)), NULL, 'G7: CRITICAL with 2 and 2 for a RUNNING run: passes (control)');

-- ============================================================================
-- G8: create_request through fao_run_finalize
-- ============================================================================
INSERT INTO v VALUES ('g8s', to_jsonb(tests.make_request(pg_temp.e('A'))));
SELECT pg_temp.crit('g8c');
INSERT INTO v VALUES ('g8run', to_jsonb(tests.make_run(pg_temp.e('L'), ARRAY['SOL'], 'fao_ratelimit_test_v1')));
SELECT tests.append(jsonb_build_array(tests.asset_event((pg_temp.g('g8run')#>>'{}')::uuid, 'SOL', 'REQUIRE_HUMAN', 'CRITICAL')));
INSERT INTO v VALUES ('g8fin', tests.finalize((pg_temp.g('g8run')#>>'{}')::uuid));
INSERT INTO v VALUES ('g8r', to_jsonb((pg_temp.g('g8fin')->>'hitl_id')::bigint));
SELECT is((SELECT configured_approvals || '/' || enforced_approvals || '/' || sub_tier FROM public.hitl_queue WHERE hitl_id = pg_temp.id('g8s')), '2/1/STANDARD',
  'G8: flagship STANDARD: configured 2, enforced 1');
SELECT is((SELECT configured_approvals || '/' || enforced_approvals || '/' || sub_tier FROM public.hitl_queue WHERE hitl_id = pg_temp.id('g8c')), '2/2/CRITICAL',
  'G8: flagship CRITICAL: configured 2, enforced 2');
SELECT is((SELECT configured_approvals || '/' || enforced_approvals || '/' || sub_tier FROM public.hitl_queue WHERE hitl_id = pg_temp.id('g8r')), '1/1/CRITICAL',
  'G8: fao_ratelimit_test_v1 (threshold 1) CRITICAL: configured 1, enforced 1');
SELECT is(pg_temp.err('C', format('UPDATE public.hitl_queue SET decision = ''REJECTED'', approver_id = %L, decided_at = now(), enforced_approvals = 1 WHERE hitl_id = %s',
                                  pg_temp.u('C'), pg_temp.id('g8c'))),
  pg_temp.msg('only the decision fields of a request may change', 'g8c'), 'G8: enforced_approvals on a PENDING row is frozen');

-- ============================================================================
-- G9: RLS
-- ============================================================================
INSERT INTO v VALUES ('g9n', to_jsonb((SELECT count(*) FROM public.hitl_approvals)));
SELECT ok((pg_temp.g('g9n')#>>'{}')::bigint >= 4, 'G9 setup: approval rows exist');
SELECT is(tests.value_as(pg_temp.e('O'), 'SELECT count(*) FROM public.hitl_approvals'), '0', 'G9: the outsider sees no approval row');
SELECT is((SELECT string_agg(tests.value_as(pg_temp.e(w), 'SELECT count(*) FROM public.hitl_approvals'), ',' ORDER BY w) FROM unnest(ARRAY['A', 'B', 'C', 'R']) w),
  repeat((pg_temp.g('g9n')#>>'{}') || ',', 3) || (pg_temp.g('g9n')#>>'{}'), 'G9: A, B, C and the reader see every approval row');

-- ============================================================================
-- G10: grants and function properties
-- ============================================================================
SELECT is_empty(
  $$SELECT r.rolname, p.priv FROM unnest(ARRAY['anon', 'authenticated', 'fao_workflow', 'service_role']) r(rolname)
     CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p(priv)
     WHERE has_table_privilege(r.rolname, 'public.hitl_approvals', p.priv) IS DISTINCT FROM (r.rolname = 'authenticated' AND p.priv = 'SELECT')$$,
  'G10: authenticated SELECT on hitl_approvals and nothing else for any client role');
SELECT is_empty(
  $$SELECT r.rolname, p.priv FROM unnest(ARRAY['anon', 'authenticated', 'fao_workflow', 'service_role']) r(rolname)
     CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) p(priv)
     WHERE has_sequence_privilege(r.rolname, 'public.hitl_approvals_approval_id_seq', p.priv)$$,
  'G10: no client privilege on hitl_approvals_approval_id_seq');
SELECT is_empty($$SELECT * FROM fao_private.grants_drift()$$, 'G10: grants_drift() is empty');
SELECT is((SELECT count(*) FROM fao_private.grants_expected() e
            WHERE e.object_kind = 'table' AND e.schema_name = 'public' AND e.object_name = 'hitl_approvals' AND e.grantee = 'authenticated' AND e.privilege = 'SELECT'),
  1::bigint, 'G10: grants_expected() has the hitl_approvals row');
SELECT is((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'fao_private' AND p.proname IN ('approver_qualifies', 'counted_approvals', 'hitl_approvals_guard_stmt', 'hitl_approvals_guard_row')
              AND p.proconfig @> ARRAY['search_path=""']
              AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated', 'fao_workflow', 'service_role', 'public']) r
                               WHERE CASE WHEN r = 'public' THEN p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0)
                                          ELSE has_function_privilege(r, p.oid, 'EXECUTE') END)),
  4::bigint, 'G10: the four new functions pin search_path and have no client or PUBLIC EXECUTE');
SELECT is((SELECT string_agg(p.proname || ' ' || l.lanname || ' ' || p.provolatile::text || ' ' || p.prosecdef, ', ' ORDER BY p.proname)
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
            WHERE n.nspname = 'fao_private' AND p.proname IN ('approver_qualifies', 'counted_approvals')),
  'approver_qualifies plpgsql s true, counted_approvals plpgsql s true', 'G10: approver_qualifies and counted_approvals are plpgsql, STABLE, SECURITY DEFINER');
SELECT is((SELECT string_agg(p.proname || ' ' || l.lanname || ' ' || p.prosecdef, ', ' ORDER BY p.proname)
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
            WHERE n.nspname = 'fao_private' AND p.proname IN ('hitl_approvals_guard_stmt', 'hitl_approvals_guard_row')),
  'hitl_approvals_guard_row plpgsql false, hitl_approvals_guard_stmt plpgsql false', 'G10: both guard functions are plpgsql SECURITY INVOKER');
SELECT is((SELECT string_agg(t.tgname, ', ' ORDER BY t.tgname) FROM pg_trigger t WHERE t.tgrelid = 'public.hitl_approvals'::regclass AND NOT t.tgisinternal),
  'hitl_approvals_deny_truncate, hitl_approvals_guard_row, hitl_approvals_guard_stmt', 'G10: the three triggers exist');

-- ============================================================================
-- G11: counted_approvals
-- ============================================================================
SELECT pg_temp.crit('g11');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11')), ARRAY[]::uuid[], 'G11: empty for a request with no rows');
SELECT is(fao_private.counted_approvals(999999999999), ARRAY[]::uuid[], 'G11: empty for a missing request');
SELECT is(pg_temp.err('B', pg_temp.ins('g11', 'B')), NULL, 'G11 setup: B''s row');
SELECT is(pg_temp.err('C', pg_temp.ins('g11', 'C')), NULL, 'G11 setup: C''s row');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11')), pg_temp.uarr(ARRAY['B', 'C']), 'G11: approval order B, C');
SELECT pg_temp.revoke_all('B');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11')), pg_temp.uarr(ARRAY['C']), 'G11: a revoked approver is excluded');
SELECT tests.grant_approver(pg_temp.e('B'), NULL, NULL, now() - interval '1 day');
SELECT pg_temp.owner_active('C', false);
SELECT is(fao_private.counted_approvals(pg_temp.id('g11')), pg_temp.uarr(ARRAY['B']), 'G11: a deactivated owner is excluded');
SELECT pg_temp.owner_active('C', true);
ALTER TABLE public.hitl_approvals DISABLE TRIGGER hitl_approvals_guard_row;
INSERT INTO public.hitl_approvals (hitl_id, approver_id, approved_at) VALUES (pg_temp.id('g11'), pg_temp.u('A'), now());
ALTER TABLE public.hitl_approvals ENABLE TRIGGER hitl_approvals_guard_row;
SELECT is(fao_private.counted_approvals(pg_temp.id('g11')), pg_temp.uarr(ARRAY['B', 'C']), 'G11: an invoker row forced in with the guard disabled is excluded');
-- DA-4 rows forced in with the guard disabled, one request each
CREATE FUNCTION pg_temp.force(p_k text, p_who text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  ALTER TABLE public.hitl_approvals DISABLE TRIGGER hitl_approvals_guard_row;
  INSERT INTO public.hitl_approvals (hitl_id, approver_id, approved_at) VALUES (pg_temp.id(p_k), pg_temp.u(p_who), now());
  ALTER TABLE public.hitl_approvals ENABLE TRIGGER hitl_approvals_guard_row;
END $$;
SELECT pg_temp.crit('g11a');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, now());
SELECT pg_temp.force('g11a', 'L');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11a')), ARRAY[]::uuid[], 'G11: excluded: L whose only grant has granted_at equal to created_at');
SELECT pg_temp.revoke_all('L');
SELECT pg_temp.crit('g11b');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('A'), pg_temp.hour_ago());
SELECT pg_temp.force('g11b', 'L');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11b')), ARRAY[]::uuid[], 'G11: excluded: L whose only grant was made by the invoker');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', pg_temp.u('C'), pg_temp.hour_ago());
SELECT pg_temp.crit('g11c');
SELECT is(pg_temp.err('C', pg_temp.ins('g11c', 'C')), NULL, 'G11 setup: C''s row first');
SELECT pg_temp.force('g11c', 'L');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11c')), pg_temp.uarr(ARRAY['C']), 'G11: excluded: L granted by C, whose row comes before L''s');
SELECT pg_temp.crit('g11d');
SELECT is(pg_temp.err('L', pg_temp.ins('g11d', 'L')), NULL, 'G11 setup: L''s row first (C has none yet, so L qualifies)');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11d')), pg_temp.uarr(ARRAY['L']), 'G11: L counts while C has no row');
SELECT is(pg_temp.err('C', pg_temp.ins('g11d', 'C')), NULL, 'G11 setup: C''s row after L''s');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11d')), pg_temp.uarr(ARRAY['C']), 'G11: excluded: L granted by C, whose row comes after L''s');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), NULL, pg_temp.u('A'), pg_temp.hour_ago());
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
SELECT pg_temp.crit('g11e');
SELECT is(pg_temp.err('L', pg_temp.ins('g11e', 'L')), NULL, 'G11 setup: L''s row');
SELECT is(fao_private.counted_approvals(pg_temp.id('g11e')), pg_temp.uarr(ARRAY['L']), 'G11: included: L with a disqualified grant and a second, qualifying grant');
SELECT pg_temp.revoke_all('L');
SELECT is(tests.sqlstate_as(pg_temp.e('B'), format('SELECT fao_private.counted_approvals(%s)', pg_temp.id('g11'))), '42501', 'G11: a direct call as B is 42501');

-- ============================================================================
-- G12: the ledger entry point and the Writer
-- ============================================================================
SELECT ok(fao_private.append_event(pg_temp.rc('g11'), 'HITL_APPROVAL_RECORDED', jsonb_build_object('note', 'pgtap 161 owner append'),
            'REQUIRE_HUMAN'::public.policy_outcome, 'CRITICAL'::public.policy_sub_tier, 'pgtap 161 owner append', NULL,
            'PENDING'::public.hitl_status, NULL, 'SUCCESS'::public.execution_status, NULL) IS NOT NULL,
  'G12: append_event as the owner accepts HITL_APPROVAL_RECORDED');
INSERT INTO v VALUES ('g12run', to_jsonb(tests.make_run(pg_temp.e('B'), ARRAY['BTC'])));
SELECT matches(tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)',
                 jsonb_build_array(tests.asset_event((pg_temp.g('g12run')#>>'{}')::uuid, 'BTC') || '{"event_type": "HITL_APPROVAL_RECORDED"}'::jsonb))),
  'event_type must be STARTED, ASSET_RECONCILED or FAILED', 'G12: the Writer cannot append HITL_APPROVAL_RECORDED (existing error)');
SELECT is((SELECT count(*) FROM unnest(ARRAY['hitl_id', 'decision', 'approver_id', 'approvers', 'configured_approvals', 'enforced_approvals',
                                             'agent_invoker_id', 'sub_tier', 'decision_notes']) k
            WHERE tests.error_as('fao_workflow', format('SELECT public.fao_ledger_append_batch(%L::jsonb)',
                    jsonb_build_array(jsonb_set(tests.asset_event((pg_temp.g('g12run')#>>'{}')::uuid, 'BTC'), ARRAY['inputs', k], '"x"'::jsonb))))
                  LIKE '%inputs.' || k || ' is set only by the database%'),
  9::bigint, 'G12: the Writer still cannot set any of the nine HITL_APPROVAL_RECORDED inputs keys');

-- ============================================================================
-- G13: approver_qualifies truth table on one request invoked by A
-- ============================================================================
SELECT pg_temp.crit('g13');
SELECT ok(fao_private.approver_qualifies(pg_temp.id('g13'), NULL, true) IS FALSE AND fao_private.approver_qualifies(999999999999, pg_temp.u('B'), true) IS FALSE,
  'G13: NULL uid and a missing request give false');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, pg_temp.hour_ago());
SELECT pg_temp.revoke_all('L');
SELECT is(pg_temp.q('g13', 'L', false), false, 'G13: a revoked grant: false');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_close_orchestrator_v1', NULL, pg_temp.hour_ago());
SELECT is(pg_temp.q('g13', 'L', false), false, 'G13: a grant for another agent: false');
SELECT pg_temp.revoke_all('L');
SELECT pg_temp.grant_role('L', 'admin', NULL, NULL, pg_temp.hour_ago());
SELECT pg_temp.grant_role('L', 'reader', NULL, NULL, pg_temp.hour_ago());
SELECT is(pg_temp.q('g13', 'L', false), false, 'G13: an admin or reader grant only: false');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, (SELECT created_at FROM public.hitl_queue WHERE hitl_id = pg_temp.id('g13')));
SELECT is(pg_temp.q('g13', 'L', false), false, 'G13: granted_at equal to created_at: false');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), 'fao_reserve_recon_v1', NULL, (SELECT created_at FROM public.hitl_queue WHERE hitl_id = pg_temp.id('g13')) - interval '1 microsecond');
SELECT is(pg_temp.q('g13', 'L', false), true, 'G13: granted_at one microsecond before created_at: true');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), NULL, pg_temp.u('A'), pg_temp.hour_ago());
SELECT is(pg_temp.q('g13', 'L', false), false, 'G13: granted_by the invoker A: false');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), NULL, NULL, pg_temp.hour_ago());
SELECT is(pg_temp.q('g13', 'L', true), true, 'G13: granted_by NULL: true');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), NULL, pg_temp.u('B'), pg_temp.hour_ago());
SELECT is(pg_temp.q('g13', 'L', true), true, 'G13: granted_by B (not the invoker, no row of B): true');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), NULL, pg_temp.u('C'), pg_temp.hour_ago());
SELECT ok(pg_temp.q('g13', 'L', false) AND pg_temp.q('g13', 'L', true), 'G13: granted_by C with no row of C: true either way');
SELECT is(pg_temp.err('C', pg_temp.ins('g13', 'C')), NULL, 'G13 setup: C''s approval row');
SELECT ok(pg_temp.q('g13', 'L', false) AND NOT pg_temp.q('g13', 'L', true), 'G13: granted_by C with C''s row present: true without the co-approver rule, false with it');
SELECT is(pg_temp.q('g13', 'L', NULL), true, 'G13: p_co_approver_rule NULL behaves as false');
SELECT pg_temp.revoke_all('L');
SELECT tests.grant_approver(pg_temp.e('L'), NULL, pg_temp.u('L'), pg_temp.hour_ago());
SELECT is(pg_temp.err('L', pg_temp.ins('g13', 'L')), NULL, 'G13 setup: L''s own row (grant made by L itself)');
SELECT is(pg_temp.q('g13', 'L', true), true, 'G13: granted_by the user itself with the user''s own row present: true');
SELECT pg_temp.revoke_all('L');
SELECT is(tests.sqlstate_as(pg_temp.e('B'), format('SELECT fao_private.approver_qualifies(%s, %L::uuid, true)', pg_temp.id('g13'), pg_temp.u('B'))), '42501',
  'G13: a direct call as B is 42501');

SELECT * FROM finish();
ROLLBACK;
