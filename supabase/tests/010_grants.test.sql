-- ============================================================================
-- FinAgent OS pgTAP 010: privileges equal the allow-list exactly
-- Controls: FAO-GOV-001, FAO-GOV-004, FAO-GOV-015 (least privilege for every
-- client role; no PUBLIC grants; definer functions pinned; no drift).
-- The expected list is written here, independent of grants_expected().
-- Schema tests is ignored.
-- ============================================================================
BEGIN;
SELECT plan(48);

CREATE TEMP TABLE fin_rel AS
SELECT c.oid, n.nspname::text COLLATE "default" AS sch, c.relname::text COLLATE "default" AS obj,
       CASE c.relkind WHEN 'v' THEN 'view' WHEN 'S' THEN 'sequence' ELSE 'table' END AS kind
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE (n.nspname = 'public' AND c.relname IN ('shadow_ledger','hitl_queue','agent_registry','process_owners','materiality_thresholds',
                                              'run_invocations','fao_user_roles','fao_settings','fao_refusal_journal','fao_admin_audit',
                                              'fao_notifications','fao_run_summary'))
   OR (n.nspname = 'fao_private' AND c.relname IN ('run_tokens','test_clock'));

INSERT INTO fin_rel
SELECT DISTINCT s.oid, n.nspname::text COLLATE "default", s.relname::text COLLATE "default", 'sequence'
FROM pg_depend d
JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
JOIN pg_namespace n ON n.oid = s.relnamespace
WHERE d.classid = 'pg_class'::regclass AND d.refclassid = 'pg_class'::regclass
  AND d.refobjid IN (SELECT oid FROM fin_rel) AND d.deptype IN ('a', 'i');

CREATE TEMP TABLE fin_fn AS
SELECT p.oid, n.nspname::text COLLATE "default" AS sch, p.proname::text COLLATE "default" AS obj
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE (n.nspname = 'public' AND (p.proname LIKE 'fao\_%' OR p.proname = 'shadow_ledger_enforce_append_only'))
   OR n.nspname = 'fao_private';

CREATE TEMP TABLE client_roles AS SELECT unnest(ARRAY['anon','authenticated','fao_workflow','service_role']) AS rolname;

-- Section 2.12, written out.
CREATE TEMP TABLE expected_acl (kind text, sch text, obj text, grantee text, privilege text);
INSERT INTO expected_acl VALUES
  ('table','public','shadow_ledger','authenticated','SELECT'),
  ('table','public','run_invocations','authenticated','SELECT'),
  ('table','public','hitl_queue','authenticated','SELECT'),
  ('table','public','agent_registry','authenticated','SELECT'),
  ('table','public','process_owners','authenticated','SELECT'),
  ('table','public','materiality_thresholds','authenticated','SELECT'),
  ('table','public','materiality_thresholds','fao_workflow','SELECT'),
  ('table','public','fao_user_roles','authenticated','SELECT'),
  ('table','public','fao_refusal_journal','authenticated','SELECT'),
  ('table','public','fao_admin_audit','authenticated','SELECT'),
  ('table','public','fao_notifications','authenticated','SELECT'),
  ('table','public','fao_settings','authenticated','SELECT'),
  ('view','public','fao_run_summary','authenticated','SELECT'),
  ('function','public','fao_run_start','anon','EXECUTE'),
  ('function','public','fao_hitl_decide','anon','EXECUTE'),
  ('function','public','fao_run_start','authenticated','EXECUTE'),
  ('function','public','fao_hitl_decide','authenticated','EXECUTE'),
  ('function','public','fao_whoami','authenticated','EXECUTE'),
  ('function','public','fao_hitl_get','authenticated','EXECUTE'),
  ('function','public','fao_ledger_correct','authenticated','EXECUTE'),
  ('function','public','fao_admin_set_threshold','authenticated','EXECUTE'),
  ('function','public','fao_admin_set_agent','authenticated','EXECUTE'),
  ('function','public','fao_admin_set_role','authenticated','EXECUTE'),
  ('function','public','fao_admin_set_owner_active','authenticated','EXECUTE'),
  ('function','fao_private','has_role','authenticated','EXECUTE'),
  ('function','fao_private','has_any_role','authenticated','EXECUTE'),
  ('function','public','fao_run_claim','fao_workflow','EXECUTE'),
  ('function','public','fao_ledger_append_batch','fao_workflow','EXECUTE'),
  ('function','public','fao_run_finalize','fao_workflow','EXECUTE'),
  ('function','public','fao_run_fail','fao_workflow','EXECUTE'),
  ('function','public','fao_notification_context','fao_workflow','EXECUTE'),
  ('function','public','fao_notification_record','fao_workflow','EXECUTE'),
  ('function','public','fao_maintenance_sweep','fao_workflow','EXECUTE'),
  ('schema','fao_private','fao_private','authenticated','USAGE');

-- 1. aclexplode over relacl, proacl and nspacl equals the list exactly
SELECT results_eq(
  $$SELECT kind, sch, obj, grantee, privilege FROM (
      SELECT r.kind, r.sch, r.obj, g.rolname::text COLLATE "default" AS grantee, a.privilege_type::text AS privilege
      FROM fin_rel r JOIN pg_class c ON c.oid = r.oid
      CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles g ON g.oid = a.grantee
      WHERE g.rolname::text IN (SELECT rolname FROM client_roles)
      UNION ALL
      SELECT 'function', f.sch, f.obj, g.rolname::text COLLATE "default", a.privilege_type::text
      FROM fin_fn f JOIN pg_proc p ON p.oid = f.oid
      CROSS JOIN LATERAL aclexplode(p.proacl) a JOIN pg_roles g ON g.oid = a.grantee
      WHERE g.rolname::text IN (SELECT rolname FROM client_roles)
      UNION ALL
      SELECT 'schema', n.nspname::text COLLATE "default", n.nspname::text COLLATE "default", g.rolname::text COLLATE "default", a.privilege_type::text
      FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a JOIN pg_roles g ON g.oid = a.grantee
      WHERE n.nspname = 'fao_private' AND g.rolname::text IN (SELECT rolname FROM client_roles)
    ) x ORDER BY 1, 2, 3, 4, 5$$,
  $$SELECT kind, sch, obj, grantee, privilege FROM expected_acl ORDER BY 1, 2, 3, 4, 5$$,
  'client-role privileges on FinAgent objects equal the allow-list');

-- 2. no column-level privileges for anyone outside the owner class
SELECT is((SELECT count(*) FROM pg_attribute a JOIN fin_rel r ON r.oid = a.attrelid
           CROSS JOIN LATERAL aclexplode(a.attacl) x
           WHERE NOT a.attisdropped AND x.grantee NOT IN (SELECT oid FROM pg_roles WHERE rolname IN ('postgres','supabase_admin'))),
  0::bigint, 'no column-level privileges on FinAgent tables');

-- 3 to 6. PUBLIC holds nothing
SELECT is((SELECT count(*) FROM fin_rel r JOIN pg_class c ON c.oid = r.oid CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE a.grantee = 0),
  0::bigint, 'no PUBLIC entry on any FinAgent table, view or sequence');
SELECT is((SELECT count(*) FROM fin_fn f JOIN pg_proc p ON p.oid = f.oid CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE a.grantee = 0),
  0::bigint, 'no PUBLIC entry in any FinAgent function proacl');
SELECT is((SELECT count(*) FROM fin_fn f JOIN pg_proc p ON p.oid = f.oid WHERE p.proacl IS NULL),
  0::bigint, 'no FinAgent function keeps the default (PUBLIC) execute privilege');
SELECT is((SELECT count(*) FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a WHERE n.nspname = 'fao_private' AND a.grantee = 0),
  0::bigint, 'no PUBLIC entry on schema fao_private');

-- 7 to 9. has_*_privilege agrees per role and object
SELECT is_empty(
  $$SELECT cr.rolname, r.obj, p.priv
    FROM client_roles cr CROSS JOIN fin_rel r
    CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS p(priv)
    WHERE r.kind IN ('table', 'view')
      AND has_table_privilege(cr.rolname, r.oid, p.priv)
          IS DISTINCT FROM EXISTS (SELECT 1 FROM expected_acl e WHERE e.sch = r.sch AND e.obj = r.obj AND e.grantee = cr.rolname AND e.privilege = p.priv)$$,
  'has_table_privilege agrees with the allow-list for every role, table and privilege');
SELECT is_empty(
  $$SELECT cr.rolname, r.obj, p.priv
    FROM client_roles cr CROSS JOIN fin_rel r CROSS JOIN unnest(ARRAY['USAGE','SELECT','UPDATE']) AS p(priv)
    WHERE r.kind = 'sequence' AND has_sequence_privilege(cr.rolname, r.oid, p.priv)$$,
  'no client role holds any privilege on a FinAgent sequence');
SELECT is_empty(
  $$SELECT cr.rolname, f.sch, f.obj
    FROM client_roles cr CROSS JOIN fin_fn f
    WHERE has_function_privilege(cr.rolname, f.oid, 'EXECUTE')
          IS DISTINCT FROM EXISTS (SELECT 1 FROM expected_acl e WHERE e.kind = 'function' AND e.sch = f.sch AND e.obj = f.obj AND e.grantee = cr.rolname)$$,
  'has_function_privilege agrees with the allow-list for every role and function');

-- 10. drift function agrees
SELECT is_empty($$SELECT * FROM fao_private.grants_drift()$$, 'grants_drift() is empty');

-- 11 to 14. function properties
SELECT is_empty(
  $$SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'fao\_%'
      AND NOT (p.prosecdef AND p.provolatile = 'v'
               AND EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'search\_path=%'))$$,
  'every public.fao_* function is VOLATILE, SECURITY DEFINER and pins search_path');
SELECT is_empty(
  $$SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'fao_private'
      AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'search\_path=%')$$,
  'every fao_private function pins search_path');
-- IC-18: each client RPC exists exactly once in public and takes one unnamed
-- json argument with no default (an overload or a named or defaulted
-- parameter would let PostgREST bind arguments by name again).
SELECT results_eq(
  $$SELECT p.proname::text COLLATE "default" FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('fao_whoami','fao_run_start','fao_hitl_get','fao_hitl_decide','fao_ledger_correct',
                        'fao_admin_set_threshold','fao_admin_set_agent','fao_admin_set_role','fao_admin_set_owner_active')
    GROUP BY p.proname
    HAVING count(*) = 1
       AND bool_and(p.pronargs = 1 AND p.proargtypes[0] = 'json'::regtype::oid AND p.pronargdefaults = 0
                    AND (p.proargnames IS NULL OR p.proargnames = ARRAY['']::text[]))
    ORDER BY 1$$,
  $$VALUES ('fao_admin_set_agent'), ('fao_admin_set_owner_active'), ('fao_admin_set_role'), ('fao_admin_set_threshold'),
           ('fao_hitl_decide'), ('fao_hitl_get'), ('fao_ledger_correct'), ('fao_run_start'), ('fao_whoami')$$,
  'every client RPC exists once and takes exactly one unnamed json argument with no default');
SELECT results_eq(
  $$SELECT f.obj FROM fin_fn f WHERE has_function_privilege('anon', f.oid, 'EXECUTE') ORDER BY 1$$,
  $$VALUES ('fao_hitl_decide'), ('fao_run_start')$$,
  'anon may execute exactly fao_run_start and fao_hitl_decide');

-- 15 to 16. schemas
SELECT is_empty(
  $$SELECT rolname FROM client_roles WHERE has_schema_privilege(rolname, 'public', 'CREATE')$$,
  'no client role holds CREATE on schema public');
SELECT is_empty(
  $$SELECT rolname FROM client_roles WHERE NOT has_schema_privilege(rolname, 'public', 'USAGE')$$,
  'every client role holds USAGE on schema public');

-- 17 to 43. live probes per listed denial
SELECT throws_ok($$SELECT tests.do_as('anon', 'SELECT 1 FROM public.agent_registry LIMIT 1')$$, '42501', NULL, 'anon cannot read agent_registry');
SELECT throws_ok($$SELECT tests.do_as('anon', 'SELECT 1 FROM public.shadow_ledger LIMIT 1')$$, '42501', NULL, 'anon cannot read shadow_ledger');
SELECT throws_ok($$SELECT tests.do_as('anon', 'SELECT 1 FROM public.fao_run_summary LIMIT 1')$$, '42501', NULL, 'anon cannot read fao_run_summary');
SELECT throws_ok($$SELECT tests.do_as('anon', 'SELECT public.fao_hitl_get(json_build_object(''p_hitl_id'', ''1''))')$$, '42501', NULL, 'anon cannot execute fao_hitl_get');
SELECT throws_ok($$SELECT tests.do_as('anon', 'SELECT public.fao_whoami(json_build_object())')$$, '42501', NULL, 'anon cannot execute fao_whoami');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo',
  'INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, policy_outcome, policy_rationale, status) VALUES (gen_random_uuid(), gen_random_uuid(), ''fao_reserve_recon_v1'', ''RED'', ''ALLOW'', ''x'', ''SUCCESS'')')$$,
  '42501', NULL, 'authenticated cannot insert into shadow_ledger');
SELECT throws_ok($$SELECT tests.do_as('marcus.patel@finagent-os.demo', 'UPDATE public.agent_registry SET max_runs_per_hour = 7')$$, '42501', NULL, 'authenticated (admin) cannot update agent_registry directly');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'DELETE FROM public.hitl_queue')$$, '42501', NULL, 'authenticated cannot delete from hitl_queue');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'SELECT 1 FROM fao_private.run_tokens LIMIT 1')$$, '42501', NULL, 'authenticated cannot read run_tokens');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'SELECT fao_private.clock()')$$, '42501', NULL, 'authenticated cannot execute private helpers other than has_role');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'SELECT public.fao_run_claim(''x'', ''y'', ''fao_reserve_recon_v1'')')$$, '42501', NULL, 'authenticated cannot execute fao_run_claim');
SELECT throws_ok($$SELECT tests.do_as('marcus.patel@finagent-os.demo', 'SELECT public.fao_maintenance_sweep()')$$, '42501', NULL, 'authenticated cannot execute fao_maintenance_sweep');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'SELECT public.fao_hitl_resolve(1, ''APPROVED'', NULL, NULL)')$$, '42501', NULL, 'authenticated cannot execute fao_hitl_resolve');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'SELECT nextval(''public.fao_refusal_journal_refusal_id_seq'')')$$, '42501', NULL, 'authenticated cannot use a FinAgent sequence');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'CREATE TABLE public.pgtap_probe (x int)')$$, '42501', NULL, 'authenticated cannot create in schema public');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'SELECT 1 FROM public.shadow_ledger LIMIT 1')$$, '42501', NULL, 'fao_workflow cannot read shadow_ledger');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'SELECT 1 FROM public.hitl_queue LIMIT 1')$$, '42501', NULL, 'fao_workflow cannot read hitl_queue');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow',
  'INSERT INTO public.materiality_thresholds (asset_symbol, scope, asset_class, materiality_usd, ratio_floor, ratio_band_lower, ratio_band_upper) VALUES (''ZZZ'', ''Spot'', ''Major'', 1, 1, 1, 1)')$$,
  '42501', NULL, 'fao_workflow cannot write materiality_thresholds');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'SELECT public.fao_whoami(json_build_object())')$$, '42501', NULL, 'fao_workflow cannot execute fao_whoami');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'SELECT public.fao_hitl_decide(json_build_object(''p_hitl_id'', ''1'', ''p_decision'', ''APPROVED''))')$$, '42501', NULL, 'fao_workflow cannot execute fao_hitl_decide');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'SELECT 1 FROM fao_private.test_clock LIMIT 1')$$, '42501', NULL, 'fao_workflow cannot read test_clock');
SELECT throws_ok($$SELECT tests.do_as('fao_workflow', 'CREATE TABLE public.pgtap_probe (x int)')$$, '42501', NULL, 'fao_workflow cannot create in schema public');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'SELECT 1 FROM public.hitl_queue LIMIT 1')$$, '42501', NULL, 'service_role cannot read hitl_queue');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'SELECT 1 FROM public.materiality_thresholds LIMIT 1')$$, '42501', NULL, 'service_role cannot read materiality_thresholds');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'SELECT 1 FROM public.fao_run_summary LIMIT 1')$$, '42501', NULL, 'service_role cannot read fao_run_summary');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'SELECT public.fao_run_start(json_build_object(''p_agent_id'', ''fao_reserve_recon_v1'', ''p_reason'', ''x'', ''p_idempotency_key'', ''abcdefgh''))')$$, '42501', NULL, 'service_role cannot execute fao_run_start');
SELECT throws_ok($$SELECT tests.do_as('service_role', 'SELECT public.fao_maintenance_sweep()')$$, '42501', NULL, 'service_role cannot execute fao_maintenance_sweep');

-- 44 to 48. temp tables named like FinAgent tables change nothing
CREATE TEMP TABLE probe (k text PRIMARY KEY, v jsonb);
INSERT INTO probe VALUES ('sweep_before', tests.sweep());
INSERT INTO probe VALUES ('start', tests.start_run('aisha.okonkwo@finagent-os.demo'));

SELECT tests.do_as('fao_workflow', 'CREATE TEMP TABLE hitl_queue (hitl_id bigint, correlation_id uuid, decision text, timeout_at timestamptz)');
SELECT tests.do_as('fao_workflow', 'INSERT INTO pg_temp.hitl_queue VALUES (1, gen_random_uuid(), ''PENDING'', now() - interval ''1 day'')');
SELECT tests.do_as('fao_workflow', 'CREATE TEMP TABLE run_invocations (correlation_id uuid, state text, claimed_at timestamptz)');
SELECT tests.do_as('fao_workflow', 'INSERT INTO pg_temp.run_invocations VALUES (gen_random_uuid(), ''RUNNING'', now() - interval ''1 day'')');

SELECT is((SELECT count(*) FROM pg_class WHERE relname IN ('hitl_queue', 'run_invocations') AND relpersistence = 't'), 2::bigint,
  'fao_workflow created temporary look-alike tables');

INSERT INTO probe VALUES ('sweep_after', tests.sweep());
INSERT INTO probe VALUES ('claim', tests.claim((SELECT v->>'run_token' FROM probe WHERE k = 'start')));
INSERT INTO probe VALUES ('claim_bad', tests.claim('Z' || repeat('q', 42)));

SELECT is((SELECT v FROM probe WHERE k = 'sweep_after'), (SELECT v FROM probe WHERE k = 'sweep_before'),
  'fao_maintenance_sweep() result is unchanged by temporary look-alike tables');
SELECT is((SELECT v->>'correlation_id' FROM probe WHERE k = 'claim'), (SELECT v->>'correlation_id' FROM probe WHERE k = 'start'),
  'fao_run_claim() claims the real run despite a temporary run_invocations');
SELECT is(tests.run_state((SELECT (v->>'correlation_id')::uuid FROM probe WHERE k = 'start')), 'RUNNING',
  'the real run moved to RUNNING');
SELECT is((SELECT v->>'code' FROM probe WHERE k = 'claim_bad'), 'INVALID_TOKEN',
  'an unknown token is still INVALID_TOKEN');

SELECT * FROM finish();
ROLLBACK;
