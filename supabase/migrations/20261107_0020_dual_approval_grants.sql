-- ============================================================================
-- FinAgent OS: Migration 0020: dual approval grants and the grants assertion
-- ============================================================================
-- The last dual approval file (after 0018 and 0019). In order:
--   1. Revoke every privilege on public.hitl_approvals and its sequence from
--      PUBLIC and every client role (repeats 0018, so this file is correct
--      on its own).
--   2. fao_private.grants_expected(): the 0017 allow-list plus SELECT on
--      hitl_approvals for authenticated.
--   3. fao_private.grants_drift(): the 0017 body with hitl_approvals among
--      the public relations checked (its sequence is found through pg_depend
--      like the others), so the maintenance sweep checks the new table with
--      no change to the sweep.
--   4. Grant SELECT on hitl_approvals to authenticated (RLS: has_any_role).
--      Nothing else is granted.
--   5. The final assertion, identical to 0017 section 6 except its notice:
--      no drift; every public.fao_* function SECURITY DEFINER, VOLATILE and
--      search_path pinned; the nine client RPCs exactly once with one unnamed
--      json argument and no default; every fao_private function pinned; the
--      v1 append-only trigger function pinned. Any failure aborts the bundle.
--
-- Control IDs implemented:
--   FAO-GOV-015  least privilege for the new table and its sequence, the
--                allow-list and drift check extended to them, the assertion
--                re-run after dual approval
--   FAO-GOV-004  approvals are read by members only and written by no client
--                role
--
-- Replaces (CREATE OR REPLACE, same signatures):
--   - fao_private.grants_expected()   (migration 0017)
--   - fao_private.grants_drift()      (migration 0017)
--
-- Must work applied on its own after 0019, as one transaction 0018 to 0020
-- on a live core, and inside the cutover bundle 0010 to 0020.
--
-- Rollback: see phase2-5/rollback/rollback_dual_approval.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. The new table and its sequence (FAO-GOV-015)
-- ----------------------------------------------------------------------------
REVOKE ALL ON TABLE    public.hitl_approvals                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON SEQUENCE public.hitl_approvals_approval_id_seq FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

-- ----------------------------------------------------------------------------
-- 2. The allow-list as rows (build spec 2.12 plus dual approval 2.6)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fao_private.grants_expected()
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
      ('table',    'public',      'hitl_approvals',         'authenticated', 'SELECT'),
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
  'FAO-GOV-015: the grant allow-list (build spec 2.12) as rows: object kind, schema, object (functions by regprocedure text), grantee and privilege. Dual approval (0020) adds SELECT on hitl_approvals for authenticated.';

-- ----------------------------------------------------------------------------
-- 3. The drift between the allow-list and the catalog, hitl_approvals added
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fao_private.grants_drift()
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
              'shadow_ledger', 'hitl_queue', 'hitl_approvals', 'agent_registry', 'process_owners', 'materiality_thresholds',
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
-- 4. The one new grant (dual approval 2.6)
-- ----------------------------------------------------------------------------
-- Approvals: members read under RLS (has_any_role); written only by
-- fao_hitl_decide.
GRANT SELECT ON TABLE public.hitl_approvals TO authenticated;

-- ----------------------------------------------------------------------------
-- 5. Final assertion (FAO-GOV-015), as 0017 section 6. Raises, aborting the
--    bundle, unless the catalog matches the allow-list and every FinAgent
--    function is pinned.
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

  RAISE NOTICE 'FAO-GOV-015 0020: grants assertion passed';
END
$$;
