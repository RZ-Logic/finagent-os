-- ============================================================================
-- FinAgent OS pgTAP 030: immutability of requests, runs, tokens and roles
-- Controls: FAO-GOV-004 (decisions only through fao_hitl_decide; decided
-- rows immutable; frozen fields), FAO-GOV-001 (history kept when people
-- leave), FAO-GOV-008 (run and token state machines).
-- ============================================================================
BEGIN;
SELECT plan(61);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
INSERT INTO v VALUES ('pending', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('decided', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('approve', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'decided'), 'APPROVED'));

CREATE TEMP TABLE probes (k text PRIMARY KEY, sql text);
INSERT INTO probes VALUES
  ('insert', format($$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale) VALUES (gen_random_uuid(), 'fao_reserve_recon_v1', %L, 'RED', 'x')$$,
                    tests.uid('aisha.okonkwo@finagent-os.demo'))),
  ('update', format($$UPDATE public.hitl_queue SET decision_notes = 'x' WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'pending'))),
  ('delete', format($$DELETE FROM public.hitl_queue WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'pending')));

SELECT is((SELECT j->>'ok' FROM v WHERE k = 'approve'), 'true', 'setup: one request decided');

-- 18 direct-write probes
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'sarah.chen@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'insert')), '42501', NULL, 'Sarah: direct INSERT on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'sarah.chen@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'update')), '42501', NULL, 'Sarah: direct UPDATE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'sarah.chen@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'delete')), '42501', NULL, 'Sarah: direct DELETE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'marcus.patel@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'insert')), '42501', NULL, 'Marcus: direct INSERT on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'marcus.patel@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'update')), '42501', NULL, 'Marcus: direct UPDATE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'marcus.patel@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'delete')), '42501', NULL, 'Marcus: direct DELETE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'aisha.okonkwo@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'insert')), '42501', NULL, 'Aisha: direct INSERT on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'aisha.okonkwo@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'update')), '42501', NULL, 'Aisha: direct UPDATE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'aisha.okonkwo@finagent-os.demo', (SELECT sql FROM probes WHERE k = 'delete')), '42501', NULL, 'Aisha: direct DELETE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'outsider@local.test', (SELECT sql FROM probes WHERE k = 'insert')), '42501', NULL, 'Outsider: direct INSERT on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'outsider@local.test', (SELECT sql FROM probes WHERE k = 'update')), '42501', NULL, 'Outsider: direct UPDATE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'outsider@local.test', (SELECT sql FROM probes WHERE k = 'delete')), '42501', NULL, 'Outsider: direct DELETE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'fao_workflow', (SELECT sql FROM probes WHERE k = 'insert')), '42501', NULL, 'fao_workflow: direct INSERT on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'fao_workflow', (SELECT sql FROM probes WHERE k = 'update')), '42501', NULL, 'fao_workflow: direct UPDATE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'fao_workflow', (SELECT sql FROM probes WHERE k = 'delete')), '42501', NULL, 'fao_workflow: direct DELETE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'service_role', (SELECT sql FROM probes WHERE k = 'insert')), '42501', NULL, 'service_role: direct INSERT on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'service_role', (SELECT sql FROM probes WHERE k = 'update')), '42501', NULL, 'service_role: direct UPDATE on hitl_queue is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'service_role', (SELECT sql FROM probes WHERE k = 'delete')), '42501', NULL, 'service_role: direct DELETE on hitl_queue is refused');

-- A pre-decided insert is refused by every route, the owner included
SELECT throws_ok(format($$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale, decision, approver_id, decided_at, timeout_at)
                          VALUES (gen_random_uuid(), 'fao_reserve_recon_v1', %L, 'RED', 'x', 'APPROVED', %L, now(), now() + interval '1 day')$$,
                        tests.uid('aisha.okonkwo@finagent-os.demo'), tests.uid('sarah.chen@finagent-os.demo')),
  '42501', NULL, 'owner: a pre-decided insert is refused');
SELECT throws_ok(format('SELECT tests.do_as(%L, %L)', 'marcus.patel@finagent-os.demo',
                        format($$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale, decision, approver_id, decided_at) VALUES (gen_random_uuid(), 'fao_reserve_recon_v1', %L, 'RED', 'x', 'APPROVED', %L, now())$$,
                               tests.uid('aisha.okonkwo@finagent-os.demo'), tests.uid('marcus.patel@finagent-os.demo'))),
  '42501', NULL, 'admin: a pre-decided insert is refused');

-- After a decision every column change is refused, the owner included
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision_notes = 'changed' WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'decided')), '42501', NULL, 'owner: decided row decision_notes is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET policy_rationale = 'changed' WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'decided')), '42501', NULL, 'owner: decided row policy_rationale is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET approval_url = 'http://x.invalid/' WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'decided')), '42501', NULL, 'owner: decided row approval_url is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'PENDING', approver_id = NULL, decided_at = NULL WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'decided')), '42501', NULL, 'owner: a decided row cannot go back to PENDING');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'REJECTED' WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'decided')), '42501', NULL, 'owner: a decided row cannot change its decision');
SELECT throws_ok(format($$DELETE FROM public.hitl_queue WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'decided')), '42501', NULL, 'owner: a decided row cannot be deleted');

-- Frozen fields on a pending row: an otherwise valid decision by an approver
-- session is refused when it also changes a frozen field.
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', tests.uid('sarah.chen@finagent-os.demo'), 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', tests.uid('sarah.chen@finagent-os.demo')::text, true);
END $$;
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), configured_approvals = configured_approvals + 1 WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: configured_approvals is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), enforced_approvals = enforced_approvals + 1 WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: enforced_approvals is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), timeout_at = timeout_at + interval '1 day' WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: timeout_at is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), agent_invoker_id = %L WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), tests.uid('marcus.patel@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: agent_invoker_id is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), risk_tier = 'AMBER' WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: risk_tier is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), policy_rationale = 'changed' WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: policy_rationale is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), escalated_assets = '[{"asset":"X"}]'::jsonb WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: escalated_assets is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), approval_url = 'http://x.invalid/' WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: approval_url is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now(), correlation_id = gen_random_uuid() WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), '42501', NULL, 'pending row: correlation_id is frozen');
SELECT throws_ok(format($$UPDATE public.hitl_queue SET decision_notes = 'only notes' WHERE hitl_id = %s$$, (SELECT j::text FROM v WHERE k = 'pending')),
  '42501', NULL, 'pending row: PENDING to PENDING is refused');
SELECT lives_ok(format($$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = %L, decided_at = now() WHERE hitl_id = %s$$,
  tests.uid('sarah.chen@finagent-os.demo'), (SELECT j::text FROM v WHERE k = 'pending')), 'control: the same decision without a frozen-field change passes the guard');
SELECT tests.as_owner();

-- History is kept when an owner leaves
DO $$ BEGIN PERFORM set_config('fao.change_reason', 'pgtap 030 delete probe', true); END $$;
SELECT throws_ok($$DELETE FROM public.process_owners WHERE email = 'aisha.okonkwo@finagent-os.demo'$$, '23503', NULL, 'a referenced process owner cannot be deleted');
SELECT throws_ok(format($$DELETE FROM auth.users WHERE id = %L$$, tests.uid('aisha.okonkwo@finagent-os.demo')), NULL, NULL, 'the auth user of a referenced owner cannot be deleted');

INSERT INTO v VALUES ('hitl_before', to_jsonb((SELECT count(*) FROM public.hitl_queue WHERE agent_invoker_id = tests.uid('aisha.okonkwo@finagent-os.demo') OR approver_id = tests.uid('aisha.okonkwo@finagent-os.demo'))));
INSERT INTO v VALUES ('ledger_before', to_jsonb((SELECT count(*) FROM public.shadow_ledger WHERE inputs->>'invoker_id' = tests.uid('aisha.okonkwo@finagent-os.demo')::text OR inputs->>'agent_invoker_id' = tests.uid('aisha.okonkwo@finagent-os.demo')::text)));
INSERT INTO v VALUES ('deactivate', tests.jsonb_as('marcus.patel@finagent-os.demo',
  format($$SELECT public.fao_admin_set_owner_active(%L, 'false', 'pgtap 030 leaver')$$, tests.uid('aisha.okonkwo@finagent-os.demo'))));
SELECT is((SELECT j->>'ok' FROM v WHERE k = 'deactivate'), 'true', 'Marcus deactivates Aisha');
SELECT is((SELECT active FROM public.process_owners WHERE email = 'aisha.okonkwo@finagent-os.demo'), false, 'Aisha is inactive');
SELECT is((SELECT count(*) FROM public.hitl_queue WHERE agent_invoker_id = tests.uid('aisha.okonkwo@finagent-os.demo') OR approver_id = tests.uid('aisha.okonkwo@finagent-os.demo')),
  (SELECT (j::text)::bigint FROM v WHERE k = 'hitl_before'), 'every request naming Aisha is kept');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE inputs->>'invoker_id' = tests.uid('aisha.okonkwo@finagent-os.demo')::text OR inputs->>'agent_invoker_id' = tests.uid('aisha.okonkwo@finagent-os.demo')::text),
  (SELECT (j::text)::bigint FROM v WHERE k = 'ledger_before'), 'every ledger row naming Aisha is kept');

-- run_invocations guard
INSERT INTO v VALUES ('run', to_jsonb(tests.make_run('sarah.chen@finagent-os.demo', ARRAY['BTC'])));
INSERT INTO v VALUES ('done', to_jsonb(tests.make_run('sarah.chen@finagent-os.demo', ARRAY['ETH'])));
INSERT INTO v VALUES ('done_append', tests.append(jsonb_build_array(tests.asset_event((SELECT (j#>>'{}')::uuid FROM v WHERE k = 'done'), 'ETH', 'ALLOW'))));
INSERT INTO v VALUES ('done_final', tests.finalize((SELECT (j#>>'{}')::uuid FROM v WHERE k = 'done')));
SELECT is(tests.run_state((SELECT (j#>>'{}')::uuid FROM v WHERE k = 'done')), 'COMMITTED', 'setup: a committed run');
SELECT throws_ok(format($$UPDATE public.run_invocations SET state = 'REQUESTED' WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'run: RUNNING cannot move back to REQUESTED');
SELECT throws_ok(format($$UPDATE public.run_invocations SET state = 'FAILED' WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'done')), '42501', NULL, 'run: a terminal state never changes');
SELECT throws_ok(format($$UPDATE public.run_invocations SET agent_id = 'fao_close_orchestrator_v1' WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'run: agent_id is frozen');
SELECT throws_ok(format($$UPDATE public.run_invocations SET invoker_id = %L WHERE correlation_id = %L$$, tests.uid('marcus.patel@finagent-os.demo'), (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'run: invoker_id is frozen');
SELECT throws_ok(format($$UPDATE public.run_invocations SET reason = 'changed' WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'run: reason is frozen');
SELECT throws_ok(format($$UPDATE public.run_invocations SET asset_scope = ARRAY['ETH'] WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'run: asset_scope changes only from NULL');
SELECT throws_ok(format($$DELETE FROM public.run_invocations WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'run: DELETE is refused');

-- run_tokens guard
SELECT throws_ok(format($$DELETE FROM fao_private.run_tokens WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'token: DELETE is refused');
SELECT throws_ok(format($$UPDATE fao_private.run_tokens SET consumed_at = now() + interval '1 minute' WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'token: consumed_at changes only from NULL');
SELECT throws_ok(format($$UPDATE fao_private.run_tokens SET token_hash = '\x00'::bytea WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'token: token_hash is frozen once consumed');
SELECT throws_ok(format($$UPDATE fao_private.run_tokens SET correlation_id = %L WHERE correlation_id = %L$$, (SELECT j#>>'{}' FROM v WHERE k = 'done'), (SELECT j#>>'{}' FROM v WHERE k = 'run')), '42501', NULL, 'token: correlation_id is frozen');

-- fao_user_roles guard (reason set so only the row guard decides)
DO $$ BEGIN PERFORM set_config('fao.change_reason', 'pgtap 030 roles guard', true); END $$;
SELECT throws_ok($$DELETE FROM public.fao_user_roles WHERE user_id = tests.uid('sarah.chen@finagent-os.demo')$$, '42501', NULL, 'roles: DELETE is refused');
SELECT throws_ok($$UPDATE public.fao_user_roles SET role = 'admin' WHERE user_id = tests.uid('sarah.chen@finagent-os.demo') AND role = 'invoker'$$, '42501', NULL, 'roles: role is frozen');
SELECT throws_ok($$UPDATE public.fao_user_roles SET reason = 'changed' WHERE user_id = tests.uid('sarah.chen@finagent-os.demo') AND role = 'invoker'$$, '42501', NULL, 'roles: reason is frozen');
SELECT lives_ok($$UPDATE public.fao_user_roles SET revoked_at = now() WHERE user_id = tests.uid('sarah.chen@finagent-os.demo') AND role = 'invoker' AND revoked_at IS NULL$$, 'roles: revoked_at may be set once');
SELECT throws_ok($$UPDATE public.fao_user_roles SET revoked_at = now() + interval '1 hour' WHERE user_id = tests.uid('sarah.chen@finagent-os.demo') AND role = 'invoker'$$, '42501', NULL, 'roles: revoked_at changes only from NULL');

SELECT * FROM finish();
ROLLBACK;
