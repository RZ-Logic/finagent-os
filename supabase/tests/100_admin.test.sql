-- ============================================================================
-- FinAgent OS pgTAP 100: admin RPCs, change reasons and the admin audit
-- Controls: FAO-GOV-002 (registry and settings changes need a reason and are
-- audited), FAO-GOV-004 (role changes, no self change), FAO-REC-002
-- (threshold changes), FAO-GOV-001 (audit and journal are append-only).
-- ============================================================================
BEGIN;
SELECT plan(82);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.marcus(p_sql text) RETURNS jsonb LANGUAGE sql AS $$ SELECT tests.jsonb_as('marcus.patel@finagent-os.demo', p_sql) $$;
CREATE FUNCTION pg_temp.audit(p_table text, p_reason_like text) RETURNS SETOF public.fao_admin_audit LANGUAGE sql AS $$
  SELECT * FROM public.fao_admin_audit WHERE table_name = p_table AND reason LIKE p_reason_like ORDER BY audit_id $$;

INSERT INTO v VALUES ('btc_before', (SELECT to_jsonb(t) FROM public.materiality_thresholds t WHERE asset_symbol = 'BTC' AND scope = 'Spot'));

-- fao_admin_set_threshold
INSERT INTO v VALUES ('thr', pg_temp.marcus($$SELECT public.fao_admin_set_threshold('BTC', 'Spot', 'Major', '600000', '1', '1.05', '1.3', 'pgtap note', 'pgtap admin threshold')$$));
SELECT is(pg_temp.g('thr')->>'ok', 'true', 'threshold: Marcus updates a threshold');
SELECT ok(pg_temp.g('thr')->'before' <> 'null'::jsonb AND (pg_temp.g('thr')->'after'->>'materiality_usd')::numeric = 600000, 'threshold: before and after returned');
SELECT is((SELECT count(*) FROM pg_temp.audit('public.materiality_thresholds', '%pgtap admin threshold%')), 1::bigint, 'threshold: one audit row');
SELECT is((SELECT actor_uid FROM pg_temp.audit('public.materiality_thresholds', '%pgtap admin threshold%')), tests.uid('marcus.patel@finagent-os.demo'), 'threshold: audit actor is Marcus');
SELECT ok((SELECT old_row IS NOT NULL AND new_row IS NOT NULL AND op = 'UPDATE' FROM pg_temp.audit('public.materiality_thresholds', '%pgtap admin threshold%')), 'threshold: audit holds before and after');
SELECT is((SELECT last_reviewed_by FROM public.materiality_thresholds WHERE asset_symbol = 'BTC' AND scope = 'Spot'), tests.uid('marcus.patel@finagent-os.demo'), 'threshold: last_reviewed_by is the admin');
SELECT ok((SELECT updated_at FROM public.materiality_thresholds WHERE asset_symbol = 'BTC' AND scope = 'Spot') = now()
          AND (pg_temp.g('btc_before')->>'updated_at')::timestamptz < now(), 'threshold: updated_at moves without being supplied');

-- fao_admin_set_agent
INSERT INTO v VALUES ('agent', pg_temp.marcus($$SELECT public.fao_admin_set_agent('fao_reserve_recon_v1', NULL, NULL, '7', 'pgtap admin agent')$$));
SELECT is(pg_temp.g('agent')->>'ok', 'true', 'agent: Marcus changes the rate limit');
SELECT is((SELECT max_runs_per_hour FROM public.agent_registry WHERE agent_id = 'fao_reserve_recon_v1'), 7, 'agent: max_runs_per_hour is 7');
SELECT is((SELECT status::text FROM public.agent_registry WHERE agent_id = 'fao_reserve_recon_v1'), 'ACTIVE', 'agent: a NULL argument leaves the column unchanged');
SELECT is((SELECT count(*) FROM pg_temp.audit('public.agent_registry', '%pgtap admin agent%')), 1::bigint, 'agent: one audit row');
SELECT is((SELECT actor_uid FROM pg_temp.audit('public.agent_registry', '%pgtap admin agent%')), tests.uid('marcus.patel@finagent-os.demo'), 'agent: audit actor is Marcus');
SELECT is(pg_temp.marcus($$SELECT public.fao_admin_set_agent('fao_no_such_agent', NULL, NULL, '7', 'pgtap')$$)->>'code', 'NOT_FOUND', 'agent: a missing agent is NOT_FOUND');

-- fao_admin_set_role
INSERT INTO v VALUES ('grant', pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'invoker', 'fao_reserve_recon_v1', 'true', 'pgtap admin role')$$, tests.uid('marcus.patel@finagent-os.demo'))));
INSERT INTO v VALUES ('grant_a', pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'reader', NULL, 'true', 'pgtap admin role aisha')$$, tests.uid('aisha.okonkwo@finagent-os.demo'))));
INSERT INTO v VALUES ('grant_a2', pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'reader', NULL, 'true', 'pgtap admin role aisha again')$$, tests.uid('aisha.okonkwo@finagent-os.demo'))));
INSERT INTO v VALUES ('revoke_a', pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'reader', NULL, 'false', 'pgtap admin role aisha revoke')$$, tests.uid('aisha.okonkwo@finagent-os.demo'))));
INSERT INTO v VALUES ('revoke_none', pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'reader', NULL, 'false', 'pgtap admin role aisha revoke again')$$, tests.uid('aisha.okonkwo@finagent-os.demo'))));
SELECT is(pg_temp.g('grant')->>'code', 'SELF_CHANGE', 'role: an admin changing their own roles gets SELF_CHANGE');
SELECT ok(pg_temp.g('grant_a')->>'ok' = 'true' AND pg_temp.g('grant_a')->'before' = 'null'::jsonb, 'role: a new grant has before NULL');
SELECT is((SELECT granted_by FROM public.fao_user_roles WHERE user_id = tests.uid('aisha.okonkwo@finagent-os.demo') AND role = 'reader' ORDER BY id DESC LIMIT 1),
  tests.uid('marcus.patel@finagent-os.demo'), 'role: granted_by is the admin');
SELECT ok(pg_temp.g('grant_a2')->>'ok' = 'true' AND pg_temp.g('grant_a2')->'before' = pg_temp.g('grant_a2')->'after', 'role: an identical grant is a no-op with before equal to after');
SELECT ok(pg_temp.g('revoke_a')->>'ok' = 'true' AND pg_temp.g('revoke_a')->'after'->>'revoked_at' IS NOT NULL, 'role: revoke sets revoked_at');
SELECT is(pg_temp.g('revoke_none')->>'code', 'NOT_FOUND', 'role: revoking a grant that is not active is NOT_FOUND');
SELECT is((SELECT count(*) FROM pg_temp.audit('public.fao_user_roles', '%pgtap admin role aisha%')), 2::bigint, 'role: grant and revoke are audited');
SELECT is(pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'invoker', NULL, 'true', 'pgtap')$$, gen_random_uuid()))->>'code', 'NOT_FOUND', 'role: an unknown user is NOT_FOUND');
SELECT is(pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'invoker', NULL, 'true', 'pgtap')$$, tests.uid('outsider@local.test')))->>'code', 'NOT_FOUND', 'role: a non-reader role for a user without an owner row is NOT_FOUND');
SELECT is(pg_temp.marcus(format($$SELECT public.fao_admin_set_role(%L, 'invoker', 'fao_no_such_agent', 'true', 'pgtap')$$, tests.uid('aisha.okonkwo@finagent-os.demo')))->>'code', 'NOT_FOUND', 'role: an unknown agent is NOT_FOUND');

-- Refusals for non-admins are journaled
INSERT INTO v VALUES ('sarah_thr', tests.jsonb_as('sarah.chen@finagent-os.demo', $$SELECT public.fao_admin_set_threshold('BTC', 'Spot', 'Major', '1', '1', '1', '1', NULL, 'pgtap not admin')$$));
INSERT INTO v VALUES ('outsider_agent', tests.jsonb_as('outsider@local.test', $$SELECT public.fao_admin_set_agent('fao_reserve_recon_v1', NULL, NULL, '9', 'pgtap not admin')$$));
INSERT INTO v VALUES ('sarah_role', tests.jsonb_as('sarah.chen@finagent-os.demo', format($$SELECT public.fao_admin_set_role(%L, 'admin', NULL, 'true', 'pgtap not admin')$$, tests.uid('aisha.okonkwo@finagent-os.demo'))));
SELECT is(pg_temp.g('sarah_thr')->>'code', 'NOT_AUTHORISED', 'Sarah is refused a threshold change');
SELECT is(tests.journal_row((pg_temp.g('sarah_thr')->>'ref')::bigint)->>'entry_point', 'rpc:fao_admin_set_threshold', 'Sarah''s refusal is journaled');
SELECT is(pg_temp.g('outsider_agent')->>'code', 'NOT_AUTHORISED', 'Outsider is refused an agent change');
SELECT ok(pg_temp.g('outsider_agent')->>'ref' IS NOT NULL, 'Outsider''s refusal is journaled');
SELECT is(pg_temp.g('sarah_role')->>'code', 'NOT_AUTHORISED', 'Sarah is refused a role change');
SELECT is((SELECT max_runs_per_hour FROM public.agent_registry WHERE agent_id = 'fao_reserve_recon_v1'), 7, 'refused changes changed nothing');

-- Junk in every argument is INVALID_INPUT
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''btc'', ''Spot'', ''Major'', ''600000'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold symbol lower case');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''ABCDEFGHIJKLM'', ''Spot'', ''Major'', ''600000'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold symbol too long');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Moon'', ''Major'', ''600000'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold scope label');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Gold'', ''600000'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold asset class label');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''NaN'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold materiality NaN');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''Infinity'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold materiality Infinity');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''-1'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold materiality negative');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''abc'', ''1'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold materiality text');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''600000'', ''1'', ''-Infinity'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold ratio -Infinity');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''600000'', ''1.2'', ''1.05'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold floor above lower');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''600000'', ''1'', ''1.4'', ''1.3'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold lower above upper');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''600000'', ''1'', ''1.05'', ''123456789'', ''pgtap'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold ratio out of range');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''600000'', ''1'', ''1.05'', ''1.3'', ''nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: threshold notes too long');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_threshold(''BTC'', ''Spot'', ''Major'', ''600000'', ''1'', ''1.05'', ''1.3'', ''pgtap'', '''')')->>'code', 'INVALID_INPUT', 'junk: threshold empty reason');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''Bad Id'', NULL, NULL, ''7'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent id pattern');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', ''RUNNING'', NULL, ''7'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent status label');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, ''yes'', ''7'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent ai flag not boolean');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, ''TRUE'', ''7'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent ai flag upper case');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, NULL, ''0'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent max runs 0');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, NULL, ''61'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent max runs 61');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, NULL, ''1.5'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent max runs fraction');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, NULL, ''NaN'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent max runs NaN');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, NULL, NULL, ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: agent all NULL');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_agent(''fao_reserve_recon_v1'', NULL, NULL, ''7'', '''')')->>'code', 'INVALID_INPUT', 'junk: agent empty reason');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_role(''not-a-uuid'', ''invoker'', NULL, ''true'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: role user not a uuid');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_role(' || quote_literal(tests.uid('sarah.chen@finagent-os.demo')::text) || ', ''superuser'', NULL, ''true'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: role label');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_role(' || quote_literal(tests.uid('sarah.chen@finagent-os.demo')::text) || ', ''invoker'', NULL, ''maybe'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: role grant not boolean');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_role(' || quote_literal(tests.uid('sarah.chen@finagent-os.demo')::text) || ', ''admin'', ''fao_reserve_recon_v1'', ''true'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: role admin with an agent');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_role(' || quote_literal(tests.uid('sarah.chen@finagent-os.demo')::text) || ', ''invoker'', ''Bad Id'', ''true'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: role agent id pattern');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_role(' || quote_literal(tests.uid('sarah.chen@finagent-os.demo')::text) || ', ''invoker'', NULL, ''true'', '''')')->>'code', 'INVALID_INPUT', 'junk: role empty reason');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_owner_active(''not-a-uuid'', ''false'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: owner_active user not a uuid');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_owner_active(' || quote_literal(tests.uid('sarah.chen@finagent-os.demo')::text) || ', ''FALSE'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: owner_active flag not exact boolean');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_admin_set_owner_active(' || quote_literal(tests.uid('sarah.chen@finagent-os.demo')::text) || ', ''false'', ''bad' || chr(1) || 'reason'')')->>'code', 'INVALID_INPUT', 'junk: owner_active control characters in reason');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_ledger_correct(''abc'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: correct id text');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_ledger_correct(''0'', ''pgtap junk'')')->>'code', 'INVALID_INPUT', 'junk: correct id 0');
SELECT is(tests.jsonb_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_ledger_correct(''1'', '''')')->>'code', 'INVALID_INPUT', 'junk: correct empty reason');

-- fao_admin_set_owner_active
INSERT INTO v VALUES ('self_active', pg_temp.marcus(format($$SELECT public.fao_admin_set_owner_active(%L, 'false', 'pgtap self')$$, tests.uid('marcus.patel@finagent-os.demo'))));
INSERT INTO v VALUES ('missing_owner', pg_temp.marcus(format($$SELECT public.fao_admin_set_owner_active(%L, 'false', 'pgtap missing')$$, tests.uid('outsider@local.test'))));
INSERT INTO v VALUES ('sarah_off', pg_temp.marcus(format($$SELECT public.fao_admin_set_owner_active(%L, 'false', 'pgtap admin owner')$$, tests.uid('sarah.chen@finagent-os.demo'))));
SELECT is(pg_temp.g('self_active')->>'code', 'SELF_CHANGE', 'owner_active: an admin changing their own active flag gets SELF_CHANGE');
SELECT is(pg_temp.g('missing_owner')->>'code', 'NOT_FOUND', 'owner_active: a user without an owner row is NOT_FOUND');
SELECT ok(pg_temp.g('sarah_off')->>'ok' = 'true' AND pg_temp.g('sarah_off')->'after'->>'active' = 'false', 'owner_active: Marcus deactivates Sarah');
SELECT is((SELECT actor_uid FROM pg_temp.audit('public.process_owners', '%pgtap admin owner%')), tests.uid('marcus.patel@finagent-os.demo'), 'owner_active: audited with Marcus as actor');

-- Direct owner changes need a change reason; the recipe with a reason is audited
DO $$ BEGIN PERFORM set_config('fao.change_reason', '', true); END $$;
SELECT throws_ok($$UPDATE public.agent_registry SET max_runs_per_hour = 9 WHERE agent_id = 'fao_reserve_recon_v1'$$, '42501', NULL, 'owner: a registry change without a reason is refused');
SELECT throws_ok($$UPDATE public.fao_settings SET value = '5' WHERE key = 'notify_max_attempts'$$, '42501', NULL, 'owner: a settings change without a reason is refused');
SELECT throws_ok($$UPDATE public.process_owners SET role = 'x' WHERE email = 'sarah.chen@finagent-os.demo'$$, '42501', NULL, 'owner: an owner change without a reason is refused');
DO $$ BEGIN PERFORM set_config('fao.change_reason', 'pgtap recipe: raise flagship limit', true); END $$;
SELECT lives_ok($$UPDATE public.agent_registry SET max_runs_per_hour = 9 WHERE agent_id = 'fao_reserve_recon_v1'$$, 'owner: the SQL recipe with a reason succeeds');
SELECT ok((SELECT actor_uid IS NULL AND db_role = 'postgres' AND reason = 'pgtap recipe: raise flagship limit' FROM pg_temp.audit('public.agent_registry', 'pgtap recipe%')),
  'owner: the recipe change is audited with its reason');

-- Audit and journal rows are append-only for every role and the owner
SELECT throws_ok($$UPDATE public.fao_admin_audit SET reason = 'x'$$, '42501', NULL, 'owner: audit rows cannot be updated');
SELECT throws_ok($$DELETE FROM public.fao_admin_audit$$, '42501', NULL, 'owner: audit rows cannot be deleted');
SELECT throws_ok($$UPDATE public.fao_refusal_journal SET code = 'x'$$, '42501', NULL, 'owner: journal rows cannot be updated');
SELECT throws_ok($$DELETE FROM public.fao_refusal_journal$$, '42501', NULL, 'owner: journal rows cannot be deleted');
SELECT throws_ok($$SELECT tests.do_as('marcus.patel@finagent-os.demo', 'UPDATE public.fao_admin_audit SET reason = ''x''')$$, '42501', NULL, 'admin: audit rows cannot be updated');
SELECT throws_ok($$SELECT tests.do_as('marcus.patel@finagent-os.demo', 'DELETE FROM public.fao_refusal_journal')$$, '42501', NULL, 'admin: journal rows cannot be deleted');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'UPDATE public.fao_admin_audit SET reason = ''x''')$$, '42501', NULL, 'fao_workflow: audit rows cannot be updated');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'DELETE FROM public.fao_admin_audit')$$, '42501', NULL, 'service_role: audit rows cannot be deleted');

SELECT * FROM finish();
ROLLBACK;
