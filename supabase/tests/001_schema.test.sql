-- ============================================================================
-- FinAgent OS pgTAP 001: schema (tables, columns, enums, checks, FK actions)
-- Controls: FAO-GOV-001 (history kept by RESTRICT FKs), FAO-GOV-004
-- (decision coherence, no self-approval), FAO-GOV-003 (tier never BLOCKED),
-- FAO-GOV-008 (run records hold no token material).
-- ============================================================================
BEGIN;
SELECT plan(47);

-- New tables
SELECT has_table('public', 'run_invocations', 'run_invocations exists');
SELECT has_table('fao_private', 'run_tokens', 'fao_private.run_tokens exists');
SELECT has_table('public', 'fao_user_roles', 'fao_user_roles exists');
SELECT has_table('public', 'fao_settings', 'fao_settings exists');
SELECT has_table('fao_private', 'test_clock', 'fao_private.test_clock exists');
SELECT has_table('public', 'fao_refusal_journal', 'fao_refusal_journal exists');
SELECT has_table('public', 'fao_admin_audit', 'fao_admin_audit exists');
SELECT has_table('public', 'fao_notifications', 'fao_notifications exists');

-- Enums and values
SELECT enum_has_labels('public', 'hitl_decision', ARRAY['PENDING','APPROVED','REJECTED','EXPIRED'], 'hitl_decision labels');
SELECT enum_has_labels('public', 'hitl_status', ARRAY['NOT_REQUIRED','PENDING','APPROVED','REJECTED','EXPIRED'], 'hitl_status labels');
SELECT enum_has_labels('public', 'fao_run_state', ARRAY['REQUESTED','RUNNING','AWAITING_HITL','COMMITTED','FAILED','EXPIRED'], 'fao_run_state labels');
SELECT enum_has_labels('public', 'fao_app_role', ARRAY['invoker','approver','admin','reader'], 'fao_app_role labels');

-- Columns added to existing tables
SELECT has_column('public', 'process_owners', 'active', 'process_owners.active');
SELECT has_column('public', 'agent_registry', 'max_runs_per_hour', 'agent_registry.max_runs_per_hour');
SELECT has_column('public', 'hitl_queue', 'configured_approvals', 'hitl_queue.configured_approvals');
SELECT has_column('public', 'hitl_queue', 'enforced_approvals', 'hitl_queue.enforced_approvals');
SELECT has_column('public', 'hitl_queue', 'approval_url', 'hitl_queue.approval_url');
SELECT has_column('public', 'hitl_queue', 'escalated_assets', 'hitl_queue.escalated_assets');
SELECT has_column('public', 'shadow_ledger', 'corrects_ledger_id', 'shadow_ledger.corrects_ledger_id');

-- Exact columns of the new tables
SELECT columns_are('public', 'run_invocations', ARRAY['correlation_id','execution_id','agent_id','invoker_id','risk_tier','invoked_via','reason','idempotency_key','state','asset_scope','n8n_execution_id','requested_at','claimed_at','finished_at','last_error'], 'run_invocations columns');
SELECT columns_are('fao_private', 'run_tokens', ARRAY['correlation_id','token_hash','expires_at','issued_at','consumed_at'], 'run_tokens columns');
SELECT columns_are('public', 'fao_user_roles', ARRAY['id','user_id','role','agent_id','granted_by','granted_at','revoked_at','reason'], 'fao_user_roles columns');
SELECT columns_are('public', 'fao_settings', ARRAY['key','value','updated_at'], 'fao_settings columns');
SELECT columns_are('fao_private', 'test_clock', ARRAY['id','offset_seconds','set_at','reason'], 'test_clock columns');
SELECT columns_are('public', 'fao_refusal_journal', ARRAY['refusal_id','at','actor_uid','db_role','session_role','entry_point','target_table','target_key','attempted','code','message'], 'fao_refusal_journal columns');
SELECT columns_are('public', 'fao_admin_audit', ARRAY['audit_id','at','table_name','op','row_key','old_row','new_row','actor_uid','db_role','session_role','txid','reason'], 'fao_admin_audit columns');
SELECT columns_are('public', 'fao_notifications', ARRAY['notification_id','hitl_id','kind','level','outcome','attempt','channel','recipient_owner_id','external_ref','error','at'], 'fao_notifications columns');

-- CHECK constraints on hitl_queue, probed with the guard triggers disabled
-- inside this transaction so only the constraints decide.
ALTER TABLE public.hitl_queue DISABLE TRIGGER USER;

SELECT throws_ok(
  $$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale, decision, approver_id)
    VALUES (gen_random_uuid(), 'fao_reserve_recon_v1', tests.uid('aisha.okonkwo@finagent-os.demo'), 'RED', 'pgtap', 'PENDING', tests.uid('sarah.chen@finagent-os.demo'))$$,
  '23514', NULL, 'coherence: PENDING with an approver is refused');
SELECT throws_ok(
  $$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale, decision)
    VALUES (gen_random_uuid(), 'fao_reserve_recon_v1', tests.uid('aisha.okonkwo@finagent-os.demo'), 'RED', 'pgtap', 'EXPIRED')$$,
  '23514', NULL, 'coherence: EXPIRED without decided_at is refused');
SELECT throws_ok(
  $$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale, decision, approver_id, decided_at)
    VALUES (gen_random_uuid(), 'fao_reserve_recon_v1', tests.uid('aisha.okonkwo@finagent-os.demo'), 'RED', 'pgtap', 'APPROVED', tests.uid('aisha.okonkwo@finagent-os.demo'), now())$$,
  '23514', NULL, 'no-self-approval enforced on insert');
SELECT throws_ok(
  $$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale)
    VALUES (gen_random_uuid(), 'fao_reserve_recon_v1', tests.uid('aisha.okonkwo@finagent-os.demo'), 'BLOCKED', 'pgtap')$$,
  '23514', NULL, 'tier BLOCKED is refused on a request');
SELECT lives_ok(
  $$INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, policy_rationale)
    VALUES ('00000000-0000-4000-8000-0000000000a1', 'fao_reserve_recon_v1', tests.uid('aisha.okonkwo@finagent-os.demo'), 'RED', 'pgtap')$$,
  'a coherent PENDING row is accepted by the constraints');
SELECT throws_ok(
  $$UPDATE public.hitl_queue SET decision = 'APPROVED', approver_id = agent_invoker_id, decided_at = now()
    WHERE correlation_id = '00000000-0000-4000-8000-0000000000a1'$$,
  '23514', NULL, 'no-self-approval enforced on update');
SELECT throws_ok(
  $$UPDATE public.hitl_queue SET decision = 'EXPIRED', approver_id = tests.uid('sarah.chen@finagent-os.demo'), decided_at = now()
    WHERE correlation_id = '00000000-0000-4000-8000-0000000000a1'$$,
  '23514', NULL, 'coherence: EXPIRED with an approver is refused');

ALTER TABLE public.hitl_queue ENABLE TRIGGER USER;

SELECT ok((SELECT NOT c.convalidated FROM pg_constraint c WHERE c.conrelid = 'public.hitl_queue'::regclass AND c.conname = 'hitl_no_self_approval'),
  'hitl_no_self_approval is NOT VALID');
SELECT ok((SELECT NOT c.convalidated FROM pg_constraint c WHERE c.conrelid = 'public.hitl_queue'::regclass AND c.conname = 'hitl_tier_not_blocked'),
  'hitl_tier_not_blocked is NOT VALID');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'public.hitl_queue'::regclass AND c.conname = 'hitl_decision_coherence' AND c.contype = 'c'),
  'hitl_decision_coherence exists');

-- Every history FK is RESTRICT
SELECT is_empty(
  $$SELECT c.conrelid::regclass::text || '.' || c.conname
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.conrelid IN ('public.process_owners'::regclass, 'public.agent_registry'::regclass, 'public.shadow_ledger'::regclass,
                         'public.hitl_queue'::regclass, 'public.materiality_thresholds'::regclass, 'public.run_invocations'::regclass,
                         'fao_private.run_tokens'::regclass, 'public.fao_user_roles'::regclass, 'public.fao_notifications'::regclass)
      AND c.confdeltype <> 'r'$$,
  'every FinAgent foreign key is ON DELETE RESTRICT');
SELECT results_eq(
  $$SELECT x.t || '.' || x.col
    FROM (VALUES ('process_owners','id'), ('process_owners','escalation_to'), ('hitl_queue','approver_id'), ('hitl_queue','agent_invoker_id'),
                 ('shadow_ledger','hitl_approver_id'), ('shadow_ledger','corrects_ledger_id'), ('materiality_thresholds','last_reviewed_by'),
                 ('run_invocations','agent_id'), ('run_invocations','invoker_id'), ('fao_user_roles','user_id'), ('fao_user_roles','agent_id'),
                 ('fao_user_roles','granted_by'), ('fao_notifications','hitl_id'), ('fao_notifications','recipient_owner_id')) AS x(t, col)
    WHERE EXISTS (
      SELECT 1 FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
      WHERE c.contype = 'f' AND c.conrelid = ('public.' || x.t)::regclass AND a.attname = x.col AND c.confdeltype = 'r')
    ORDER BY 1$$,
  $$SELECT x FROM unnest(ARRAY['fao_notifications.hitl_id','fao_notifications.recipient_owner_id','fao_user_roles.agent_id','fao_user_roles.granted_by',
    'fao_user_roles.user_id','hitl_queue.agent_invoker_id','hitl_queue.approver_id','materiality_thresholds.last_reviewed_by','process_owners.escalation_to',
    'process_owners.id','run_invocations.agent_id','run_invocations.invoker_id','shadow_ledger.corrects_ledger_id','shadow_ledger.hitl_approver_id']) AS x ORDER BY 1$$,
  'each history column has a RESTRICT foreign key');

-- test_clock is empty; no token material on run_invocations
SELECT is((SELECT count(*) FROM fao_private.test_clock), 0::bigint, 'fao_private.test_clock is empty');
SELECT is_empty(
  $$SELECT column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'run_invocations' AND column_name ~* '(token|hash|secret)'$$,
  'no run_invocations column holds token material');

-- Indexes and unique keys
SELECT has_index('public', 'fao_user_roles', 'fao_user_roles_active_key', 'fao_user_roles_active_key exists');
SELECT has_index('public', 'fao_notifications', 'fao_notifications_sent_key', 'fao_notifications_sent_key exists');
SELECT has_index('public', 'process_owners', 'process_owners_email_lower_key', 'process_owners_email_lower_key exists');
SELECT has_index('public', 'shadow_ledger', 'idx_shadow_ledger_corr_event', 'idx_shadow_ledger_corr_event exists');
SELECT col_is_unique('public', 'run_invocations', ARRAY['invoker_id','idempotency_key'], 'run_invocations unique (invoker_id, idempotency_key)');

-- fao_settings accepts only the five keys
DO $$ BEGIN PERFORM set_config('fao.change_reason', 'pgtap 001 settings key check', true); END $$;
SELECT throws_ok($$INSERT INTO public.fao_settings (key, value) VALUES ('bogus_key', 'x')$$, '23514', NULL, 'fao_settings refuses an unknown key');

SELECT * FROM finish();
ROLLBACK;
