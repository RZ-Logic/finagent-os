-- ============================================================================
-- FinAgent OS: Migration 0016: admin RPCs, ledger corrections and the run
-- summary view
-- ============================================================================
-- Client RPCs for the global admin role (PostgREST, every parameter text):
--   fao_admin_set_threshold()     upsert one materiality threshold
--   fao_admin_set_agent()         registry status, AI flag, run rate limit
--   fao_admin_set_role()          grant or revoke an application role
--   fao_admin_set_owner_active()  deactivate or reactivate a process owner
--   fao_ledger_correct()          append a CORRECTION event that references
--                                 the original ledger row
-- View:
--   fao_run_summary               one row per correlation id in the ledger
--                                 (security invoker; members and the reader)
--
-- Control IDs implemented:
--   FAO-GOV-001  corrections are new ledger rows referencing the original,
--                which is never changed; refusals journaled
--   FAO-GOV-002  registry and threshold changes need a reason and are
--                audited (the admin audit trigger records actor and reason)
--   FAO-GOV-004  role grants and revocations with a reason; no admin may
--                change their own access (SELF_CHANGE)
--   FAO-GOV-013  owners are deactivated, never deleted
--   FAO-GOV-015  the run summary view the MCP reader reads
--   FAO-REC-002  threshold changes validated (finite, positive, floor <=
--                lower <= upper)
--
-- Pattern for every admin RPC: session (NO_SESSION); every input including
-- the reason (INVALID_INPUT); global admin role (NOT_AUTHORISED); then the
-- change reason is set to "<function> by <admin uuid>: <reason>" for the
-- transaction, so the audit trigger records actor and reason. The data
-- change runs in an inner block that maps check, numeric range and foreign
-- key violations to INVALID_INPUT (a refusal, so journaled). No database
-- error text reaches a caller.
--
-- Replaces: nothing (direct owner edits keep working through the SQL recipe
-- with a change reason; they are audited the same way).
--
-- Every function: SECURITY DEFINER, VOLATILE, SET search_path = '', fully
-- qualified names; revoked from every client role here; 0017 grants
-- EXECUTE on the five RPCs and SELECT on the view to authenticated only.
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fao_admin_set_threshold (FAO-REC-002, FAO-GOV-002)
-- ----------------------------------------------------------------------------
-- Upsert on (asset_symbol, scope). Numbers are plain decimal text (optional
-- sign, digits, optional fraction and exponent, at most 40 characters), so
-- NaN and the infinities are refused before any cast. last_reviewed_by is
-- the admin from the session.
CREATE FUNCTION public.fao_admin_set_threshold(
  p_asset_symbol     text,
  p_scope            text,
  p_asset_class      text,
  p_materiality_usd  text,
  p_ratio_floor      text,
  p_ratio_band_lower text,
  p_ratio_band_upper text,
  p_notes            text,
  p_reason           text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry   constant text := 'rpc:fao_admin_set_threshold';
  c_num     constant text := '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]{1,3})?$';
  v_uid     uuid;
  v_key     text;
  v_attempt jsonb;
  v_mat     numeric;
  v_floor   numeric;
  v_lower   numeric;
  v_upper   numeric;
  v_ok      boolean := true;
  v_before  jsonb;
  v_after   jsonb;
  v_bad     boolean := false;
BEGIN
  v_key := left(p_asset_symbol, 12) || '/' || left(p_scope, 20);
  v_attempt := jsonb_build_object(
    'asset_symbol',     left(p_asset_symbol, 200),
    'scope',            left(p_scope, 200),
    'asset_class',      left(p_asset_class, 200),
    'materiality_usd',  left(p_materiality_usd, 200),
    'ratio_floor',      left(p_ratio_floor, 200),
    'ratio_band_lower', left(p_ratio_band_lower, 200),
    'ratio_band_upper', left(p_ratio_band_upper, 200),
    'notes',            left(p_notes, 200),
    'reason',           left(p_reason, 200));

  -- Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'materiality_thresholds', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- Inputs
  IF coalesce(p_asset_symbol ~ '^[A-Z0-9]{1,12}$', false) IS NOT TRUE
     OR coalesce(p_scope = ANY (enum_range(NULL::public.attestation_scope)::text[]), false) IS NOT TRUE
     OR coalesce(p_asset_class = ANY (enum_range(NULL::public.asset_class)::text[]), false) IS NOT TRUE
     OR (p_notes IS NOT NULL AND NOT fao_private.text_ok(p_notes, 0, 2000))
     OR NOT fao_private.text_ok(p_reason, 1, 500)
     OR coalesce(length(p_materiality_usd) <= 40 AND p_materiality_usd ~ c_num, false) IS NOT TRUE
     OR coalesce(length(p_ratio_floor) <= 40 AND p_ratio_floor ~ c_num, false) IS NOT TRUE
     OR coalesce(length(p_ratio_band_lower) <= 40 AND p_ratio_band_lower ~ c_num, false) IS NOT TRUE
     OR coalesce(length(p_ratio_band_upper) <= 40 AND p_ratio_band_upper ~ c_num, false) IS NOT TRUE THEN
    v_ok := false;
  END IF;
  IF v_ok THEN
    BEGIN
      v_mat   := p_materiality_usd::numeric;
      v_floor := p_ratio_floor::numeric;
      v_lower := p_ratio_band_lower::numeric;
      v_upper := p_ratio_band_upper::numeric;
    EXCEPTION WHEN others THEN
      v_ok := false;
    END;
  END IF;
  IF v_ok AND NOT (v_mat > 0 AND v_floor > 0 AND v_lower > 0 AND v_upper > 0
                   AND v_floor <= v_lower AND v_lower <= v_upper) THEN
    v_ok := false;
  END IF;
  IF NOT v_ok THEN
    RETURN fao_private.refuse(c_entry, 'materiality_thresholds', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  -- Authorization
  IF NOT fao_private.has_role(v_uid, 'admin'::public.fao_app_role, NULL) THEN
    RETURN fao_private.refuse(c_entry, 'materiality_thresholds', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  PERFORM set_config('fao.change_reason', format('%s by %s: %s', 'fao_admin_set_threshold', v_uid, p_reason), true);

  BEGIN
    SELECT to_jsonb(t) INTO v_before
      FROM public.materiality_thresholds t
     WHERE t.asset_symbol = p_asset_symbol
       AND t.scope = p_scope::public.attestation_scope
       FOR UPDATE;

    INSERT INTO public.materiality_thresholds AS t (
      asset_symbol, scope, asset_class, materiality_usd, ratio_floor,
      ratio_band_lower, ratio_band_upper, notes, last_reviewed_by, last_reviewed_at
    )
    VALUES (
      p_asset_symbol, p_scope::public.attestation_scope, p_asset_class::public.asset_class,
      v_mat, v_floor, v_lower, v_upper, p_notes, v_uid, now()
    )
    ON CONFLICT (asset_symbol, scope) DO UPDATE
       SET asset_class      = EXCLUDED.asset_class,
           materiality_usd  = EXCLUDED.materiality_usd,
           ratio_floor      = EXCLUDED.ratio_floor,
           ratio_band_lower = EXCLUDED.ratio_band_lower,
           ratio_band_upper = EXCLUDED.ratio_band_upper,
           notes            = EXCLUDED.notes,
           last_reviewed_by = EXCLUDED.last_reviewed_by,
           last_reviewed_at = EXCLUDED.last_reviewed_at
    RETURNING to_jsonb(t.*) INTO v_after;
  EXCEPTION WHEN check_violation OR numeric_value_out_of_range OR foreign_key_violation THEN
    v_bad := true;
  END;
  IF v_bad THEN
    RETURN fao_private.refuse(c_entry, 'materiality_thresholds', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  RETURN fao_private.ok_result(jsonb_build_object('before', v_before, 'after', v_after));
END;
$$;

COMMENT ON FUNCTION public.fao_admin_set_threshold(text, text, text, text, text, text, text, text, text) IS
  'FAO-REC-002, FAO-GOV-002: global admin upserts one materiality threshold with a reason; finite positive values with floor <= lower <= upper; last_reviewed_by is the admin from the session; audited with before and after images.';

-- ----------------------------------------------------------------------------
-- fao_admin_set_agent (FAO-GOV-002, FAO-GOV-014)
-- ----------------------------------------------------------------------------
-- Each NULL argument leaves its column unchanged; all three NULL is
-- INVALID_INPUT. The rate limit is an integer 1 to 60.
CREATE FUNCTION public.fao_admin_set_agent(
  p_agent_id            text,
  p_status              text,
  p_ai_advisory_enabled text,
  p_max_runs_per_hour   text,
  p_reason              text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry   constant text := 'rpc:fao_admin_set_agent';
  v_uid     uuid;
  v_key     text;
  v_attempt jsonb;
  v_max     int;
  v_before  jsonb;
  v_after   jsonb;
  v_bad     boolean := false;
BEGIN
  v_key := left(p_agent_id, 64);
  v_attempt := jsonb_build_object(
    'agent_id',            left(p_agent_id, 200),
    'status',              left(p_status, 200),
    'ai_advisory_enabled', left(p_ai_advisory_enabled, 200),
    'max_runs_per_hour',   left(p_max_runs_per_hour, 200),
    'reason',              left(p_reason, 200));

  -- Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- Inputs
  IF coalesce(p_agent_id ~ '^[a-z0-9_]{1,64}$', false) IS NOT TRUE
     OR (p_status IS NOT NULL AND coalesce(p_status = ANY (enum_range(NULL::public.agent_status)::text[]), false) IS NOT TRUE)
     OR (p_ai_advisory_enabled IS NOT NULL AND p_ai_advisory_enabled NOT IN ('true', 'false'))
     OR (p_max_runs_per_hour IS NOT NULL AND p_max_runs_per_hour !~ '^[0-9]{1,2}$')
     OR (p_status IS NULL AND p_ai_advisory_enabled IS NULL AND p_max_runs_per_hour IS NULL)
     OR NOT fao_private.text_ok(p_reason, 1, 500) THEN
    RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'INVALID_INPUT');
  END IF;
  IF p_max_runs_per_hour IS NOT NULL THEN
    v_max := p_max_runs_per_hour::int;  -- one or two digits; the cast cannot fail
    IF v_max NOT BETWEEN 1 AND 60 THEN
      RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'INVALID_INPUT');
    END IF;
  END IF;

  -- Authorization
  IF NOT fao_private.has_role(v_uid, 'admin'::public.fao_app_role, NULL) THEN
    RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  SELECT to_jsonb(a) INTO v_before
    FROM public.agent_registry a
   WHERE a.agent_id = p_agent_id
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'NOT_FOUND');
  END IF;

  PERFORM set_config('fao.change_reason', format('%s by %s: %s', 'fao_admin_set_agent', v_uid, p_reason), true);

  BEGIN
    UPDATE public.agent_registry AS a
       SET status              = coalesce(p_status::public.agent_status, a.status),
           ai_advisory_enabled = coalesce(p_ai_advisory_enabled::boolean, a.ai_advisory_enabled),
           max_runs_per_hour   = coalesce(v_max, a.max_runs_per_hour)
     WHERE a.agent_id = p_agent_id
    RETURNING to_jsonb(a.*) INTO v_after;
  EXCEPTION WHEN check_violation OR numeric_value_out_of_range OR foreign_key_violation THEN
    v_bad := true;
  END;
  IF v_bad THEN
    RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  RETURN fao_private.ok_result(jsonb_build_object('before', v_before, 'after', v_after));
END;
$$;

COMMENT ON FUNCTION public.fao_admin_set_agent(text, text, text, text, text) IS
  'FAO-GOV-002, FAO-GOV-014: global admin changes an agent''s status, AI advisory flag or run rate limit with a reason (NULL leaves a column unchanged); audited with before and after images.';

-- ----------------------------------------------------------------------------
-- fao_admin_set_role (FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- Grant (p_grant 'true') or revoke ('false') one application role. admin and
-- reader are global only (agent NULL). An admin can never change their own
-- roles. The target must exist in auth.users and, for every role except
-- reader, have a process owner row. Granting an identical active grant is a
-- no-op that returns the grant as both before and after; revoking sets
-- revoked_at on the active grant (rows are never deleted).
CREATE FUNCTION public.fao_admin_set_role(
  p_user_id  text,
  p_role     text,
  p_agent_id text,
  p_grant    text,
  p_reason   text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry   constant text := 'rpc:fao_admin_set_role';
  c_uuid    constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_uid     uuid;
  v_key     text;
  v_attempt jsonb;
  v_target  uuid;
  v_role    public.fao_app_role;
  v_row     public.fao_user_roles%ROWTYPE;
  v_before  jsonb;
  v_after   jsonb;
  v_bad     boolean := false;
  v_found   boolean;
BEGIN
  v_key := left(p_user_id, 36);
  v_attempt := jsonb_build_object(
    'user_id',  left(p_user_id, 200),
    'role',     left(p_role, 200),
    'agent_id', left(p_agent_id, 200),
    'grant',    left(p_grant, 200),
    'reason',   left(p_reason, 200));

  -- Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- Inputs
  IF coalesce(p_user_id ~ c_uuid, false) IS NOT TRUE
     OR coalesce(p_role = ANY (enum_range(NULL::public.fao_app_role)::text[]), false) IS NOT TRUE
     OR (p_agent_id IS NOT NULL AND p_agent_id !~ '^[a-z0-9_]{1,64}$')
     OR (p_agent_id IS NOT NULL AND p_role IN ('admin', 'reader'))
     OR coalesce(p_grant IN ('true', 'false'), false) IS NOT TRUE
     OR NOT fao_private.text_ok(p_reason, 1, 500) THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'INVALID_INPUT');
  END IF;
  BEGIN
    v_target := p_user_id::uuid;
  EXCEPTION WHEN others THEN
    v_target := NULL;
  END;
  IF v_target IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'INVALID_INPUT');
  END IF;
  v_role := p_role::public.fao_app_role;

  -- Authorization
  IF NOT fao_private.has_role(v_uid, 'admin'::public.fao_app_role, NULL) THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;
  IF v_target = v_uid THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'SELF_CHANGE');
  END IF;

  -- Targets
  IF p_agent_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.agent_registry a WHERE a.agent_id = p_agent_id) THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'NOT_FOUND');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_target)
     OR (v_role <> 'reader'::public.fao_app_role
         AND NOT EXISTS (SELECT 1 FROM public.process_owners po WHERE po.id = v_target)) THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'NOT_FOUND');
  END IF;

  -- One role change per user at a time.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('fao_role:' || v_target::text));

  SELECT * INTO v_row
    FROM public.fao_user_roles r
   WHERE r.user_id = v_target
     AND r.role = v_role
     AND coalesce(r.agent_id, '*') = coalesce(p_agent_id, '*')
     AND r.revoked_at IS NULL
     FOR UPDATE;
  v_found := FOUND;

  IF p_grant = 'true' THEN
    IF v_found THEN
      -- Identical active grant: nothing changes.
      v_before := to_jsonb(v_row);
      RETURN fao_private.ok_result(jsonb_build_object('before', v_before, 'after', v_before));
    END IF;

    PERFORM set_config('fao.change_reason', format('%s by %s: %s', 'fao_admin_set_role', v_uid, p_reason), true);
    BEGIN
      INSERT INTO public.fao_user_roles AS r (user_id, role, agent_id, granted_by, reason)
      VALUES (v_target, v_role, p_agent_id, v_uid, p_reason)
      RETURNING to_jsonb(r.*) INTO v_after;
    EXCEPTION WHEN check_violation OR numeric_value_out_of_range OR foreign_key_violation THEN
      v_bad := true;
    END;
    IF v_bad THEN
      RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'INVALID_INPUT');
    END IF;
    RETURN fao_private.ok_result(jsonb_build_object('before', NULL::jsonb, 'after', v_after));
  END IF;

  -- Revoke
  IF NOT v_found THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'NOT_FOUND');
  END IF;
  v_before := to_jsonb(v_row);

  PERFORM set_config('fao.change_reason', format('%s by %s: %s', 'fao_admin_set_role', v_uid, p_reason), true);
  BEGIN
    UPDATE public.fao_user_roles AS r
       SET revoked_at = now()
     WHERE r.id = v_row.id
    RETURNING to_jsonb(r.*) INTO v_after;
  EXCEPTION WHEN check_violation OR numeric_value_out_of_range OR foreign_key_violation THEN
    v_bad := true;
  END;
  IF v_bad THEN
    RETURN fao_private.refuse(c_entry, 'fao_user_roles', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  RETURN fao_private.ok_result(jsonb_build_object('before', v_before, 'after', v_after));
END;
$$;

COMMENT ON FUNCTION public.fao_admin_set_role(text, text, text, text, text) IS
  'FAO-GOV-004: global admin grants or revokes an application role with a reason. admin and reader are global only; no admin changes their own roles (SELF_CHANGE); grants are revoked, never deleted; audited with before and after images.';

-- ----------------------------------------------------------------------------
-- fao_admin_set_owner_active (FAO-GOV-013)
-- ----------------------------------------------------------------------------
-- Deactivates or reactivates a process owner. Only the active flag changes;
-- the owner row and every request and ledger row naming them stay. An
-- inactive owner holds no honoured role except reader (has_role).
CREATE FUNCTION public.fao_admin_set_owner_active(
  p_user_id text,
  p_active  text,
  p_reason  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry   constant text := 'rpc:fao_admin_set_owner_active';
  c_uuid    constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_uid     uuid;
  v_key     text;
  v_attempt jsonb;
  v_target  uuid;
  v_before  jsonb;
  v_after   jsonb;
  v_bad     boolean := false;
BEGIN
  v_key := left(p_user_id, 36);
  v_attempt := jsonb_build_object(
    'user_id', left(p_user_id, 200),
    'active',  left(p_active, 200),
    'reason',  left(p_reason, 200));

  -- Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'process_owners', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- Inputs
  IF coalesce(p_user_id ~ c_uuid, false) IS NOT TRUE
     OR coalesce(p_active IN ('true', 'false'), false) IS NOT TRUE
     OR NOT fao_private.text_ok(p_reason, 1, 500) THEN
    RETURN fao_private.refuse(c_entry, 'process_owners', v_key, v_attempt, 'INVALID_INPUT');
  END IF;
  BEGIN
    v_target := p_user_id::uuid;
  EXCEPTION WHEN others THEN
    v_target := NULL;
  END;
  IF v_target IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'process_owners', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  -- Authorization
  IF NOT fao_private.has_role(v_uid, 'admin'::public.fao_app_role, NULL) THEN
    RETURN fao_private.refuse(c_entry, 'process_owners', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;
  IF v_target = v_uid THEN
    RETURN fao_private.refuse(c_entry, 'process_owners', v_key, v_attempt, 'SELF_CHANGE');
  END IF;

  SELECT to_jsonb(po) INTO v_before
    FROM public.process_owners po
   WHERE po.id = v_target
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN fao_private.refuse(c_entry, 'process_owners', v_key, v_attempt, 'NOT_FOUND');
  END IF;

  PERFORM set_config('fao.change_reason', format('%s by %s: %s', 'fao_admin_set_owner_active', v_uid, p_reason), true);

  BEGIN
    UPDATE public.process_owners AS po
       SET active = p_active::boolean
     WHERE po.id = v_target
    RETURNING to_jsonb(po.*) INTO v_after;
  EXCEPTION WHEN check_violation OR numeric_value_out_of_range OR foreign_key_violation THEN
    v_bad := true;
  END;
  IF v_bad THEN
    RETURN fao_private.refuse(c_entry, 'process_owners', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  RETURN fao_private.ok_result(jsonb_build_object('before', v_before, 'after', v_after));
END;
$$;

COMMENT ON FUNCTION public.fao_admin_set_owner_active(text, text, text) IS
  'FAO-GOV-013: global admin deactivates or reactivates a process owner with a reason; only the active flag changes; no admin changes their own flag (SELF_CHANGE); audited with before and after images.';

-- ----------------------------------------------------------------------------
-- fao_ledger_correct (FAO-GOV-001)
-- ----------------------------------------------------------------------------
-- Appends a CORRECTION event for the original row's correlation, with
-- corrects_ledger_id set. The original row is never changed. Works for runs
-- from before run records existed (run_context falls back to the ledger).
CREATE FUNCTION public.fao_ledger_correct(p_ledger_id text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry   constant text := 'rpc:fao_ledger_correct';
  v_uid     uuid;
  v_id      bigint;
  v_key     text;
  v_attempt jsonb;
  v_corr    uuid;
  v_new     bigint;
BEGIN
  v_key := left(p_ledger_id, 20);
  v_attempt := jsonb_build_object(
    'ledger_id', left(p_ledger_id, 200),
    'reason',    left(p_reason, 200));

  -- Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'shadow_ledger', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- Inputs
  v_id := fao_private.parse_id(p_ledger_id);
  IF v_id IS NULL OR NOT fao_private.text_ok(p_reason, 1, 500) THEN
    RETURN fao_private.refuse(c_entry, 'shadow_ledger', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  -- Authorization
  IF NOT fao_private.has_role(v_uid, 'admin'::public.fao_app_role, NULL) THEN
    RETURN fao_private.refuse(c_entry, 'shadow_ledger', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  SELECT l.correlation_id INTO v_corr FROM public.shadow_ledger l WHERE l.ledger_id = v_id;
  IF NOT FOUND THEN
    RETURN fao_private.refuse(c_entry, 'shadow_ledger', v_key, v_attempt, 'NOT_FOUND');
  END IF;

  PERFORM set_config('fao.change_reason', format('%s by %s: %s', 'fao_ledger_correct', v_uid, p_reason), true);

  v_new := fao_private.append_event(
    v_corr,
    'CORRECTION',
    jsonb_build_object(
      'corrects_ledger_id', v_id,
      'reason',             p_reason,
      'corrected_by',       v_uid),
    'ALLOW'::public.policy_outcome,
    NULL,
    format('FAO-GOV-001 correction of ledger_id %s: %s', v_id, p_reason),
    NULL,
    'NOT_REQUIRED'::public.hitl_status,
    NULL,
    'SUCCESS'::public.execution_status,
    NULL,
    p_corrects => v_id);

  RETURN fao_private.ok_result(jsonb_build_object(
    'ledger_id',          v_new,
    'corrects_ledger_id', v_id));
END;
$$;

COMMENT ON FUNCTION public.fao_ledger_correct(text, text) IS
  'FAO-GOV-001: global admin appends a CORRECTION ledger event with a reason, referencing the original row (corrects_ledger_id); the original row is never changed.';

-- ----------------------------------------------------------------------------
-- fao_run_summary (FAO-GOV-015, FAO-GOV-008)
-- ----------------------------------------------------------------------------
-- One row per correlation id found in the ledger. Security invoker: the
-- caller's own privileges and RLS on shadow_ledger, run_invocations and
-- hitl_queue apply, so only members and the reader see rows. Named columns
-- only; never reads fao_private. No aggregate ratio.
CREATE VIEW public.fao_run_summary WITH (security_invoker = true) AS
WITH ev AS (
  SELECT correlation_id, min(agent_id) AS agent_id,
         min(event_timestamp) AS started_at, max(event_timestamp) AS latest_event_at,
         count(*) AS event_count,
         count(*) FILTER (WHERE inputs->>'event_type' = 'COMMITTED') AS committed_count,
         coalesce(bool_or(inputs->>'event_type' = 'COMMIT_BLOCKED'), false) AS commit_blocked,
         count(*) FILTER (WHERE inputs->>'event_type' = 'CORRECTION') AS correction_count,
         max(ledger_id) FILTER (WHERE inputs->>'event_type' = 'COMMITTED') AS last_committed_id
  FROM public.shadow_ledger GROUP BY correlation_id)
SELECT ev.correlation_id, ev.agent_id, ri.invoker_id, ri.invoked_via, ri.state::text AS run_state,
       ev.started_at, ev.latest_event_at, ev.event_count,
       hq.hitl_id, hq.decision::text AS hitl_decision, hq.decided_at, hq.approver_id,
       lc.policy_outcome::text AS latest_committed_outcome, lc.status::text AS latest_committed_status,
       ev.committed_count, ev.commit_blocked, ev.correction_count, (ri.correlation_id IS NOT NULL) AS has_run_record
FROM ev
LEFT JOIN public.run_invocations ri ON ri.correlation_id = ev.correlation_id
LEFT JOIN LATERAL (SELECT h.hitl_id, h.decision, h.decided_at, h.approver_id FROM public.hitl_queue h
                   WHERE h.correlation_id = ev.correlation_id ORDER BY h.hitl_id DESC LIMIT 1) hq ON true
LEFT JOIN public.shadow_ledger lc ON lc.ledger_id = ev.last_committed_id;

-- The view is read-only. Without an INSTEAD OF trigger a write attempt fails
-- in the rewriter with database text before any privilege check; with it,
-- the privilege check runs first, so every client role gets 42501 (no write
-- grant), and the owner reaches the trigger, which refuses as well.
CREATE TRIGGER fao_run_summary_read_only
  INSTEAD OF INSERT OR UPDATE OR DELETE ON public.fao_run_summary
  FOR EACH ROW EXECUTE FUNCTION fao_private.deny_row_mutation();

COMMENT ON VIEW public.fao_run_summary IS
  'FAO-GOV-015, FAO-GOV-008: one row per correlation id in the Shadow Ledger: run record fields, newest request and decision, latest COMMITTED outcome and status, commit-blocked and correction counts. Security invoker; readable by members and the reader under RLS.';

-- ----------------------------------------------------------------------------
-- Revoke every function in this file and the view from every client role.
-- 0017 grants EXECUTE on the five RPCs and SELECT on the view to
-- authenticated only.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fao_admin_set_threshold(text, text, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_admin_set_agent(text, text, text, text, text)                             FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_admin_set_role(text, text, text, text, text)                              FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_admin_set_owner_active(text, text, text)                                  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_ledger_correct(text, text)                                                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE public.fao_run_summary                                                                  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
