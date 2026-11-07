-- ============================================================================
-- FinAgent OS pgTAP 146: fix round 5, HITL decide, read view, escalation
-- targets, seed control ids and the run summary view
-- Controls:
--   FAO-GOV-004 (K2): an APPROVED decision whose run's invoker is no longer
--     an active owner holding the invoker grant for the agent is never
--     committed: COMMIT_BLOCKED (inputs.code and inputs.reason
--     INVOKER_NOT_ACTIVE), run FAILED, envelope INVOKER_NOT_ACTIVE (409,
--     journaled) with the AGENT_NOT_ACTIVE decide key set; the agent check
--     comes first; REJECTED still commits.
--   FAO-GOV-004, FAO-GOV-007 (K3): fao_hitl_get carries top-level committed
--     and commit_blocked_reason on OK, ALREADY_DECIDED and EXPIRED, never
--     inside request, and not on NO_SESSION, INVALID_INPUT, NOT_AUTHORISED or
--     NOT_FOUND.
--   FAO-GOV-004, FAO-GOV-007 (U11): an inactive escalation_to or process
--     owner is never chosen as an escalation or notice target; the next
--     eligible owner is, or none (NO_ESCALATION_TARGET, the operator alert).
--   FAO-GOV-002 (F-28): seed 0003 sox_control_ids list the controls
--     SOX-MAPPING.md says each agent exercises.
--   FAO-GOV-015, FAO-GOV-008 (REG-B09): fao_run_summary reports the newest
--     COMMITTED row when a correlation id has two.
-- Flagship fao_reserve_recon_v1: owner Sarah, Sarah's escalation_to Marcus,
-- invokers Aisha and Sarah, approvers Aisha, Sarah and Marcus. Owners are
-- deactivated and reactivated with the audited direct owner edit (a change
-- reason), as 142 does. Clock offsets: 0 for K2 and K3, then 90000 and
-- 200000 for the deadline cases (requests last 24 hours).
-- ============================================================================
BEGIN;
SELECT plan(58);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j#>>'{}')::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.rc(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr(pg_temp.id(p_k)) $$;
CREATE FUNCTION pg_temp.keys(p_j jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_j) AS k $$;
CREATE FUNCTION pg_temp.summary(p_corr uuid) RETURNS text LANGUAGE sql AS $$
  SELECT tests.run_state(p_corr) || '/' || tests.ledger_count(p_corr, 'COMMITTED') || '/' || tests.ledger_count(p_corr, 'COMMIT_BLOCKED') $$;
CREATE FUNCTION pg_temp.blocked(p_corr uuid) RETURNS public.shadow_ledger LANGUAGE sql AS $$
  SELECT * FROM public.shadow_ledger WHERE correlation_id = p_corr AND inputs->>'event_type' = 'COMMIT_BLOCKED' ORDER BY ledger_id DESC LIMIT 1 $$;
CREATE FUNCTION pg_temp.k3(p_j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT (p_j->>'code') || '/' || coalesce(p_j->>'committed', '<none>') || '/' || coalesce(p_j->>'commit_blocked_reason', '<null>') $$;
CREATE FUNCTION pg_temp.active(p_email text, p_active boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 146 owner active ' || p_active::text, true);
  UPDATE public.process_owners SET active = p_active WHERE email = p_email;
END $$;
CREATE FUNCTION pg_temp.set_status(p_status text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 146 status ' || p_status, true);
  UPDATE public.agent_registry SET status = p_status::public.agent_status WHERE agent_id = 'fao_reserve_recon_v1';
END $$;
CREATE FUNCTION pg_temp.rec(p_id bigint, p_kind text, p_level int, p_outcome text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format($q$SELECT public.fao_notification_record(%s::bigint, %L, %s, %L, 'slack', %L, %L)$q$,
    p_id, p_kind, p_level, p_outcome, CASE WHEN p_outcome = 'SENT' THEN '1730900000.0146' END, CASE WHEN p_outcome = 'FAILED' THEN 'pgtap 146 failure' END)) $$;
CREATE FUNCTION pg_temp.ctx(p_id bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format('SELECT public.fao_notification_context(%s::bigint, %L, 1)', p_id, 'ESCALATED')) $$;
-- The level-1 HITL_ESCALATED target of a request (JSON null when NULL).
CREATE FUNCTION pg_temp.target(p_k text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT l.inputs->'target_owner_id' FROM public.shadow_ledger l
   WHERE l.correlation_id = pg_temp.rc(p_k) AND l.inputs->>'event_type' = 'HITL_ESCALATED' AND l.inputs->>'level' = '1'
   ORDER BY l.ledger_id DESC LIMIT 1 $$;
CREATE FUNCTION pg_temp.uidj(p_email text) RETURNS jsonb LANGUAGE sql AS $$ SELECT to_jsonb(tests.uid(p_email)::text) $$;
CREATE FUNCTION pg_temp.has_err(p_sweep text, p_step text, p_k text, p_sqlstate text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(pg_temp.g(p_sweep)->'item_errors', '[]'::jsonb)) e
                  WHERE e->>'step' = p_step AND e->>'id' = pg_temp.id(p_k)::text AND e->>'sqlstate' = p_sqlstate) $$;
CREATE FUNCTION pg_temp.listed(p_sweep text, p_k text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(pg_temp.g(p_sweep)->'escalations', '[]'::jsonb)) e
                  WHERE e->>'hitl_id' = pg_temp.id(p_k)::text) $$;
CREATE FUNCTION pg_temp.recipient(p_k text) RETURNS uuid LANGUAGE sql AS $$
  SELECT n.recipient_owner_id FROM public.fao_notifications n
   WHERE n.hitl_id = pg_temp.id(p_k) AND n.kind = 'ESCALATED' ORDER BY n.notification_id DESC LIMIT 1 $$;

SELECT tests.set_clock(0);

-- ============================================================================
-- K3: the read view of a pending request, and the refusals
-- ============================================================================
INSERT INTO v VALUES ('kA', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('get_pending', tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('kA')::text));
SELECT is(pg_temp.k3(pg_temp.g('get_pending')), 'OK/false/<null>',
  'K3: a pending request carries committed false and commit_blocked_reason null');
SELECT ok(pg_temp.g('get_pending') ? 'commit_blocked_reason' AND NOT pg_temp.g('get_pending')->'request' ? 'committed'
          AND NOT pg_temp.g('get_pending')->'request' ? 'commit_blocked_reason',
  'K3: both keys are top level, never inside request');
SELECT ok(NOT tests.get_raw('anon', pg_temp.id('kA')::text) ? 'committed', 'K3: NO_SESSION carries no committed key');
SELECT ok((SELECT j->>'code' = 'INVALID_INPUT' AND NOT j ? 'committed' FROM (SELECT tests.get_raw('sarah.chen@finagent-os.demo', 'abc') AS j) x),
  'K3: INVALID_INPUT carries no committed key');
SELECT ok((SELECT j->>'code' = 'NOT_FOUND' AND NOT j ? 'committed' FROM (SELECT tests.get_raw('sarah.chen@finagent-os.demo', '999999999999') AS j) x),
  'K3: NOT_FOUND carries no committed key');
SELECT ok((SELECT j->>'code' = 'NOT_AUTHORISED' AND NOT j ? 'committed' FROM (SELECT tests.get_raw('ratelimit@local.test', pg_temp.id('kA')::text) AS j) x),
  'K3: NOT_AUTHORISED carries no committed key');

-- A committed approval
INSERT INTO v VALUES ('dA', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('kA'), 'APPROVED'));
SELECT is(pg_temp.g('dA')->>'code' || '/' || (pg_temp.g('dA')->>'committed'), 'OK/true', 'K3 setup: an ordinary approval commits');
INSERT INTO v VALUES ('get_A', tests.get_raw('aisha.okonkwo@finagent-os.demo', pg_temp.id('kA')::text));
SELECT is(pg_temp.k3(pg_temp.g('get_A')) || '/' || (pg_temp.g('get_A')->>'http_status'), 'ALREADY_DECIDED/true/<null>/410',
  'K3: a committed decided request reads committed true, reason null');
SELECT is(pg_temp.keys(pg_temp.g('get_A')->'request'), ARRAY['decided_at', 'decision', 'hitl_id'],
  'K3: the decided request keys stay exactly decided_at, decision, hitl_id');
SELECT is(pg_temp.keys(pg_temp.g('get_A')), ARRAY['code', 'commit_blocked_reason', 'committed', 'http_status', 'message', 'ok', 'ref', 'request'],
  'K3: the ALREADY_DECIDED envelope keys');

-- ============================================================================
-- K2: the invoker deactivated after the request
-- ============================================================================
INSERT INTO v VALUES ('kB', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', false);
INSERT INTO v VALUES ('jB0', to_jsonb(tests.journal_count('INVOKER_NOT_ACTIVE')));
INSERT INTO v VALUES ('dB', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('kB'), 'APPROVED'));
SELECT is(pg_temp.g('dB')->>'code' || '/' || (pg_temp.g('dB')->>'http_status') || '/' || (pg_temp.g('dB')->>'ok') || '/' || (pg_temp.g('dB')->>'message'),
  'INVOKER_NOT_ACTIVE/409/false/The invoker is no longer authorised for this agent.',
  'K2: approving a deactivated invoker''s run is INVOKER_NOT_ACTIVE (409) with the fixed message');
SELECT is(pg_temp.keys(pg_temp.g('dB')),
  ARRAY['code', 'committed', 'committed_ledger_id', 'decided_at', 'decision', 'hitl_id', 'http_status', 'message', 'ok', 'ref'],
  'K2: the envelope has exactly the AGENT_NOT_ACTIVE decide key set');
SELECT ok(pg_temp.g('dB')->>'decision' = 'APPROVED' AND pg_temp.g('dB')->'committed' = 'false'::jsonb
          AND pg_temp.g('dB')->'committed_ledger_id' = 'null'::jsonb AND pg_temp.g('dB')->>'decided_at' IS NOT NULL
          AND (pg_temp.g('dB')->>'hitl_id')::bigint = pg_temp.id('kB'),
  'K2: the envelope carries the recorded decision, its time and committed false');
SELECT ok(pg_temp.g('dB')->>'ref' IS NOT NULL AND tests.journal_count('INVOKER_NOT_ACTIVE') = (pg_temp.g('jB0')#>>'{}')::bigint + 1,
  'K2: the refusal is journaled');
SELECT is(pg_temp.summary(pg_temp.rc('kB')), 'FAILED/0/1', 'K2: nothing is committed; the run is FAILED with one COMMIT_BLOCKED');
SELECT is((SELECT (b).inputs->>'code' || '/' || ((b).inputs->>'reason') || '/' || (b).status::text || '/' || (b).policy_outcome::text
             FROM (SELECT pg_temp.blocked(pg_temp.rc('kB')) AS b) x),
  'INVOKER_NOT_ACTIVE/INVOKER_NOT_ACTIVE/FAILURE/BLOCKED', 'K2: COMMIT_BLOCKED carries inputs.code and inputs.reason INVOKER_NOT_ACTIVE');
SELECT ok((SELECT decision = 'APPROVED' FROM public.hitl_queue WHERE hitl_id = pg_temp.id('kB'))
          AND tests.ledger_count(pg_temp.rc('kB'), 'HITL_RESOLVED') = 1,
  'K2: the decision and HITL_RESOLVED stand');
INSERT INTO v VALUES ('get_B', tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('kB')::text));
SELECT is(pg_temp.k3(pg_temp.g('get_B')), 'ALREADY_DECIDED/false/INVOKER_NOT_ACTIVE',
  'K3: reloading it reads committed false and reason INVOKER_NOT_ACTIVE');
SELECT is(pg_temp.keys(pg_temp.g('get_B')->'request'), ARRAY['decided_at', 'decision', 'hitl_id'],
  'K3: the blocked request keys stay the short form');

-- REJECTED still commits (ROLLED_BACK) with the invoker deactivated
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', true);
INSERT INTO v VALUES ('kR', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', false);
INSERT INTO v VALUES ('dR', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('kR'), 'REJECTED'));
SELECT is(pg_temp.g('dR')->>'code' || '/' || (pg_temp.g('dR')->>'committed') || '/' || pg_temp.summary(pg_temp.rc('kR')), 'OK/true/COMMITTED/1/0',
  'K2: a rejection of a deactivated invoker''s run still commits');
SELECT is(pg_temp.k3(tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('kR')::text)), 'ALREADY_DECIDED/true/<null>',
  'K3: a committed rejection reads committed true, reason null');

-- Agent not ACTIVE and the invoker deactivated: AGENT_NOT_ACTIVE first
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', true);
INSERT INTO v VALUES ('kC', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', false);
SELECT pg_temp.set_status('DEPRECATED');
INSERT INTO v VALUES ('dC', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('kC'), 'APPROVED'));
SELECT is(pg_temp.g('dC')->>'code' || '/' || pg_temp.summary(pg_temp.rc('kC')), 'AGENT_NOT_ACTIVE/FAILED/0/1',
  'K2: with both gates failing, AGENT_NOT_ACTIVE is checked first');
SELECT is((SELECT (b).inputs->>'code' FROM (SELECT pg_temp.blocked(pg_temp.rc('kC')) AS b) x), 'AGENT_NOT_ACTIVE',
  'K2: the COMMIT_BLOCKED row names AGENT_NOT_ACTIVE');
SELECT is(pg_temp.k3(tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('kC')::text)), 'ALREADY_DECIDED/false/AGENT_NOT_ACTIVE',
  'K3: reloading it reads committed false and reason AGENT_NOT_ACTIVE');
SELECT pg_temp.set_status('ACTIVE');
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', true);

-- Audit chain block: committed false, reason null (not a named gate)
INSERT INTO v VALUES ('kD', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, inputs, policy_outcome, policy_rationale, status)
SELECT r.correlation_id, r.execution_id, r.agent_id, r.risk_tier, jsonb_build_object('event_type', 'ASSET_RECONCILED', 'asset', 'USDC', 'ratio', 1.0),
       'ALLOW', 'pgtap 146 stray row (owner-side tampered chain, as 144)', 'SUCCESS'
  FROM public.run_invocations r WHERE r.correlation_id = pg_temp.rc('kD');
INSERT INTO v VALUES ('dD', tests.decide('sarah.chen@finagent-os.demo', pg_temp.id('kD'), 'APPROVED'));
SELECT is(pg_temp.g('dD')->>'code' || '/' || pg_temp.summary(pg_temp.rc('kD')), 'AUDIT_CHAIN_MISMATCH/FAILED/0/1',
  'K3 setup: a broken chain blocks the commit');
SELECT is(pg_temp.k3(tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('kD')::text)), 'ALREADY_DECIDED/false/<null>',
  'K3: an audit chain block reads committed false, reason null');

-- K2: the invoker grant revoked after the request (Sarah invokes, Marcus decides)
INSERT INTO v VALUES ('kE', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 146 revoke invoker', true);
  UPDATE public.fao_user_roles SET revoked_at = now()
   WHERE user_id = tests.uid('sarah.chen@finagent-os.demo') AND role = 'invoker' AND revoked_at IS NULL;
END $$;
INSERT INTO v VALUES ('dE', tests.decide('marcus.patel@finagent-os.demo', pg_temp.id('kE'), 'APPROVED'));
SELECT is(pg_temp.g('dE')->>'code' || '/' || pg_temp.summary(pg_temp.rc('kE')), 'INVOKER_NOT_ACTIVE/FAILED/0/1',
  'K2: approving the run of an invoker whose grant was revoked is INVOKER_NOT_ACTIVE');
SELECT is(pg_temp.k3(tests.get_raw('marcus.patel@finagent-os.demo', pg_temp.id('kE')::text)), 'ALREADY_DECIDED/false/INVOKER_NOT_ACTIVE',
  'K3: reloading it reads reason INVOKER_NOT_ACTIVE');
-- An agent-scoped invoker grant for another agent does not count
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 146 grant other agent', true);
  INSERT INTO public.fao_user_roles (user_id, role, agent_id, granted_by, reason)
  VALUES (tests.uid('sarah.chen@finagent-os.demo'), 'invoker', 'fao_close_orchestrator_v1', NULL, 'pgtap 146 grant other agent');
END $$;
SELECT is(fao_private.has_role(tests.uid('sarah.chen@finagent-os.demo'), 'invoker', 'fao_reserve_recon_v1'), false,
  'K2 setup: a grant for another agent is not an invoker grant for the flagship');
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 146 regrant invoker', true);
  INSERT INTO public.fao_user_roles (user_id, role, agent_id, granted_by, reason)
  VALUES (tests.uid('sarah.chen@finagent-os.demo'), 'invoker', NULL, NULL, 'pgtap 146 regrant invoker');
END $$;

-- The gate reads the invoker rows FOR SHARE before the agent row
SELECT matches(pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure),
  'FROM public\.process_owners po WHERE po\.id = v_run\.invoker_id FOR SHARE;.*FROM public\.fao_user_roles ur.*FOR SHARE;.*FROM public\.agent_registry ar\s+WHERE ar\.agent_id = v_run\.agent_id\s+FOR SHARE;\s+r := fao_private\.run_rollup',
  'K2: decide locks the invoker owner and grant rows FOR SHARE after the run lock, before the agent row and the rollup');
SELECT ok(position('INVOKER_NOT_ACTIVE' IN substring(pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure) FROM 'r := fao_private.run_rollup(.*)$'))
          > position('AGENT_NOT_ACTIVE' IN substring(pg_get_functiondef('public.fao_hitl_decide(json)'::regprocedure) FROM 'r := fao_private.run_rollup(.*)$')),
  'K2: the agent gate comes before the invoker gate');

-- ============================================================================
-- U11 notice targets: a target deactivated after the escalation
-- ============================================================================
-- Three FAILED REQUESTED notices: the next sweep escalates (NOTIFICATION_FAILED)
-- to Sarah's escalation_to, Marcus, who is active.
INSERT INTO v VALUES ('uN', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.rec(pg_temp.id('uN'), 'REQUESTED', 0, 'FAILED');
SELECT pg_temp.rec(pg_temp.id('uN'), 'REQUESTED', 0, 'FAILED');
SELECT pg_temp.rec(pg_temp.id('uN'), 'REQUESTED', 0, 'FAILED');
INSERT INTO v VALUES ('sN1', tests.sweep());
SELECT is(pg_temp.target('uN'), pg_temp.uidj('marcus.patel@finagent-os.demo'), 'U11 setup: escalated to the active escalation_to (Marcus)');
SELECT pg_temp.active('marcus.patel@finagent-os.demo', false);
INSERT INTO v VALUES ('cN1', pg_temp.ctx(pg_temp.id('uN')));
SELECT is(pg_temp.g('cN1')->>'send' || '/' || (pg_temp.g('cN1')->>'target_name'), 'true/Sarah Chen',
  'U11: a recorded target deactivated since the escalation is not named; the next eligible owner (the process owner) is');
SELECT is(pg_temp.rec(pg_temp.id('uN'), 'ESCALATED', 1, 'FAILED')->>'ok', 'true', 'U11 setup: an ESCALATED attempt is recorded');
SELECT is(pg_temp.recipient('uN'), tests.uid('sarah.chen@finagent-os.demo'), 'U11: the recorded recipient is the owner the notice named');
INSERT INTO v VALUES ('sN2', tests.sweep());
SELECT ok(pg_temp.listed('sN2', 'uN') AND NOT pg_temp.has_err('sN2', 'escalation_notice', 'uN', 'NO_ESCALATION_TARGET'),
  'U11: relisted with an eligible replacement, no operator alert');
SELECT pg_temp.active('sarah.chen@finagent-os.demo', false);
INSERT INTO v VALUES ('cN2', pg_temp.ctx(pg_temp.id('uN')));
SELECT ok(pg_temp.g('cN2')->>'send' = 'true' AND pg_temp.g('cN2')->'target_name' = 'null'::jsonb,
  'U11: with the process owner inactive too, the notice names no one');
SELECT ok(position('Marcus' IN pg_temp.g('cN2')::text) = 0 AND position('Sarah' IN pg_temp.g('cN2')::text) = 0,
  'U11: no inactive owner is named, as target or approver candidate');
SELECT pg_temp.rec(pg_temp.id('uN'), 'ESCALATED', 1, 'FAILED');
SELECT is(pg_temp.recipient('uN'), NULL::uuid, 'U11: no inactive owner is recorded as the recipient');
INSERT INTO v VALUES ('sN3', tests.sweep());
SELECT ok(pg_temp.listed('sN3', 'uN') AND pg_temp.has_err('sN3', 'escalation_notice', 'uN', 'NO_ESCALATION_TARGET'),
  'U11: the relisted escalation with no eligible target is reported as NO_ESCALATION_TARGET (operator alerted)');
SELECT pg_temp.active('sarah.chen@finagent-os.demo', true);
SELECT pg_temp.active('marcus.patel@finagent-os.demo', true);
-- The decided request is no longer relisted (it closes the case).
SELECT is(tests.decide('marcus.patel@finagent-os.demo', pg_temp.id('uN'), 'REJECTED')->>'code', 'OK', 'U11 setup: the request is decided');

-- ============================================================================
-- U11 escalation targets: TIMEOUT escalations at the deadline
-- ============================================================================
-- Each request gets a SENT REQUESTED notice so only the deadline escalates it.
INSERT INTO v VALUES ('uA', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.rec(pg_temp.id('uA'), 'REQUESTED', 0, 'SENT');
SELECT pg_temp.active('marcus.patel@finagent-os.demo', false);
SELECT tests.set_clock(90000);
INSERT INTO v VALUES ('sA', tests.sweep());
SELECT is(pg_temp.target('uA'), pg_temp.uidj('sarah.chen@finagent-os.demo'),
  'U11: an inactive escalation_to is skipped; the escalation goes to the active process owner');
SELECT ok(NOT pg_temp.has_err('sA', 'expire_request', 'uA', 'NO_ESCALATION_TARGET'), 'U11: an eligible fallback raises no alert');
SELECT is(pg_temp.ctx(pg_temp.id('uA'))->>'target_name', 'Sarah Chen', 'U11: the notice names the fallback');

-- Escalation_to and process owner both inactive: none eligible
INSERT INTO v VALUES ('uB', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.rec(pg_temp.id('uB'), 'REQUESTED', 0, 'SENT');
SELECT pg_temp.active('sarah.chen@finagent-os.demo', false);
SELECT tests.set_clock(200000);
INSERT INTO v VALUES ('sB', tests.sweep());
SELECT ok(pg_temp.target('uB') = 'null'::jsonb, 'U11: with escalation_to and the process owner inactive the target is NULL');
SELECT ok(pg_temp.has_err('sB', 'expire_request', 'uB', 'NO_ESCALATION_TARGET') AND pg_temp.listed('sB', 'uB'),
  'U11: reported as NO_ESCALATION_TARGET (operator alerted) and still listed for the channel notice');
SELECT ok(pg_temp.ctx(pg_temp.id('uB'))->'target_name' = 'null'::jsonb, 'U11: the notice names no one');
SELECT pg_temp.active('sarah.chen@finagent-os.demo', true);

-- The process owner is the invoker and escalation_to is inactive: none
INSERT INTO v VALUES ('uC', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
SELECT pg_temp.rec(pg_temp.id('uC'), 'REQUESTED', 0, 'SENT');
SELECT tests.set_clock(300000);
INSERT INTO v VALUES ('sC', tests.sweep());
SELECT ok(pg_temp.target('uC') = 'null'::jsonb AND pg_temp.has_err('sC', 'expire_request', 'uC', 'NO_ESCALATION_TARGET'),
  'U11: an inactive escalation_to never falls back to the invoker; none eligible, reported');
SELECT pg_temp.active('marcus.patel@finagent-os.demo', true);

-- NOTIFICATION_FAILED escalation (renotify step) with escalation_to inactive
SELECT tests.set_clock(400000);
INSERT INTO v VALUES ('uF', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
SELECT pg_temp.rec(pg_temp.id('uF'), 'REQUESTED', 0, 'FAILED');
SELECT pg_temp.rec(pg_temp.id('uF'), 'REQUESTED', 0, 'FAILED');
SELECT pg_temp.rec(pg_temp.id('uF'), 'REQUESTED', 0, 'FAILED');
SELECT pg_temp.active('marcus.patel@finagent-os.demo', false);
INSERT INTO v VALUES ('sF', tests.sweep());
SELECT ok(pg_temp.target('uF') = pg_temp.uidj('sarah.chen@finagent-os.demo') AND NOT pg_temp.has_err('sF', 'renotify', 'uF', 'NO_ESCALATION_TARGET'),
  'U11: the renotify escalation skips an inactive escalation_to too');
SELECT pg_temp.active('marcus.patel@finagent-os.demo', true);

-- K3: an expired request reads committed false, reason null
SELECT is(pg_temp.k3(tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('uA')::text)), 'EXPIRED/false/<null>',
  'K3: an EXPIRED request carries committed false and reason null');
SELECT is(pg_temp.keys(tests.get_raw('sarah.chen@finagent-os.demo', pg_temp.id('uA')::text)->'request'), ARRAY['decided_at', 'decision', 'hitl_id'],
  'K3: the expired request keys stay the short form');

-- The helpers are private
SELECT is((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
           WHERE n.nspname = 'fao_private' AND p.proname IN ('escalation_target', 'notice_target')
             AND a.grantee <> p.proowner),
  0::bigint, 'U11: escalation_target and notice_target are executable by no client role');

-- ============================================================================
-- F-28: seed 0003 sox_control_ids per agent (SOX-MAPPING.md)
-- ============================================================================
SELECT is((SELECT array_agg(c ORDER BY c) FROM public.agent_registry ar, unnest(ar.sox_control_ids) c WHERE ar.agent_id = 'fao_reserve_recon_v1'),
  ARRAY['FAO-GOV-001', 'FAO-GOV-002', 'FAO-GOV-003', 'FAO-GOV-004', 'FAO-GOV-008', 'FAO-GOV-009', 'FAO-GOV-013', 'FAO-GOV-014', 'FAO-GOV-015',
        'FAO-REC-001', 'FAO-REC-002', 'FAO-REC-003', 'FAO-REC-004', 'FAO-REC-006', 'FAO-REC-007', 'FAO-REC-008'],
  'F-28: the flagship lists every live or partial control it exercises (REC-003, REC-004, REC-008, GOV-008, GOV-009, GOV-015 included)');
SELECT is((SELECT count(*) FROM public.agent_registry ar
            WHERE ar.agent_id IN ('fao_close_orchestrator_v1', 'fao_variance_analyzer_v1', 'fao_treasury_monitor_v1')
              AND (SELECT array_agg(c ORDER BY c) FROM unnest(ar.sox_control_ids) c)
                  = ARRAY['FAO-GOV-001', 'FAO-GOV-002', 'FAO-GOV-003', 'FAO-GOV-004', 'FAO-GOV-013', 'FAO-GOV-014']),
  3::bigint, 'F-28: each stub lists only the inherited platform controls');
SELECT is((SELECT count(*) FROM public.agent_registry ar, unnest(ar.sox_control_ids) c
            WHERE c IN ('FAO-GOV-005', 'FAO-GOV-010', 'FAO-GOV-011', 'FAO-GOV-012', 'FAO-REC-005', 'FAO-REC-009')),
  0::bigint, 'F-28: no agent lists a planned (v1.1) control');

-- ============================================================================
-- REG-B09: two COMMITTED rows for one correlation id, newest wins
-- ============================================================================
-- Honest path: the first COMMITTED row comes from a real approval (kA above:
-- REQUIRE_HUMAN, SUCCESS). The second is written by the database's own
-- insert point, fao_private.append_event, called as the owner inside this
-- transaction, standing in for a second commit path; no trigger, constraint
-- or policy is disabled. It differs in outcome and status so the view's
-- choice is visible.
SELECT is((SELECT latest_committed_outcome || '/' || latest_committed_status || '/' || committed_count
             FROM public.fao_run_summary WHERE correlation_id = pg_temp.rc('kA')),
  'REQUIRE_HUMAN/SUCCESS/1', 'REG-B09 setup: one COMMITTED row from the approval');
INSERT INTO v VALUES ('b09', to_jsonb(fao_private.append_event(
  pg_temp.rc('kA'), 'COMMITTED', jsonb_build_object('note', 'pgtap 146 second COMMITTED'),
  'BLOCKED'::public.policy_outcome, NULL, 'pgtap 146 second COMMITTED row', NULL,
  'APPROVED'::public.hitl_status, NULL, 'FAILURE'::public.execution_status, NULL)));
SELECT ok((pg_temp.g('b09')#>>'{}')::bigint > (SELECT min(ledger_id) FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc('kA') AND inputs->>'event_type' = 'COMMITTED'),
  'REG-B09 setup: the second COMMITTED row is the newer one');
SELECT is((SELECT latest_committed_outcome || '/' || latest_committed_status || '/' || committed_count
             FROM public.fao_run_summary WHERE correlation_id = pg_temp.rc('kA')),
  'BLOCKED/FAILURE/2', 'REG-B09: the view reports the newest COMMITTED row and counts both');

SELECT * FROM finish();
ROLLBACK;
