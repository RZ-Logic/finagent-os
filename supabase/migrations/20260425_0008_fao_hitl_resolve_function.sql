-- ============================================================================
-- FinAgent OS — Migration 0008: fao_hitl_resolve() function
-- ============================================================================
-- The HITL Approval Handler workflow's database-layer entry point.
-- Resolves a hitl_queue row from PENDING to APPROVED/REJECTED, with the
-- segregation-of-duties trigger (Migration 0005b) firing correctly on
-- self-approval attempts.
--
-- THE AUTH.UID SPOOFING PROBLEM
-- -----------------------------------------------------------------------------
-- The hitl_queue_sod_guard trigger reads auth.uid() and compares it to
-- OLD.agent_invoker_id. If they match, it raises FAO-GOV-004. But:
--
--   - auth.uid() reads from JWT claims on the current Postgres session
--   - n8n connects as `postgres` superuser with no JWT
--   - so auth.uid() returns NULL
--   - the trigger interprets NULL as "service_role administrative bypass"
--     and silently allows the update
--
-- This is intentional in the trigger — administrative overrides need to
-- exist (e.g. cancelling a hung HITL). But in the demo, every approval
-- comes through n8n as superuser, so the trigger never fires and the
-- SoD enforcement is theatre.
--
-- THE FIX: TRANSACTION-LOCAL JWT CLAIM SPOOFING
-- -----------------------------------------------------------------------------
-- Postgres exposes set_config(name, value, is_local) which can set any
-- session/transaction variable. Supabase's auth.uid() is implemented as
-- a SQL function that reads from request.jwt.claims:
--
--   CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
--     SELECT coalesce(
--       nullif(current_setting('request.jwt.claim.sub', true), ''),
--       (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
--     )::uuid
--   $$;
--
-- By calling set_config('request.jwt.claims', '{"sub":"<uuid>","role":"authenticated"}', true)
-- inside this function, we make auth.uid() return the approver's UUID
-- for the duration of this transaction. The trigger then sees an
-- authenticated identity and applies the SoD check correctly. The third
-- arg `true` makes the setting transaction-local — it does not leak to
-- subsequent queries on the same connection.
--
-- HONEST GAP NAMING (architectural disclosure)
-- -----------------------------------------------------------------------------
-- This function trusts the p_approver_email parameter. In the demo flow,
-- approver_email arrives via URL query string from the Slack message —
-- meaning anyone with the URL can claim to be any approver. The auth gap
-- is at the URL layer, not at the SoD layer. The SoD trigger fires
-- correctly regardless of who claims to be approving — if Aisha clicks
-- "Approve as Aisha" on her own invocation, FAO-GOV-004 raises.
--
-- Production posture for closing this gap:
--   - Slack signed payloads (Slack signs the request; we verify the
--     signature; the approver identity is authenticated by Slack)
--   - SSO/OIDC at an API gateway (the approver's identity comes from
--     a trusted IdP, not the URL)
--
-- The architecture is: authentication at the edge, enforcement at the
-- database. This function implements the database side; the edge side
-- is named-and-bounded, not hidden.
--
-- Control IDs implemented:
--   FAO-GOV-004  HITL resolution with database-layer SoD enforcement
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-25
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fao_hitl_resolve(
  p_hitl_id          bigint,
  p_decision         public.hitl_decision,
  p_approver_email   text,
  p_decision_notes   text DEFAULT NULL
)
RETURNS TABLE (
  hitl_id           bigint,
  correlation_id    uuid,
  agent_id          text,
  agent_invoker_id  uuid,
  approver_id       uuid,
  approver_email    text,
  decision          public.hitl_decision,
  decided_at        timestamptz,
  risk_tier         public.risk_tier,
  sub_tier          public.policy_sub_tier
)
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_approver_id  uuid;
  v_row_count    integer;
BEGIN
  -- ----- 1. Resolve approver email -> UUID --------------------------------
  SELECT po.id INTO v_approver_id
  FROM public.process_owners po
  WHERE po.email = p_approver_email;

  IF v_approver_id IS NULL THEN
    RAISE EXCEPTION
      'FAO-GOV-004 fao_hitl_resolve: approver_email % is not in process_owners. Check public.process_owners seed.',
      p_approver_email
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- ----- 2. Validate decision (must be terminal, not PENDING) -------------
  IF p_decision NOT IN ('APPROVED', 'REJECTED') THEN
    RAISE EXCEPTION
      'FAO-GOV-004 fao_hitl_resolve: decision must be APPROVED or REJECTED, got %.',
      p_decision
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- ----- 3. Spoof auth.uid() to the approver UUID --------------------------
  -- See header comment for full rationale. Without this, the SoD trigger
  -- silently bypasses (auth.uid() = NULL = administrative path), making
  -- FAO-GOV-004 enforcement theatre. With this, the trigger fires
  -- correctly on self-approval attempts.
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub',  v_approver_id::text,
      'role', 'authenticated'
    )::text,
    true  -- transaction-local; does not leak to next query
  );

  -- ----- 4. Run the UPDATE — SoD trigger fires here ------------------------
  -- The trigger compares auth.uid() (now = approver UUID) to
  -- OLD.agent_invoker_id. On a self-approval attempt, the trigger raises
  -- FAO-GOV-004 and the entire transaction aborts before this RETURN
  -- QUERY produces output. The exception propagates back to the n8n
  -- Postgres node, which surfaces it as a red node with the named
  -- Control ID in the error message.
  RETURN QUERY
  UPDATE public.hitl_queue
  SET
    decision       = p_decision,
    approver_id    = v_approver_id,
    decided_at     = NOW(),
    decision_notes = p_decision_notes
  WHERE hitl_queue.hitl_id  = p_hitl_id
    AND hitl_queue.decision = 'PENDING'
  RETURNING
    hitl_queue.hitl_id,
    hitl_queue.correlation_id,
    hitl_queue.agent_id,
    hitl_queue.agent_invoker_id,
    hitl_queue.approver_id,
    p_approver_email,
    hitl_queue.decision,
    hitl_queue.decided_at,
    hitl_queue.risk_tier,
    hitl_queue.sub_tier;

  -- ----- 5. Confirm UPDATE matched (loud zero-row check) -------------------
  -- If hitl_id doesn't exist or is already decided, UPDATE matches zero
  -- rows. Same lesson as Migration 0007 on the create side: silent zero-
  -- row results are exactly what the gateway exists to prevent.
  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  IF v_row_count = 0 THEN
    RAISE EXCEPTION
      'FAO-GOV-004 fao_hitl_resolve: hitl_id % does not exist or is not PENDING (already decided?).',
      p_hitl_id
      USING ERRCODE = 'no_data_found';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.fao_hitl_resolve(bigint, public.hitl_decision, text, text) IS
  'FAO-GOV-004: Resolves a hitl_queue row from PENDING to APPROVED/REJECTED. Spoofs auth.uid() to the approver UUID via transaction-local JWT claims so the hitl_queue_sod_guard trigger fires correctly on self-approval attempts. Raises named FAO-GOV-004 exceptions on every failure mode (unknown approver, invalid decision, missing/decided row). The SoD trigger raises its own FAO-GOV-004 on actual SoD violations.';
