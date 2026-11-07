-- ============================================================================
-- FinAgent OS - pgTAP helpers (schema tests), local test database only
-- ============================================================================
-- Installed by scripts/local-setup.mjs after every local reset. Never part of
-- a migration and never applied to a hosted project. The grants test ignores
-- schema tests.
--
-- Controls exercised through these helpers:
--   FAO-GOV-001  ledger append and immutability
--   FAO-GOV-004  identity from the session only, segregation of duties
--   FAO-GOV-008  run start, claim and finalize
--
-- Identity helpers switch role and request claims for the current
-- transaction, exactly as PostgREST does for a signed-in caller:
--   tests.as_user(email)      authenticated, claims {sub, role, aal, email}
--   tests.as_uid(uuid)        the same for a synthetic id
--   tests.as_anon()           anon, no subject
--   tests.as_role(role)       fao_workflow or service_role, claims cleared
--   tests.as_owner()          back to the session user, claims cleared
-- Probe helpers run one statement as a caller and always come back as the
-- owner, so pgTAP assertions run as the owner:
--   tests.do_as(who, sql)       raises through (use inside throws_ok)
--   tests.sqlstate_as(who, sql) '00000' or the SQLSTATE raised
--   tests.error_as(who, sql)    NULL or '<SQLSTATE> <message>'
--   tests.jsonb_as(who, sql)    the jsonb result, or {error, message}
--   tests.value_as(who, sql)    the first column as text (raises through)
-- `who` is an email, 'uid:<uuid>', 'anon', 'fao_workflow', 'service_role'
-- or 'owner'.
-- Run helpers: tests.set_clock, tests.make_run, tests.make_request,
-- tests.journal_count and small builders for Writer-shaped events.
-- IC-18: every client RPC takes one unnamed json body. The helpers build it
-- with json_build_object under today's argument names (a NULL value becomes
-- JSON null, the old explicit NULL); tests.rpc_body(who, rpc, body) sends a
-- raw json body for the body rules of fao_private.client_args.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS tests;

-- --- Identity ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION tests.uid(p_email text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.id FROM auth.users u WHERE lower(u.email) = lower(p_email) LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION tests.as_owner()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE NONE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', '', true);
END;
$$;

CREATE OR REPLACE FUNCTION tests.as_uid(p_uid uuid, p_email text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub', p_uid::text, 'role', 'authenticated', 'aal', 'aal1',
                       'email', coalesce(p_email, p_uid::text || '@synthetic.test'))::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END;
$$;

CREATE OR REPLACE FUNCTION tests.as_user(p_email text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_uid uuid := tests.uid(p_email);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'tests.as_user: no auth user %', p_email;
  END IF;
  PERFORM tests.as_uid(v_uid, p_email);
END;
$$;

CREATE OR REPLACE FUNCTION tests.as_anon()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'anon')::text, true);
  PERFORM set_config('request.jwt.claim.role', 'anon', true);
  EXECUTE 'SET LOCAL ROLE anon';
END;
$$;

CREATE OR REPLACE FUNCTION tests.as_role(p_role text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_role NOT IN ('fao_workflow', 'service_role') THEN
    RAISE EXCEPTION 'tests.as_role: role % is not fao_workflow or service_role', p_role;
  END IF;
  PERFORM tests.as_owner();
  EXECUTE format('SET LOCAL ROLE %I', p_role);
END;
$$;

CREATE OR REPLACE FUNCTION tests.use(p_who text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_who IS NULL OR p_who = 'owner' THEN
    PERFORM tests.as_owner();
  ELSIF p_who = 'anon' THEN
    PERFORM tests.as_anon();
  ELSIF p_who IN ('fao_workflow', 'service_role') THEN
    PERFORM tests.as_role(p_who);
  ELSIF p_who LIKE 'uid:%' THEN
    PERFORM tests.as_uid(substr(p_who, 5)::uuid);
  ELSIF p_who LIKE '%@%' THEN
    PERFORM tests.as_user(p_who);
  ELSE
    RAISE EXCEPTION 'tests.use: unknown caller %', p_who;
  END IF;
END;
$$;

-- --- Probes ------------------------------------------------------------------

CREATE OR REPLACE FUNCTION tests.do_as(p_who text, p_sql text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM tests.use(p_who);
  EXECUTE p_sql;
  PERFORM tests.as_owner();
END;
$$;

CREATE OR REPLACE FUNCTION tests.sqlstate_as(p_who text, p_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_state text := '00000';
BEGIN
  BEGIN
    PERFORM tests.use(p_who);
    EXECUTE p_sql;
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v_state := SQLSTATE;
  END;
  PERFORM tests.as_owner();
  RETURN v_state;
END;
$$;

CREATE OR REPLACE FUNCTION tests.error_as(p_who text, p_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_err text := NULL;
BEGIN
  BEGIN
    PERFORM tests.use(p_who);
    EXECUTE p_sql;
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  PERFORM tests.as_owner();
  RETURN v_err;
END;
$$;

CREATE OR REPLACE FUNCTION tests.jsonb_as(p_who text, p_sql text)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  BEGIN
    PERFORM tests.use(p_who);
    EXECUTE p_sql INTO v;
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.value_as(p_who text, p_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v text;
BEGIN
  PERFORM tests.use(p_who);
  EXECUTE p_sql INTO v;
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

-- --- Clock and counters -------------------------------------------------------

CREATE OR REPLACE FUNCTION tests.set_clock(p_seconds int)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap tests.set_clock', true);
  INSERT INTO fao_private.test_clock (id, offset_seconds, set_at, reason)
  VALUES (1, p_seconds, now(), 'pgtap tests.set_clock')
  ON CONFLICT (id) DO UPDATE
    SET offset_seconds = EXCLUDED.offset_seconds, set_at = EXCLUDED.set_at, reason = EXCLUDED.reason;
END;
$$;

CREATE OR REPLACE FUNCTION tests.journal_count(p_code text)
RETURNS bigint
LANGUAGE sql
AS $$
  SELECT count(*) FROM public.fao_refusal_journal j WHERE j.code = p_code;
$$;

CREATE OR REPLACE FUNCTION tests.journal_total()
RETURNS bigint
LANGUAGE sql
AS $$
  SELECT count(*) FROM public.fao_refusal_journal;
$$;

CREATE OR REPLACE FUNCTION tests.ledger_count(p_correlation_id uuid, p_event_type text DEFAULT NULL)
RETURNS bigint
LANGUAGE sql
AS $$
  SELECT count(*) FROM public.shadow_ledger l
  WHERE l.correlation_id = p_correlation_id
    AND (p_event_type IS NULL OR l.inputs->>'event_type' = p_event_type);
$$;

CREATE OR REPLACE FUNCTION tests.run_state(p_correlation_id uuid)
RETURNS text
LANGUAGE sql
AS $$
  SELECT r.state::text FROM public.run_invocations r WHERE r.correlation_id = p_correlation_id;
$$;

CREATE OR REPLACE FUNCTION tests.new_key()
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
  SELECT 'pgtap_' || replace(gen_random_uuid()::text, '-', '');
$$;

-- --- Writer-shaped events -----------------------------------------------------

CREATE OR REPLACE FUNCTION tests.started_event(p_correlation_id uuid, p_assets text[])
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'correlation_id', p_correlation_id,
    'event_type', 'STARTED',
    'inputs', jsonb_build_object(
      'asset_scope', to_jsonb(p_assets),
      'asset_count', coalesce(array_length(p_assets, 1), 0),
      'wallet_source', 'pgtap',
      'ledger_source', 'pgtap',
      'fixture_provenance', '{}'::jsonb),
    'policy_outcome', 'ALLOW',
    'policy_rationale', 'pgtap STARTED',
    'status', 'SUCCESS');
$$;

CREATE OR REPLACE FUNCTION tests.asset_event(p_correlation_id uuid, p_asset text,
                                             p_outcome text DEFAULT 'ALLOW', p_sub_tier text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT jsonb_build_object(
    'correlation_id', p_correlation_id,
    'event_type', 'ASSET_RECONCILED',
    'inputs', jsonb_build_object(
      'asset', p_asset,
      'wallet', 100,
      'ledger', 100,
      'ratio', CASE WHEN p_outcome IN ('ALLOW', 'ALLOW_WITH_OBLIGATIONS') THEN to_jsonb(1.0)
                    WHEN p_outcome = 'REQUIRE_HUMAN' THEN to_jsonb(0.95)
                    ELSE 'null'::jsonb END,
      'discrepancy', 0,
      'band_status', CASE p_outcome WHEN 'ALLOW' THEN 'IN_BAND' WHEN 'ALLOW_WITH_OBLIGATIONS' THEN 'BELOW_BAND_LOWER'
                                    WHEN 'REQUIRE_HUMAN' THEN 'BELOW_FLOOR' ELSE 'INVALID_INPUT' END,
      'threshold', '{}'::jsonb,
      'input_problem', CASE WHEN p_outcome IN ('DENY', 'BLOCKED') THEN 'pgtap' END),
    'policy_outcome', p_outcome,
    'policy_sub_tier', p_sub_tier,
    'policy_rationale', 'pgtap ' || p_asset || ' ' || p_outcome,
    'obligations', CASE WHEN p_outcome = 'ALLOW_WITH_OBLIGATIONS' THEN '["weekly_review_required"]'::jsonb ELSE '[]'::jsonb END,
    'status', 'SUCCESS',
    'hitl_status', CASE WHEN p_outcome IN ('REQUIRE_HUMAN', 'DENY', 'BLOCKED') THEN 'PENDING' ELSE 'NOT_REQUIRED' END);
$$;

-- --- Runs ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION tests.start_run(p_email text, p_agent_id text DEFAULT 'fao_reserve_recon_v1',
                                           p_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
  v_key text := coalesce(p_key, tests.new_key());  -- built as the owner, before the switch
BEGIN
  PERFORM tests.as_user(p_email);
  v := public.fao_run_start(json_build_object('p_agent_id', p_agent_id, 'p_reason', 'pgtap run', 'p_idempotency_key', v_key, 'p_invoked_via', 'test'));
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

-- Fix round 2 R08: fao_run_claim takes the agent the calling workflow serves.
-- The helpers stand for that agent's own workflow, so they pass the agent of
-- the run the token was issued for (looked up as the owner by the token hash;
-- an unknown or malformed token gets the flagship agent). A test that needs
-- another workflow's agent uses tests.claim_agent_raw.
CREATE OR REPLACE FUNCTION tests.token_agent(p_token text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    (SELECT r.agent_id FROM fao_private.run_tokens t
       JOIN public.run_invocations r ON r.correlation_id = t.correlation_id
      WHERE t.token_hash = extensions.digest(p_token, 'sha256')),
    'fao_reserve_recon_v1');
$$;

CREATE OR REPLACE FUNCTION tests.claim(p_token text, p_exec_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
  v_agent text := tests.token_agent(p_token);  -- looked up as the owner, before the switch
BEGIN
  PERFORM tests.as_role('fao_workflow');
  v := public.fao_run_claim(p_token, coalesce(p_exec_id, 'pgtap-' || left(replace(gen_random_uuid()::text, '-', ''), 24)), v_agent);
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.append(p_events jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM tests.as_role('fao_workflow');
  v := public.fao_ledger_append_batch(p_events);
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.finalize(p_correlation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM tests.as_role('fao_workflow');
  v := public.fao_run_finalize(p_correlation_id);
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.decide(p_email text, p_hitl_id bigint, p_decision text DEFAULT 'APPROVED',
                                        p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM tests.as_user(p_email);
  v := public.fao_hitl_decide(json_build_object('p_hitl_id', p_hitl_id::text, 'p_decision', p_decision, 'p_notes', p_notes));
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.sweep()
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM tests.as_role('fao_workflow');
  v := public.fao_maintenance_sweep();
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

-- Start, claim and STARTED through the RPCs; returns the correlation id.
CREATE OR REPLACE FUNCTION tests.make_run(p_invoker_email text, p_assets text[],
                                          p_agent_id text DEFAULT 'fao_reserve_recon_v1')
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_start jsonb;
  v_claim jsonb;
  v_corr uuid;
BEGIN
  v_start := tests.start_run(p_invoker_email, p_agent_id);
  IF coalesce((v_start->>'ok')::boolean, false) IS NOT TRUE OR v_start->>'run_token' IS NULL THEN
    RAISE EXCEPTION 'tests.make_run: run start refused: %', v_start;
  END IF;
  v_corr := (v_start->>'correlation_id')::uuid;
  v_claim := tests.claim(v_start->>'run_token');
  IF coalesce((v_claim->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'tests.make_run: claim refused: %', v_claim;
  END IF;
  PERFORM tests.append(jsonb_build_array(tests.started_event(v_corr, p_assets)));
  RETURN v_corr;
END;
$$;

-- A run with one REQUIRE_HUMAN asset (plus any ALLOW assets given) taken to
-- AWAITING_HITL through fao_run_finalize; returns the hitl id.
CREATE OR REPLACE FUNCTION tests.make_request(p_invoker_email text, p_allow_assets text[] DEFAULT ARRAY[]::text[])
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_corr uuid;
  v_events jsonb := '[]'::jsonb;
  v_fin jsonb;
  a text;
BEGIN
  v_corr := tests.make_run(p_invoker_email, ARRAY['USDT'] || p_allow_assets);
  v_events := v_events || jsonb_build_array(tests.asset_event(v_corr, 'USDT', 'REQUIRE_HUMAN', 'STANDARD'));
  FOREACH a IN ARRAY p_allow_assets LOOP
    v_events := v_events || jsonb_build_array(tests.asset_event(v_corr, a, 'ALLOW', NULL));
  END LOOP;
  PERFORM tests.append(v_events);
  v_fin := tests.finalize(v_corr);
  IF coalesce((v_fin->>'hitl_required')::boolean, false) IS NOT TRUE OR v_fin->>'hitl_id' IS NULL THEN
    RAISE EXCEPTION 'tests.make_request: finalize did not open a request: %', v_fin;
  END IF;
  RETURN (v_fin->>'hitl_id')::bigint;
END;
$$;

CREATE OR REPLACE FUNCTION tests.request_corr(p_hitl_id bigint)
RETURNS uuid
LANGUAGE sql
AS $$
  SELECT h.correlation_id FROM public.hitl_queue h WHERE h.hitl_id = p_hitl_id;
$$;

-- Raw client RPC calls as any caller; errors come back as {error, message}.
CREATE OR REPLACE FUNCTION tests.decide_raw(p_who text, p_hitl_id text, p_decision text, p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  BEGIN
    PERFORM tests.use(p_who);
    v := public.fao_hitl_decide(json_build_object('p_hitl_id', p_hitl_id, 'p_decision', p_decision, 'p_notes', p_notes));
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.get_raw(p_who text, p_hitl_id text)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  BEGIN
    PERFORM tests.use(p_who);
    v := public.fao_hitl_get(json_build_object('p_hitl_id', p_hitl_id));
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.start_raw(p_who text, p_agent_id text, p_reason text, p_key text, p_via text DEFAULT 'test')
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  BEGIN
    PERFORM tests.use(p_who);
    v := public.fao_run_start(json_build_object('p_agent_id', p_agent_id, 'p_reason', p_reason, 'p_idempotency_key', p_key, 'p_invoked_via', p_via));
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

-- IC-18 (FAO-GOV-008): a client RPC called with a raw JSON body, as PostgREST
-- passes it. The body stays typed json all the way, so a '\u0000' escape, a
-- repeated key or a non-object reaches fao_private.client_args exactly as
-- written. Only the nine client RPCs are accepted; anything else raises.
CREATE OR REPLACE FUNCTION tests.rpc_body(p_who text, p_rpc text, p_body json)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  IF p_rpc IS NULL OR p_rpc NOT IN ('fao_whoami', 'fao_run_start', 'fao_hitl_get', 'fao_hitl_decide', 'fao_ledger_correct',
                                    'fao_admin_set_threshold', 'fao_admin_set_agent', 'fao_admin_set_role',
                                    'fao_admin_set_owner_active') THEN
    RAISE EXCEPTION 'tests.rpc_body: % is not a client RPC', p_rpc;
  END IF;
  BEGIN
    PERFORM tests.use(p_who);
    EXECUTE format('SELECT public.%I($1)', p_rpc) INTO v USING p_body;
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.claim_agent_raw(p_token text, p_exec_id text, p_agent_id text)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v jsonb;
BEGIN
  BEGIN
    PERFORM tests.as_role('fao_workflow');
    v := public.fao_run_claim(p_token, p_exec_id, p_agent_id);
    PERFORM tests.as_owner();
  EXCEPTION WHEN OTHERS THEN
    v := jsonb_build_object('error', SQLSTATE, 'message', SQLERRM);
  END;
  PERFORM tests.as_owner();
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION tests.claim_raw(p_token text, p_exec_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT tests.claim_agent_raw(p_token, p_exec_id, tests.token_agent(p_token));
$$;

-- Owner-side helper: the newest journal row.
CREATE OR REPLACE FUNCTION tests.journal_row(p_ref bigint)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT to_jsonb(j) FROM public.fao_refusal_journal j WHERE j.refusal_id = p_ref;
$$;

-- --- Grants on schema tests ------------------------------------------------------
-- FAO-GOV-015: every helper is called by the owner. While a probe runs, the
-- switched role (anon, authenticated, service_role or fao_workflow) only has
-- to resolve schema tests and call tests.as_owner() to come back, so that is
-- the only EXECUTE it gets. PUBLIC loses the default EXECUTE, so no client
-- role can reach tests.do_as (any SQL as any role), tests.uid (email to id)
-- or any other helper, even if schema tests were ever exposed to an API.
-- Re-running this file re-applies the same grants (CREATE OR REPLACE keeps
-- the ACL of an existing function; a new one starts with PUBLIC EXECUTE and
-- loses it here).

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA tests FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
GRANT USAGE ON SCHEMA tests TO anon, authenticated, service_role, fao_workflow;
GRANT EXECUTE ON FUNCTION tests.as_owner() TO anon, authenticated, service_role, fao_workflow;
