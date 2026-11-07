-- ============================================================================
-- FinAgent OS: Migration 0017: grant allow-list, drift functions and the
-- final assertion
-- ============================================================================
-- Runs last, so it covers every FinAgent object created by 0001 to 0016.
--   1. Revoke every privilege on every FinAgent table, view and sequence
--      (column privileges included) from PUBLIC and every client role.
--   2. Create fao_private.grants_expected() (the allow-list as rows) and
--      fao_private.grants_drift() (present but not expected, expected but
--      missing).
--   3. Revoke every privilege on every FinAgent function from PUBLIC and
--      every client role.
--   4. Grant exactly the allow-list (build spec 2.12).
--   5. Revoke CREATE on schema public from PUBLIC and every client role.
--   6. Assert: no drift; every public.fao_* function is SECURITY DEFINER,
--      VOLATILE and pins search_path; every client RPC exists exactly once
--      and takes one unnamed json argument with no default (IC-18); every
--      fao_private function pins search_path. Any failure aborts the whole
--      bundle (a drifted project fails instead of passing silently).
--
-- Client roles: anon, authenticated, fao_workflow, service_role (and PUBLIC).
-- service_role holds nothing on any FinAgent object. Owner-class grantees
-- (postgres, supabase_admin) are outside the list. Nothing in schema tests
-- and no non-FinAgent object is listed or touched. No ALTER DEFAULT
-- PRIVILEGES anywhere.
--
-- Control IDs implemented:
--   FAO-GOV-001  no client role can write any FinAgent table; the ledger is
--                written only through the FinAgent functions
--   FAO-GOV-004  decisions only through fao_hitl_decide; anon may call only
--                the two RPCs that refuse it with NO_SESSION
--   FAO-GOV-015  least privilege for every client role, a drift check the
--                maintenance sweep reports, and an assertion at migration time
--
-- Replaces: the Supabase default grants on the v1 tables, sequences and
-- functions (0001 to 0008) and every default grant on the new objects.
--
-- Must work applied on its own and inside one transaction with 0010 to 0016.
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tables, the view and their sequences (FAO-GOV-015)
-- ----------------------------------------------------------------------------
REVOKE ALL ON TABLE
  public.shadow_ledger,
  public.hitl_queue,
  public.agent_registry,
  public.process_owners,
  public.materiality_thresholds,
  public.run_invocations,
  public.fao_user_roles,
  public.fao_settings,
  public.fao_refusal_journal,
  public.fao_admin_audit,
  public.fao_notifications,
  public.workflow_failures,
  public.fao_run_summary,
  fao_private.run_tokens,
  fao_private.test_clock
FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

-- Sequences owned by those tables (serial and identity columns), found
-- through pg_depend, and column-level privileges on those tables.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT s.oid::regclass AS seq
      FROM pg_catalog.pg_depend d
      JOIN pg_catalog.pg_class s ON s.oid = d.objid AND s.relkind = 'S'
     WHERE d.classid = 'pg_catalog.pg_class'::regclass
       AND d.refclassid = 'pg_catalog.pg_class'::regclass
       AND d.deptype IN ('a', 'i')
       AND d.refobjid IN (
         'public.shadow_ledger'::regclass, 'public.hitl_queue'::regclass,
         'public.agent_registry'::regclass, 'public.process_owners'::regclass,
         'public.materiality_thresholds'::regclass, 'public.run_invocations'::regclass,
         'public.fao_user_roles'::regclass, 'public.fao_settings'::regclass,
         'public.fao_refusal_journal'::regclass, 'public.fao_admin_audit'::regclass,
         'public.fao_notifications'::regclass, 'public.workflow_failures'::regclass,
         'public.fao_run_summary'::regclass,
         'fao_private.run_tokens'::regclass, 'fao_private.test_clock'::regclass)
  LOOP
    EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated, service_role, fao_workflow', r.seq);
    RAISE NOTICE 'FAO-GOV-015 0017: revoked sequence %', r.seq;
  END LOOP;

  FOR r IN
    SELECT a.attrelid::regclass AS rel, a.attname
      FROM pg_catalog.pg_attribute a
     WHERE a.attacl IS NOT NULL
       AND a.attnum > 0
       AND NOT a.attisdropped
       AND a.attrelid IN (
         'public.shadow_ledger'::regclass, 'public.hitl_queue'::regclass,
         'public.agent_registry'::regclass, 'public.process_owners'::regclass,
         'public.materiality_thresholds'::regclass, 'public.run_invocations'::regclass,
         'public.fao_user_roles'::regclass, 'public.fao_settings'::regclass,
         'public.fao_refusal_journal'::regclass, 'public.fao_admin_audit'::regclass,
         'public.fao_notifications'::regclass, 'public.workflow_failures'::regclass,
         'public.fao_run_summary'::regclass,
         'fao_private.run_tokens'::regclass, 'fao_private.test_clock'::regclass)
  LOOP
    EXECUTE format('REVOKE ALL (%I) ON TABLE %s FROM PUBLIC, anon, authenticated, service_role, fao_workflow', r.attname, r.rel);
    RAISE NOTICE 'FAO-GOV-015 0017: revoked column privileges on %.%', r.rel, r.attname;
  END LOOP;
END
$$;

-- ----------------------------------------------------------------------------
-- 2. The allow-list as rows, and the drift between it and the catalog
-- ----------------------------------------------------------------------------

-- FAO-GOV-015: build spec 2.12 as rows. Functions are named by their
-- regprocedure text as it reads with an empty search_path; privilege names
-- as aclexplode reports them.
CREATE FUNCTION fao_private.grants_expected()
RETURNS TABLE (object_kind text, schema_name text, object_name text, grantee text, privilege text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT e.object_kind, e.schema_name, e.object_name, e.grantee, e.privilege
    FROM (VALUES
      ('table',    'public',      'shadow_ledger',          'authenticated', 'SELECT'),
      ('table',    'public',      'run_invocations',        'authenticated', 'SELECT'),
      ('table',    'public',      'hitl_queue',             'authenticated', 'SELECT'),
      ('table',    'public',      'agent_registry',         'authenticated', 'SELECT'),
      ('table',    'public',      'process_owners',         'authenticated', 'SELECT'),
      ('table',    'public',      'materiality_thresholds', 'authenticated', 'SELECT'),
      ('table',    'public',      'materiality_thresholds', 'fao_workflow',  'SELECT'),
      ('table',    'public',      'fao_user_roles',         'authenticated', 'SELECT'),
      ('table',    'public',      'fao_refusal_journal',    'authenticated', 'SELECT'),
      ('table',    'public',      'fao_admin_audit',        'authenticated', 'SELECT'),
      ('table',    'public',      'fao_notifications',      'authenticated', 'SELECT'),
      ('table',    'public',      'fao_settings',           'authenticated', 'SELECT'),
      ('table',    'public',      'workflow_failures',      'authenticated', 'SELECT'),
      ('view',     'public',      'fao_run_summary',        'authenticated', 'SELECT'),
      ('function', 'public',      'public.fao_run_start(json)',                                        'anon',          'EXECUTE'),
      ('function', 'public',      'public.fao_run_start(json)',                                        'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_hitl_decide(json)',                                      'anon',          'EXECUTE'),
      ('function', 'public',      'public.fao_hitl_decide(json)',                                      'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_whoami(json)',                                           'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_hitl_get(json)',                                         'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_ledger_correct(json)',                                   'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_admin_set_threshold(json)',                              'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_admin_set_agent(json)',                                  'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_admin_set_role(json)',                                   'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_admin_set_owner_active(json)',                           'authenticated', 'EXECUTE'),
      ('function', 'public',      'public.fao_run_claim(text,text,text)',                              'fao_workflow',  'EXECUTE'),
      ('function', 'public',      'public.fao_ledger_append_batch(jsonb)',                             'fao_workflow',  'EXECUTE'),
      ('function', 'public',      'public.fao_run_finalize(uuid)',                                     'fao_workflow',  'EXECUTE'),
      ('function', 'public',      'public.fao_run_fail(text,text,text,text)',                          'fao_workflow',  'EXECUTE'),
      ('function', 'public',      'public.fao_notification_context(bigint,text,integer)',              'fao_workflow',  'EXECUTE'),
      ('function', 'public',      'public.fao_notification_record(bigint,text,integer,text,text,text,text)', 'fao_workflow', 'EXECUTE'),
      ('function', 'public',      'public.fao_maintenance_sweep()',                                    'fao_workflow',  'EXECUTE'),
      ('function', 'fao_private', 'fao_private.has_role(uuid,public.fao_app_role,text)',               'authenticated', 'EXECUTE'),
      ('function', 'fao_private', 'fao_private.has_any_role(uuid)',                                    'authenticated', 'EXECUTE'),
      ('schema',   'fao_private', 'fao_private',            'authenticated', 'USAGE'),
      ('schema',   'public',      'public',                 'fao_workflow',  'USAGE')
    ) AS e(object_kind, schema_name, object_name, grantee, privilege)
$$;

COMMENT ON FUNCTION fao_private.grants_expected() IS
  'FAO-GOV-015: the grant allow-list (build spec 2.12) as rows: object kind, schema, object (functions by regprocedure text), grantee and privilege.';

-- FAO-GOV-015: privileges on the FinAgent objects (named explicitly) compared
-- with the allow-list. Sources: relation ACLs, column ACLs, function ACLs
-- (a NULL ACL is read as the default, so a default PUBLIC EXECUTE shows) and
-- the fao_private schema ACL; for schema public only USAGE by fao_workflow
-- (expected) and CREATE by PUBLIC or a client role (never expected) count.
-- Grantees postgres and supabase_admin are excluded; PUBLIC is reported as
-- PUBLIC. marker '+' is present but not expected; '-' is expected but missing.
CREATE FUNCTION fao_private.grants_drift()
RETURNS TABLE (marker text, object_kind text, schema_name text, object_name text, grantee text, privilege text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH rel AS (
    SELECT c.oid, n.nspname::text AS sch, c.relname::text AS obj,
           CASE c.relkind WHEN 'v' THEN 'view' WHEN 'S' THEN 'sequence' ELSE 'table' END AS kind
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE (n.nspname = 'public' AND c.relname IN (
              'shadow_ledger', 'hitl_queue', 'agent_registry', 'process_owners', 'materiality_thresholds',
              'run_invocations', 'fao_user_roles', 'fao_settings', 'fao_refusal_journal', 'fao_admin_audit',
              'fao_notifications', 'workflow_failures', 'fao_run_summary'))
        OR (n.nspname = 'fao_private' AND c.relname IN ('run_tokens', 'test_clock'))
  ),
  seq AS (
    SELECT DISTINCT s.oid, n.nspname::text AS sch, s.relname::text AS obj, 'sequence'::text AS kind
      FROM pg_catalog.pg_depend d
      JOIN pg_catalog.pg_class s ON s.oid = d.objid AND s.relkind = 'S'
      JOIN pg_catalog.pg_namespace n ON n.oid = s.relnamespace
     WHERE d.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
       AND d.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
       AND d.deptype IN ('a', 'i')
       AND d.refobjid IN (SELECT rel.oid FROM rel)
  ),
  objs AS (
    SELECT rel.oid, rel.sch, rel.obj, rel.kind FROM rel
    UNION
    SELECT seq.oid, seq.sch, seq.obj, seq.kind FROM seq
  ),
  fn AS (
    SELECT p.oid, n.nspname::text AS sch, p.oid::pg_catalog.regprocedure::text AS obj, p.proacl, p.proowner,
           CASE WHEN p.prokind = 'p' THEN 'p' ELSE 'f' END AS acl_kind
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE (n.nspname = 'public' AND (p.proname LIKE 'fao\_%' OR p.proname = 'shadow_ledger_enforce_append_only'))
        OR n.nspname = 'fao_private'
  ),
  raw AS (
    SELECT o.kind AS object_kind, o.sch AS schema_name, o.obj AS object_name, a.grantee, a.privilege_type AS privilege
      FROM objs o
      JOIN pg_catalog.pg_class c ON c.oid = o.oid
     CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault(
                          CASE WHEN c.relkind = 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner))) a
    UNION ALL
    SELECT 'column', o.sch, o.obj || '.' || att.attname::text, a.grantee, a.privilege_type
      FROM objs o
      JOIN pg_catalog.pg_attribute att ON att.attrelid = o.oid AND att.attnum > 0 AND NOT att.attisdropped
     CROSS JOIN LATERAL pg_catalog.aclexplode(att.attacl) a
    UNION ALL
    SELECT 'function', f.sch, f.obj, a.grantee, a.privilege_type
      FROM fn f
     CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(f.proacl, pg_catalog.acldefault(f.acl_kind::"char", f.proowner))) a
    UNION ALL
    SELECT 'schema', n.nspname::text, n.nspname::text, a.grantee, a.privilege_type
      FROM pg_catalog.pg_namespace n
     CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(n.nspacl, pg_catalog.acldefault('n'::"char", n.nspowner))) a
     WHERE n.nspname = 'fao_private'
    UNION ALL
    SELECT 'schema', n.nspname::text, n.nspname::text, a.grantee, a.privilege_type
      FROM pg_catalog.pg_namespace n
     CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(n.nspacl, pg_catalog.acldefault('n'::"char", n.nspowner))) a
     WHERE n.nspname = 'public'
       AND (   (a.privilege_type = 'USAGE'
                AND a.grantee = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = 'fao_workflow'))
            OR (a.privilege_type = 'CREATE'
                AND (a.grantee = 0
                     OR a.grantee IN (SELECT r.oid FROM pg_catalog.pg_roles r
                                       WHERE r.rolname IN ('anon', 'authenticated', 'service_role', 'fao_workflow')))))
  ),
  present AS (
    SELECT DISTINCT raw.object_kind, raw.schema_name, raw.object_name,
           CASE WHEN raw.grantee = 0 THEN 'PUBLIC'
                ELSE coalesce((SELECT r.rolname::text FROM pg_catalog.pg_roles r WHERE r.oid = raw.grantee), raw.grantee::text)
           END AS grantee,
           raw.privilege
      FROM raw
  ),
  present_f AS (
    SELECT * FROM present p WHERE p.grantee NOT IN ('postgres', 'supabase_admin')
  ),
  expected AS (
    SELECT * FROM fao_private.grants_expected()
  )
  SELECT d.marker, d.object_kind, d.schema_name, d.object_name, d.grantee, d.privilege
    FROM (
      SELECT '+'::text AS marker, x.* FROM (SELECT * FROM present_f EXCEPT SELECT * FROM expected) x
      UNION ALL
      SELECT '-'::text AS marker, y.* FROM (SELECT * FROM expected EXCEPT SELECT * FROM present_f) y
    ) d
   ORDER BY d.object_kind, d.schema_name, d.object_name, d.grantee, d.privilege, d.marker
$$;

COMMENT ON FUNCTION fao_private.grants_drift() IS
  'FAO-GOV-015: privileges on FinAgent objects that differ from grants_expected(): + present but not expected, - expected but missing. Owner-class grantees excluded. Empty when the project matches the allow-list; the maintenance sweep reports and journals any drift.';

-- ----------------------------------------------------------------------------
-- 3. Functions (FAO-GOV-015): every public.fao_* function, the v1 append-only
--    trigger function and every fao_private function, this file's included.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE (n.nspname = 'public' AND (p.proname LIKE 'fao\_%' OR p.proname = 'shadow_ledger_enforce_append_only'))
        OR n.nspname = 'fao_private'
     ORDER BY n.nspname, p.proname, p.oid
  LOOP
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM PUBLIC, anon, authenticated, service_role, fao_workflow', r.fn);
    RAISE NOTICE 'FAO-GOV-015 0017: revoked function %', r.fn;
  END LOOP;
END
$$;

-- ----------------------------------------------------------------------------
-- 4. The allow-list (build spec 2.12), exactly
-- ----------------------------------------------------------------------------

-- Evidence tables: members read under RLS (has_any_role).
GRANT SELECT ON TABLE public.shadow_ledger, public.run_invocations, public.hitl_queue TO authenticated;

-- Organizational context: every signed-in caller reads (RLS: true).
GRANT SELECT ON TABLE public.agent_registry, public.process_owners TO authenticated;

-- Thresholds: signed-in callers and the workflow role read (RLS: true).
GRANT SELECT ON TABLE public.materiality_thresholds TO authenticated, fao_workflow;

-- Roles: own rows, admin or reader (RLS).
GRANT SELECT ON TABLE public.fao_user_roles TO authenticated;

-- Journal, audit, notifications, settings: admin or reader (RLS).
GRANT SELECT ON TABLE public.fao_refusal_journal, public.fao_admin_audit,
                      public.fao_notifications, public.fao_settings TO authenticated;

-- Workflow failures that attach to no run (round 5, K1): members read under
-- RLS, the MCP reader included; written only by fao_run_fail.
GRANT SELECT ON TABLE public.workflow_failures TO authenticated;

-- Summary view (security invoker: the caller's RLS applies).
GRANT SELECT ON TABLE public.fao_run_summary TO authenticated;

-- Client RPCs (one unnamed json body each, IC-18). anon may call only the
-- two that refuse it with NO_SESSION.
GRANT EXECUTE ON FUNCTION public.fao_run_start(json)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fao_hitl_decide(json) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.fao_whoami(json),
  public.fao_hitl_get(json),
  public.fao_ledger_correct(json),
  public.fao_admin_set_threshold(json),
  public.fao_admin_set_agent(json),
  public.fao_admin_set_role(json),
  public.fao_admin_set_owner_active(json)
TO authenticated;

-- Workflow RPCs (n8n over the fao_workflow connection).
GRANT EXECUTE ON FUNCTION
  public.fao_run_claim(text, text, text),
  public.fao_ledger_append_batch(jsonb),
  public.fao_run_finalize(uuid),
  public.fao_run_fail(text, text, text, text),
  public.fao_notification_context(bigint, text, int),
  public.fao_notification_record(bigint, text, int, text, text, text, text),
  public.fao_maintenance_sweep()
TO fao_workflow;

-- RLS helpers only: authenticated needs them to evaluate the read policies.
GRANT USAGE ON SCHEMA fao_private TO authenticated;
GRANT EXECUTE ON FUNCTION
  fao_private.has_role(uuid, public.fao_app_role, text),
  fao_private.has_any_role(uuid)
TO authenticated;

-- The workflow role resolves the public RPCs.
GRANT USAGE ON SCHEMA public TO fao_workflow;

-- ----------------------------------------------------------------------------
-- 5. No client role creates objects in schema public
-- ----------------------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

-- ----------------------------------------------------------------------------
-- 6. Final assertion (FAO-GOV-015). Raises, aborting the bundle, unless the
--    catalog matches the allow-list and every FinAgent function is pinned.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_detail text;
BEGIN
  SELECT string_agg(format('%s %s %s %s %s %s', d.marker, d.object_kind, d.schema_name, d.object_name, d.grantee, d.privilege), '; ')
    INTO v_detail
    FROM (SELECT * FROM fao_private.grants_drift() LIMIT 40) d;
  IF v_detail IS NOT NULL THEN
    RAISE EXCEPTION 'FAO-GOV-015 grants assertion failed: privileges differ from the allow-list: %', v_detail
      USING ERRCODE = '42501';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.proname)
    INTO v_detail
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname LIKE 'fao\_%'
     AND NOT (p.prosecdef
              AND p.provolatile = 'v'
              AND EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'search\_path=%'));
  IF v_detail IS NOT NULL THEN
    RAISE EXCEPTION 'FAO-GOV-015 grants assertion failed: not SECURITY DEFINER, VOLATILE and search_path pinned: %', v_detail
      USING ERRCODE = '42501';
  END IF;

  -- IC-18: each client RPC exists exactly once in public (no overload, such
  -- as a text signature left next to the json one, which PostgREST would
  -- answer with 300 PGRST203) and takes exactly one argument, unnamed, of
  -- type json, with no default (a default would let a GET reach it), no
  -- OUT or VARIADIC argument.
  SELECT string_agg(x.name, ', ' ORDER BY x.name)
    INTO v_detail
    FROM unnest(ARRAY['fao_whoami', 'fao_run_start', 'fao_hitl_get', 'fao_hitl_decide', 'fao_ledger_correct',
                      'fao_admin_set_threshold', 'fao_admin_set_agent', 'fao_admin_set_role',
                      'fao_admin_set_owner_active']) AS x(name)
   WHERE (SELECT count(*)
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = x.name) <> 1
      OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_proc p
             JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname = x.name
              AND NOT (p.pronargs = 1
                       AND p.proargtypes[0] = 'pg_catalog.json'::pg_catalog.regtype::oid
                       AND (p.proargnames IS NULL OR p.proargnames = ARRAY['']::text[])
                       AND p.pronargdefaults = 0
                       AND p.proallargtypes IS NULL
                       AND p.provariadic = 0));
  IF v_detail IS NOT NULL THEN
    RAISE EXCEPTION 'FAO-GOV-015 grants assertion failed: client RPC missing, overloaded or not one unnamed json argument without a default: %', v_detail
      USING ERRCODE = '42501';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.proname)
    INTO v_detail
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'fao_private'
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'search\_path=%');
  IF v_detail IS NOT NULL THEN
    RAISE EXCEPTION 'FAO-GOV-015 grants assertion failed: fao_private function without a pinned search_path: %', v_detail
      USING ERRCODE = '42501';
  END IF;

  -- B-28 (round 5): the v1 append-only trigger function is pinned too (0013).
  IF EXISTS (
       SELECT 1
         FROM pg_catalog.pg_proc p
         JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'shadow_ledger_enforce_append_only'
          AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'search\_path=%')) THEN
    RAISE EXCEPTION 'FAO-GOV-015 grants assertion failed: public.shadow_ledger_enforce_append_only() without a pinned search_path'
      USING ERRCODE = '42501';
  END IF;

  RAISE NOTICE 'FAO-GOV-015 0017: grants assertion passed';
END
$$;
