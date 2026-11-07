-- ============================================================================
-- FinAgent OS: Migration 0011: private helpers and generic trigger functions
-- ============================================================================
-- Creates the helpers every later FinAgent function and policy uses: caller
-- identity, the clock, role checks, the fixed code and message table, input
-- validation, the result envelope and the refusal journal. Also creates the
-- generic trigger functions (append-only, no TRUNCATE, change reason,
-- updated_at, admin audit) and attaches the append-only pair to the three
-- evidence tables created in 0010. Every other trigger attachment is in 0013.
--
-- Functions are created before any policy that calls them, because CREATE
-- POLICY resolves functions when the policy is created (0013).
--
-- Control IDs implemented:
--   FAO-GOV-001  refusal journal with a per-actor flood cap; append-only and
--                no-TRUNCATE triggers; admin audit images
--   FAO-GOV-002  change reason required for configuration tables
--   FAO-GOV-004  role checks (has_role, has_any_role) used by RLS and RPCs
--   FAO-GOV-008  fixed result envelope, codes, HTTP statuses and messages;
--                the client RPC body decoder client_args (IC-18)
--
-- Replaces: nothing.
--
-- Every function: SET search_path = '' and fully qualified names. SECURITY
-- DEFINER unless it is a trigger function (SECURITY INVOKER). Every function
-- in this file is revoked from every client role; 0017 grants EXECUTE on
-- has_role and has_any_role to authenticated (for RLS) and nothing else.
--
-- Messages and codes come only from the fixed table in code_message and
-- code_http. No database error text is ever returned to a caller.
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Identity and time
-- ----------------------------------------------------------------------------

-- FAO-GOV-001: the database role the caller is acting as. Through PostgREST
-- this is the role PostgREST switched to (anon or authenticated); on a direct
-- connection with no SET ROLE it is the login role (for example fao_workflow).
-- SECURITY DEFINER does not change the role setting, so the caller's role is
-- reported, not the function owner.
CREATE FUNCTION fao_private.caller_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(nullif(current_setting('role', true), 'none'), session_user::text)
$$;

COMMENT ON FUNCTION fao_private.caller_role() IS
  'FAO-GOV-001: role the caller acts as (the SET ROLE value, else the session user). Used for journal and audit rows.';

-- FAO-GOV-004: the FinAgent clock. now() plus the test clock offset (0 when
-- the test clock is empty, which it is in every deployed project). Deadlines
-- (timeout_at, token expiry) are compared against this clock.
CREATE FUNCTION fao_private.clock()
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT now() + make_interval(secs => coalesce(
    (SELECT tc.offset_seconds FROM fao_private.test_clock tc WHERE tc.id = 1), 0))
$$;

COMMENT ON FUNCTION fao_private.clock() IS
  'FAO-GOV-004: now() plus the test clock offset (0 when fao_private.test_clock is empty). Used for every deadline check.';

-- FAO-GOV-013: true when the user has an active process_owners row.
CREATE FUNCTION fao_private.owner_active(p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce((SELECT po.active FROM public.process_owners po WHERE po.id = p_uid), false)
$$;

COMMENT ON FUNCTION fao_private.owner_active(uuid) IS
  'FAO-GOV-013: true when the user has a process_owners row with active = true.';

-- FAO-GOV-004: true when the user holds an unrevoked grant of the role for
-- the agent. A grant with agent_id NULL covers every agent; when p_agent_id
-- is NULL only such global grants match. Roles other than reader also need
-- an active owner row. For admin and reader only global grants count.
CREATE FUNCTION fao_private.has_role(p_uid uuid, p_role public.fao_app_role, p_agent_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_uid IS NOT NULL
     AND p_role IS NOT NULL
     AND EXISTS (
       SELECT 1
         FROM public.fao_user_roles r
        WHERE r.user_id = p_uid
          AND r.role = p_role
          AND r.revoked_at IS NULL
          AND (
            r.agent_id IS NULL
            OR (p_agent_id IS NOT NULL
                AND p_role NOT IN ('admin'::public.fao_app_role, 'reader'::public.fao_app_role)
                AND r.agent_id = p_agent_id)
          )
     )
     AND (p_role = 'reader'::public.fao_app_role OR fao_private.owner_active(p_uid))
$$;

COMMENT ON FUNCTION fao_private.has_role(uuid, public.fao_app_role, text) IS
  'FAO-GOV-004: unrevoked grant of the role for the agent (NULL agent grant covers all). Non-reader roles need an active owner row; admin and reader count only global grants. Executable by authenticated for RLS.';

-- FAO-GOV-004: true when has_role is true for some role and some agent.
CREATE FUNCTION fao_private.has_any_role(p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_uid IS NOT NULL
     AND EXISTS (
       SELECT 1
         FROM public.fao_user_roles r
        WHERE r.user_id = p_uid
          AND r.revoked_at IS NULL
          AND fao_private.has_role(p_uid, r.role, r.agent_id)
     )
$$;

COMMENT ON FUNCTION fao_private.has_any_role(uuid) IS
  'FAO-GOV-004: true when has_role holds for some role and some agent. Used by member read policies. Executable by authenticated for RLS.';

-- ----------------------------------------------------------------------------
-- Fixed codes, HTTP statuses and messages (FAO-GOV-008). One table, shared by
-- the database, the approval page and the tests. An unknown code raises.
-- ----------------------------------------------------------------------------

CREATE FUNCTION fao_private.code_message(p_code text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_message text;
BEGIN
  v_message := CASE p_code
    WHEN 'OK'                   THEN 'OK'
    WHEN 'NO_SESSION'           THEN 'Sign in to continue.'
    WHEN 'INVALID_INPUT'        THEN 'The request is not valid.'
    WHEN 'NOT_AN_OWNER'         THEN 'Your account is not an active process owner.'
    WHEN 'NOT_AUTHORISED'       THEN 'You are not authorised for this action.'
    WHEN 'SOD_SELF_APPROVAL'    THEN 'You cannot decide a run you started.'
    WHEN 'SELF_CHANGE'          THEN 'You cannot change your own access.'
    WHEN 'NOT_FOUND'            THEN 'Not found.'
    WHEN 'UNKNOWN_AGENT'        THEN 'The agent does not exist.'
    WHEN 'AGENT_NOT_ACTIVE'     THEN 'The agent is not active.'
    WHEN 'BUSY'                 THEN 'Someone else is deciding this request. Try again.'
    WHEN 'NO_RUN_RECORD'        THEN 'This request has no run record.'
    WHEN 'ALREADY_CLAIMED'      THEN 'This run has already started.'
    WHEN 'ALREADY_DECIDED'      THEN 'This request has already been decided.'
    WHEN 'EXPIRED'              THEN 'This request has expired.'
    WHEN 'TOKEN_EXPIRED'        THEN 'The run token has expired.'
    WHEN 'INVALID_TOKEN'        THEN 'The run token is not valid.'
    WHEN 'RATE_LIMITED'         THEN 'Too many runs in the last hour.'
    WHEN 'AUDIT_CHAIN_MISMATCH' THEN 'Recorded, but the run''s ledger chain is incomplete, so it was not committed.'
    WHEN 'UNKNOWN_EXECUTION'    THEN 'No run matches this execution.'
    WHEN 'ALREADY_TERMINAL'     THEN 'The run has already finished.'
    WHEN 'NOT_PENDING'          THEN 'Nothing to send.'
    WHEN 'ALREADY_SENT'         THEN 'Already sent.'
    -- Journal-only codes (journal rows, never RPC results).
    WHEN 'JOURNAL_SUPPRESSED'   THEN 'Further refusals for this caller are not journaled for the rest of this minute.'
    WHEN 'GRANTS_DRIFT'         THEN 'Privileges differ from the allow-list.'
    WHEN 'TEST_CLOCK_SET'       THEN 'A test clock offset is set.'
  END;
  IF v_message IS NULL THEN
    RAISE EXCEPTION 'FAO-GOV-001 unknown code %', coalesce(p_code, '<null>')
      USING ERRCODE = '22023';
  END IF;
  RETURN v_message;
END;
$$;

COMMENT ON FUNCTION fao_private.code_message(text) IS
  'FAO-GOV-008: fixed message for a result or journal code (build spec 2.6). An unknown code raises.';

CREATE FUNCTION fao_private.code_http(p_code text)
RETURNS int
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status int;
BEGIN
  v_status := CASE p_code
    WHEN 'OK'                   THEN 200
    WHEN 'NO_SESSION'           THEN 401
    WHEN 'INVALID_INPUT'        THEN 400
    WHEN 'NOT_AN_OWNER'         THEN 403
    WHEN 'NOT_AUTHORISED'       THEN 403
    WHEN 'SOD_SELF_APPROVAL'    THEN 403
    WHEN 'SELF_CHANGE'          THEN 403
    WHEN 'NOT_FOUND'            THEN 404
    WHEN 'UNKNOWN_AGENT'        THEN 404
    WHEN 'AGENT_NOT_ACTIVE'     THEN 409
    WHEN 'BUSY'                 THEN 409
    WHEN 'NO_RUN_RECORD'        THEN 409
    WHEN 'ALREADY_CLAIMED'      THEN 409
    WHEN 'ALREADY_DECIDED'      THEN 410
    WHEN 'EXPIRED'              THEN 410
    WHEN 'TOKEN_EXPIRED'        THEN 410
    WHEN 'INVALID_TOKEN'        THEN 401
    WHEN 'RATE_LIMITED'         THEN 429
    WHEN 'AUDIT_CHAIN_MISMATCH' THEN 200
    WHEN 'UNKNOWN_EXECUTION'    THEN 200
    WHEN 'ALREADY_TERMINAL'     THEN 200
    WHEN 'NOT_PENDING'          THEN 200
    WHEN 'ALREADY_SENT'         THEN 200
    -- Journal-only codes: 200, unused.
    WHEN 'JOURNAL_SUPPRESSED'   THEN 200
    WHEN 'GRANTS_DRIFT'         THEN 200
    WHEN 'TEST_CLOCK_SET'       THEN 200
  END;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'FAO-GOV-001 unknown code %', coalesce(p_code, '<null>')
      USING ERRCODE = '22023';
  END IF;
  RETURN v_status;
END;
$$;

COMMENT ON FUNCTION fao_private.code_http(text) IS
  'FAO-GOV-008: HTTP status for a result code (build spec 2.6); 200 for journal-only codes. An unknown code raises.';

-- ----------------------------------------------------------------------------
-- Input validation (FAO-GOV-008). Used by every client RPC before any
-- authorization check; a violation is 400 INVALID_INPUT with a fixed message.
-- ----------------------------------------------------------------------------

-- Not NULL, length within bounds, no control characters other than newline
-- and tab.
CREATE FUNCTION fao_private.text_ok(p_value text, p_min int, p_max int)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(
    p_value IS NOT NULL
    AND length(p_value) BETWEEN p_min AND p_max
    AND translate(p_value, E'\n\t', '') !~ '[[:cntrl:]]',
    false)
$$;

COMMENT ON FUNCTION fao_private.text_ok(text, int, int) IS
  'FAO-GOV-008: input check for free text: not NULL, length within bounds, no control characters other than newline and tab.';

-- The id when the text is 1 to 12 ASCII digits with a value of at least 1,
-- else NULL. The cast runs only after the pattern matched, so no cast error
-- can occur.
CREATE FUNCTION fao_private.parse_id(p_value text)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id bigint;
BEGIN
  IF p_value IS NULL OR p_value !~ '^[0-9]{1,12}$' THEN
    RETURN NULL;
  END IF;
  v_id := p_value::bigint;
  IF v_id < 1 THEN
    RETURN NULL;
  END IF;
  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION fao_private.parse_id(text) IS
  'FAO-GOV-008: id parsing for client RPCs: 1 to 12 digits and at least 1, else NULL.';

-- IC-18 (FAO-GOV-008): the body of a client RPC. Every client RPC takes one
-- unnamed json parameter, so PostgREST passes the request body unchanged and
-- a \u0000 escape reaches the function instead of failing in PostgREST. This
-- helper decodes it once and never raises. The first failure in this order
-- sets the reason:
--   media_type     a Content-Type other than none or application/json (IC-14,
--                  moved here so it covers all nine; unparseable headers fail
--                  closed)
--   undecodable    the body does not cast to jsonb (\u0000 anywhere, keys
--                  included; bad escapes; numeric overflow)
--   not_object     SQL NULL, an array or a scalar
--   duplicate_key  a key repeated (json keeps both, jsonb keeps the last)
--   unknown_key    a key outside p_required and p_optional (case-sensitive)
--   missing_key    a p_required key absent
--   not_string     a value that is not a JSON string or null
-- Returns {ok, args, note}. ok: args is p_optional merged with the body (every
-- allowed key present, defaults filled), note {}. Not ok: args is the decoded
-- object when there is one, else {}; note {invalid_body: <reason>}. The field
-- rules (text_ok, patterns, parse_id) stay in each RPC.
CREATE FUNCTION fao_private.client_args(p_body json, p_required text[], p_optional jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ctype   text;
  v_obj     jsonb;
  v_allowed text[];
  v_reason  text;
BEGIN
  BEGIN
    v_ctype := lower(btrim(split_part(coalesce(
                 nullif(current_setting('request.headers', true), '')::jsonb->>'content-type', ''), ';', 1)));
  EXCEPTION WHEN others THEN
    v_ctype := 'unreadable';
  END;
  IF v_ctype IS NULL OR v_ctype NOT IN ('', 'application/json') THEN
    v_reason := 'media_type';
  END IF;

  IF v_reason IS NULL THEN
    BEGIN
      v_obj := p_body::jsonb;
    EXCEPTION WHEN others THEN
      v_reason := 'undecodable';
      v_obj := NULL;
    END;
  END IF;

  IF v_reason IS NULL AND (v_obj IS NULL OR jsonb_typeof(v_obj) <> 'object') THEN
    v_reason := 'not_object';
    v_obj := NULL;
  END IF;

  IF v_reason IS NULL THEN
    v_allowed := coalesce(p_required, ARRAY[]::text[])
                 || ARRAY(SELECT k FROM jsonb_object_keys(coalesce(p_optional, '{}'::jsonb)) AS k);
    IF (SELECT count(*) FROM json_object_keys(p_body)) <> (SELECT count(*) FROM jsonb_object_keys(v_obj)) THEN
      v_reason := 'duplicate_key';
    ELSIF EXISTS (SELECT 1 FROM jsonb_object_keys(v_obj) AS k WHERE k <> ALL (v_allowed)) THEN
      v_reason := 'unknown_key';
    ELSIF EXISTS (SELECT 1 FROM unnest(coalesce(p_required, ARRAY[]::text[])) AS r WHERE NOT v_obj ? r) THEN
      v_reason := 'missing_key';
    ELSIF EXISTS (SELECT 1 FROM jsonb_each(v_obj) AS e WHERE jsonb_typeof(e.value) NOT IN ('string', 'null')) THEN
      v_reason := 'not_string';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',   v_reason IS NULL,
    'args', CASE WHEN v_reason IS NULL THEN coalesce(p_optional, '{}'::jsonb) || v_obj
                 ELSE coalesce(v_obj, '{}'::jsonb) END,
    'note', CASE WHEN v_reason IS NULL THEN '{}'::jsonb
                 ELSE jsonb_build_object('invalid_body', v_reason) END);
EXCEPTION WHEN others THEN
  -- Never raises: anything unexpected refuses the body.
  RETURN jsonb_build_object('ok', false, 'args', '{}'::jsonb,
                            'note', jsonb_build_object('invalid_body', 'undecodable'));
END;
$$;

COMMENT ON FUNCTION fao_private.client_args(json, text[], jsonb) IS
  'FAO-GOV-008 (IC-18): decodes the one json body of a client RPC and never raises. Returns {ok, args, note}; refuses (note invalid_body) media_type, undecodable (a \u0000 escape anywhere), not_object, duplicate_key, unknown_key, missing_key, not_string; on success args is p_optional merged with the body.';

-- ----------------------------------------------------------------------------
-- Result envelope (FAO-GOV-008)
-- ----------------------------------------------------------------------------

-- Sets the HTTP status PostgREST returns for this request (transaction-local).
CREATE FUNCTION fao_private.set_http_status(p_status int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM set_config('response.status', p_status::text, true);
END;
$$;

COMMENT ON FUNCTION fao_private.set_http_status(int) IS
  'FAO-GOV-008: sets response.status (transaction-local) so PostgREST returns the HTTP status of the result code.';

-- ----------------------------------------------------------------------------
-- Refusal journal (FAO-GOV-001). Refusals returned by FinAgent RPCs are
-- journaled in the same transaction as the refusal. A per-actor cap per
-- minute bounds the journal; the first refusal over the cap writes one
-- JOURNAL_SUPPRESSED row for that bucket. Every attempt is still refused.
-- The sweep's GRANTS_DRIFT and TEST_CLOCK_SET rows are exempt from the cap
-- and do not count toward it (FAO-GOV-001, fix round 1 A3).
-- ----------------------------------------------------------------------------

CREATE FUNCTION fao_private.journal_allowed(p_actor uuid, p_db_role text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cap int;
  v_n   int;
BEGIN
  -- One bucket per actor (or no session) and database role; serialize
  -- concurrent refusals in the same bucket so the count is exact.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('fao_journal:' || coalesce(p_actor::text, '-') || ':' || coalesce(p_db_role, '-')));

  BEGIN
    v_cap := (SELECT s.value::int FROM public.fao_settings s WHERE s.key = 'journal_cap_per_minute');
  EXCEPTION WHEN others THEN
    v_cap := NULL;  -- a non-integer setting falls back to the default
  END;
  v_cap := coalesce(v_cap, 20);

  SELECT count(*)
    INTO v_n
    FROM public.fao_refusal_journal j
   WHERE j.actor_uid IS NOT DISTINCT FROM p_actor
     AND j.db_role = p_db_role
     AND j.code NOT IN ('JOURNAL_SUPPRESSED', 'GRANTS_DRIFT', 'TEST_CLOCK_SET')
     AND j.at > clock_timestamp() - interval '1 minute';

  IF v_n < v_cap THEN
    RETURN true;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.fao_refusal_journal j
     WHERE j.actor_uid IS NOT DISTINCT FROM p_actor
       AND j.db_role = p_db_role
       AND j.code = 'JOURNAL_SUPPRESSED'
       AND j.at > clock_timestamp() - interval '1 minute'
  ) THEN
    INSERT INTO public.fao_refusal_journal
      (actor_uid, db_role, session_role, entry_point, target_table, target_key, attempted, code, message)
    VALUES
      (p_actor, p_db_role, session_user::text, 'journal', NULL, NULL, '{}'::jsonb,
       'JOURNAL_SUPPRESSED', fao_private.code_message('JOURNAL_SUPPRESSED'));
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION fao_private.journal_allowed(uuid, text) IS
  'FAO-GOV-001: refusal journal flood cap per actor and database role per minute (setting journal_cap_per_minute, default 20). Writes one JOURNAL_SUPPRESSED row per bucket when the cap is first exceeded. GRANTS_DRIFT and TEST_CLOCK_SET rows do not count toward the cap.';

CREATE FUNCTION fao_private.journal_refusal(
  p_entry_point  text,
  p_target_table text,
  p_target_key   text,
  p_attempted    jsonb,
  p_code         text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor    uuid;
  v_role     text;
  v_message  text;
  v_attempt  jsonb;
  v_id       bigint;
BEGIN
  -- Validate the code first: an unknown code raises before anything is
  -- written.
  v_message := fao_private.code_message(p_code);

  -- Identity comes only from the session (request.jwt.claims). A claim that
  -- does not parse as a UUID is journaled as no session.
  BEGIN
    v_actor := auth.uid();
  EXCEPTION WHEN others THEN
    v_actor := NULL;
  END;
  v_role := fao_private.caller_role();

  -- The sweep's GRANTS_DRIFT and TEST_CLOCK_SET rows share the fao_workflow
  -- bucket with every claim refusal, so the flood cap could suppress them.
  -- They are exempt from the cap (and not counted toward it); the sweep
  -- itself writes each at most once per 24 hours per distinct diff_md5.
  IF p_code NOT IN ('GRANTS_DRIFT', 'TEST_CLOCK_SET')
     AND NOT fao_private.journal_allowed(v_actor, v_role) THEN
    RETURN NULL;
  END IF;

  v_attempt := coalesce(p_attempted, '{}'::jsonb);
  IF length(v_attempt::text) > 4000 THEN
    -- IC-18: the body refusal reason survives the cut, so a journal row still
    -- says which body rule fired.
    v_attempt := jsonb_build_object('truncated', left(v_attempt::text, 4000))
                 || CASE WHEN jsonb_typeof(p_attempted -> 'invalid_body') = 'string'
                         THEN jsonb_build_object('invalid_body', left(p_attempted ->> 'invalid_body', 64))
                         ELSE '{}'::jsonb END;
  END IF;

  INSERT INTO public.fao_refusal_journal
    (actor_uid, db_role, session_role, entry_point, target_table, target_key, attempted, code, message)
  VALUES
    (v_actor, v_role, session_user::text, p_entry_point, p_target_table, p_target_key, v_attempt,
     p_code, v_message)
  RETURNING refusal_id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION fao_private.journal_refusal(text, text, text, jsonb, text) IS
  'FAO-GOV-001: journals one refusal in the current transaction (actor from auth.uid(), role, session role, target, attempt, code, fixed message). Returns the refusal_id, or NULL when the flood cap applies. GRANTS_DRIFT and TEST_CLOCK_SET (sweep) are exempt from the cap.';

-- The ok:false envelope. Journals when p_journal, sets the HTTP status from
-- the code, and returns the fixed message for the code.
CREATE FUNCTION fao_private.refuse(
  p_entry_point  text,
  p_target_table text,
  p_target_key   text,
  p_attempted    jsonb,
  p_code         text,
  p_journal      boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ref     bigint;
  v_status  int;
  v_message text;
BEGIN
  v_status  := fao_private.code_http(p_code);
  v_message := fao_private.code_message(p_code);
  v_ref := CASE WHEN p_journal
                THEN fao_private.journal_refusal(p_entry_point, p_target_table, p_target_key, p_attempted, p_code)
           END;
  PERFORM fao_private.set_http_status(v_status);
  RETURN jsonb_build_object(
    'ok',          false,
    'code',        p_code,
    'http_status', v_status,
    'message',     v_message,
    'ref',         v_ref
  );
END;
$$;

COMMENT ON FUNCTION fao_private.refuse(text, text, text, jsonb, text, boolean) IS
  'FAO-GOV-008: refusal envelope {ok:false, code, http_status, message, ref}. Journals the refusal (FAO-GOV-001) when p_journal and sets the HTTP status.';

-- The ok:true envelope merged with the function's own fields; sets the HTTP
-- status from the code (200 for every ok:true code).
CREATE FUNCTION fao_private.ok_result(p_fields jsonb DEFAULT '{}'::jsonb, p_code text DEFAULT 'OK')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status int;
BEGIN
  v_status := fao_private.code_http(p_code);
  PERFORM fao_private.set_http_status(v_status);
  RETURN jsonb_build_object(
    'ok',          true,
    'code',        p_code,
    'http_status', v_status,
    'message',     fao_private.code_message(p_code),
    'ref',         NULL
  ) || coalesce(p_fields, '{}'::jsonb);
END;
$$;

COMMENT ON FUNCTION fao_private.ok_result(jsonb, text) IS
  'FAO-GOV-008: success envelope {ok:true, code, http_status, message, ref:null} merged with the function fields; sets the HTTP status.';

-- ----------------------------------------------------------------------------
-- Generic trigger functions (SECURITY INVOKER, no grants)
-- ----------------------------------------------------------------------------

-- FAO-GOV-001: BEFORE TRUNCATE FOR EACH STATEMENT. Refuses TRUNCATE for every
-- role, the table owner included, unless the owner disables the trigger.
CREATE FUNCTION fao_private.deny_truncate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'FAO-GOV-001: TRUNCATE is not permitted on %', TG_TABLE_NAME
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION fao_private.deny_truncate() IS
  'FAO-GOV-001: statement trigger that refuses TRUNCATE on FinAgent tables for every role, the owner included.';

-- FAO-GOV-001: BEFORE UPDATE OR DELETE FOR EACH ROW on append-only tables.
CREATE FUNCTION fao_private.deny_row_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'FAO-GOV-001: % is append-only', TG_TABLE_NAME
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION fao_private.deny_row_mutation() IS
  'FAO-GOV-001: row trigger that refuses UPDATE and DELETE on append-only evidence tables.';

-- FAO-GOV-002: BEFORE INSERT OR UPDATE OR DELETE FOR EACH STATEMENT on
-- configuration tables. A change needs a reason in fao.change_reason.
CREATE FUNCTION fao_private.require_change_reason()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF coalesce(current_setting('fao.change_reason', true), '') = '' THEN
    RAISE EXCEPTION 'FAO-GOV-002: a change reason is required (set fao.change_reason)'
      USING ERRCODE = '42501';
  END IF;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION fao_private.require_change_reason() IS
  'FAO-GOV-002: statement trigger that refuses a change to a configuration table unless fao.change_reason is set.';

-- BEFORE UPDATE FOR EACH ROW: keeps updated_at current without the caller
-- supplying it.
CREATE FUNCTION fao_private.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fao_private.touch_updated_at() IS
  'FAO-GOV-002: row trigger that sets updated_at on every update of a configuration table.';

-- FAO-GOV-001: AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW on configuration
-- tables. Writes the before and after images with the actor, roles,
-- transaction id and change reason. Trigger arguments name the key columns.
-- reason is NOT NULL in fao_admin_audit, so a change with no reason cannot be
-- audited and fails (require_change_reason refuses it first).
CREATE FUNCTION fao_private.admin_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_row   jsonb;
  v_key   jsonb;
  v_actor uuid;
  i       int;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;

  IF TG_NARGS > 0 THEN
    v_key := '{}'::jsonb;
    FOR i IN 0 .. TG_NARGS - 1 LOOP
      v_key := v_key || jsonb_build_object(TG_ARGV[i], v_row -> TG_ARGV[i]);
    END LOOP;
  END IF;

  BEGIN
    v_actor := auth.uid();
  EXCEPTION WHEN others THEN
    v_actor := NULL;
  END;

  INSERT INTO public.fao_admin_audit
    (table_name, op, row_key, old_row, new_row, actor_uid, db_role, session_role, txid, reason)
  VALUES (
    TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
    TG_OP,
    v_key,
    CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END,
    v_actor,
    fao_private.caller_role(),
    session_user::text,
    txid_current(),
    current_setting('fao.change_reason', true)
  );

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION fao_private.admin_audit() IS
  'FAO-GOV-001: row trigger that writes public.fao_admin_audit (before and after images, actor, roles, txid, change reason) for every change to a configuration table.';

-- ----------------------------------------------------------------------------
-- Attach the append-only pair to the three evidence tables from 0010. Every
-- other attachment is in 0013.
-- ----------------------------------------------------------------------------
CREATE TRIGGER fao_refusal_journal_append_only
  BEFORE UPDATE OR DELETE ON public.fao_refusal_journal
  FOR EACH ROW EXECUTE FUNCTION fao_private.deny_row_mutation();
CREATE TRIGGER fao_refusal_journal_deny_truncate
  BEFORE TRUNCATE ON public.fao_refusal_journal
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();

CREATE TRIGGER fao_admin_audit_append_only
  BEFORE UPDATE OR DELETE ON public.fao_admin_audit
  FOR EACH ROW EXECUTE FUNCTION fao_private.deny_row_mutation();
CREATE TRIGGER fao_admin_audit_deny_truncate
  BEFORE TRUNCATE ON public.fao_admin_audit
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();

CREATE TRIGGER fao_notifications_append_only
  BEFORE UPDATE OR DELETE ON public.fao_notifications
  FOR EACH ROW EXECUTE FUNCTION fao_private.deny_row_mutation();
CREATE TRIGGER fao_notifications_deny_truncate
  BEFORE TRUNCATE ON public.fao_notifications
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();

-- ----------------------------------------------------------------------------
-- Revoke every function in this file from every client role. Functions are
-- executable by PUBLIC by default; nothing may rely on that. 0017 grants
-- EXECUTE on has_role and has_any_role to authenticated only.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION fao_private.caller_role()                                          FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.clock()                                                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.owner_active(uuid)                                     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.has_role(uuid, public.fao_app_role, text)              FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.has_any_role(uuid)                                     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.code_message(text)                                     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.code_http(text)                                        FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.text_ok(text, int, int)                                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.parse_id(text)                                         FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.client_args(json, text[], jsonb)                       FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.set_http_status(int)                                   FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.journal_allowed(uuid, text)                            FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.journal_refusal(text, text, text, jsonb, text)         FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.refuse(text, text, text, jsonb, text, boolean)         FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.ok_result(jsonb, text)                                 FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.deny_truncate()                                        FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.deny_row_mutation()                                    FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.require_change_reason()                                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.touch_updated_at()                                     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.admin_audit()                                          FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
