-- ============================================================================
-- FinAgent OS: Migration 0015: HITL RPCs, notification RPCs and the sweep
-- ============================================================================
-- The functions that read and decide HITL requests, record notification
-- attempts, and run the five-minute maintenance sweep.
--
-- Client RPCs (PostgREST, every parameter text):
--   fao_hitl_get()      the request for the approval page, for members only
--   fao_hitl_decide()   the only way a decision is recorded: decision,
--                       HITL_RESOLVED, rollup and COMMITTED in one transaction
-- Workflow RPCs (n8n over the fao_workflow connection, typed parameters):
--   fao_notification_context()  what the notifier may send, and to whom
--   fao_notification_record()   one notification attempt and its ledger event
--   fao_maintenance_sweep()     expiry, escalation, renotify and stale runs
-- Retired:
--   fao_hitl_create()   dropped (it took the invoker as an email argument)
--   fao_hitl_resolve()  kept as a stub that always raises; it no longer
--                       writes anything
--
-- Control IDs implemented:
--   FAO-GOV-001  ledger events written only through append_event; refusals
--                journaled in the same transaction
--   FAO-GOV-004  identity only from auth.uid(); approver role required; no
--                self-approval; no decision at or after the deadline; the
--                decision and its ledger events commit together or not at all;
--                overdue requests expire and escalate once
--   FAO-GOV-007  notification context and attempts recorded, at most one SENT
--                per request, kind and level; failed sends retried up to the
--                notify_max_attempts setting, then escalated
--   FAO-GOV-008  stale RUNNING runs and expired run tokens are closed
--   FAO-GOV-015  the sweep reports privilege drift and any test clock offset,
--                journaled once per day per distinct state
--
-- Replaces:
--   - public.fao_hitl_create(uuid, text, text, risk_tier, policy_sub_tier,
--     text, text) from migration 0007 (dropped)
--   - public.fao_hitl_resolve(bigint, hitl_decision, text, text) from
--     migration 0008 (now a stub returning void that always raises)
--
-- Validation pattern for client RPCs: session check, then every input check
-- with a fixed message, then authorization. Expected refusals never raise:
-- they journal, set the HTTP status and return ok:false with the fixed
-- message for the code. No database error text reaches a caller.
--
-- Every function: SECURITY DEFINER, VOLATILE, SET search_path = '', fully
-- qualified names; revoked from every client role here; 0017 grants the
-- allow-list. Must work applied on its own and inside one transaction with
-- 0010 to 0017. fao_maintenance_sweep calls fao_private.grants_drift(),
-- which 0017 creates; plpgsql resolves it when the sweep runs.
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Retire the v1 functions (FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- fao_hitl_create took the invoker as an email argument; requests are now
-- opened only by fao_run_finalize (fao_private.create_request).
DROP FUNCTION IF EXISTS public.fao_hitl_create(uuid, text, text, public.risk_tier, public.policy_sub_tier, text, text);

-- fao_hitl_resolve keeps its argument signature so an old caller gets a named
-- refusal instead of an unknown-function error. Its return type changes to
-- void, so it is dropped and created again (CREATE OR REPLACE cannot change a
-- return type). It writes nothing and has no grants.
DROP FUNCTION IF EXISTS public.fao_hitl_resolve(bigint, public.hitl_decision, text, text);

CREATE FUNCTION public.fao_hitl_resolve(
  p_hitl_id        bigint,
  p_decision       public.hitl_decision,
  p_approver_email text,
  p_decision_notes text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'FAO-GOV-004 fao_hitl_resolve is superseded by fao_hitl_decide'
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION public.fao_hitl_resolve(bigint, public.hitl_decision, text, text) IS
  'FAO-GOV-004: retired. Always raises; decisions are recorded only through fao_hitl_decide with the approver''s own session. No grants.';

-- ----------------------------------------------------------------------------
-- 2. fao_hitl_get (FAO-GOV-004, FAO-GOV-007)
-- ----------------------------------------------------------------------------
-- The approval page's read of one request, for the signed-in caller only.
--   1. session (NO_SESSION)
--   2. id (INVALID_INPUT)
--   3. caller holds no honoured invoker, approver or admin grant for any
--      agent: NOT_AUTHORISED, without looking the row up
--   4. missing row: NOT_FOUND (not journaled)
--   5. caller is not an approver for the agent, not the invoker and not a
--      global admin: NOT_AUTHORISED (same body as step 3)
--   6. decided: ALREADY_DECIDED; expired or past the deadline: EXPIRED (both
--      not journaled, carrying request{hitl_id, decision, decided_at} only)
--   7. the request with the viewer flags
-- A read never changes the request or the ledger.
CREATE FUNCTION public.fao_hitl_get(p_hitl_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry    constant text := 'rpc:fao_hitl_get';
  v_uid      uuid;
  v_id       bigint;
  v_key      text;
  v_attempt  jsonb;
  v_req      public.hitl_queue%ROWTYPE;
  v_agent    text;
  v_invoker  text;
  v_short    jsonb;
BEGIN
  v_key     := left(p_hitl_id, 20);
  v_attempt := jsonb_build_object('hitl_id', left(p_hitl_id, 200));

  -- 1. Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- 2. Input
  v_id := fao_private.parse_id(p_hitl_id);
  IF v_id IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  -- 3. Some honoured invoker, approver or admin grant, before any lookup
  IF NOT EXISTS (
    SELECT 1
      FROM public.fao_user_roles r
     WHERE r.user_id = v_uid
       AND r.revoked_at IS NULL
       AND r.role IN ('invoker'::public.fao_app_role, 'approver'::public.fao_app_role, 'admin'::public.fao_app_role)
       AND fao_private.has_role(v_uid, r.role, r.agent_id)
  ) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  -- 4. The row
  SELECT * INTO v_req FROM public.hitl_queue h WHERE h.hitl_id = v_id;
  IF NOT FOUND THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_FOUND', p_journal => false);
  END IF;

  -- 5. A right to this row
  IF NOT (
       fao_private.has_role(v_uid, 'approver'::public.fao_app_role, v_req.agent_id)
    OR v_uid = v_req.agent_invoker_id
    OR fao_private.has_role(v_uid, 'admin'::public.fao_app_role, NULL)
  ) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  -- 6. Decided or expired: the short form only. A request with no deadline
  --    is treated as past it (fail closed).
  v_short := jsonb_build_object('request', jsonb_build_object(
    'hitl_id',    v_req.hitl_id,
    'decision',   v_req.decision::text,
    'decided_at', v_req.decided_at));

  IF v_req.decision IN ('APPROVED'::public.hitl_decision, 'REJECTED'::public.hitl_decision) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'ALREADY_DECIDED', p_journal => false) || v_short;
  END IF;
  IF v_req.decision = 'EXPIRED'::public.hitl_decision
     OR coalesce(fao_private.clock() >= v_req.timeout_at, true) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'EXPIRED', p_journal => false) || v_short;
  END IF;

  -- 7. The request
  SELECT ar.display_name INTO v_agent   FROM public.agent_registry ar WHERE ar.agent_id = v_req.agent_id;
  SELECT po.name         INTO v_invoker FROM public.process_owners po WHERE po.id = v_req.agent_invoker_id;

  RETURN fao_private.ok_result(jsonb_build_object('request', jsonb_build_object(
    'hitl_id',              v_req.hitl_id,
    'agent_id',             v_req.agent_id,
    'agent_name',           v_agent,
    'risk_tier',            v_req.risk_tier::text,
    'sub_tier',             v_req.sub_tier::text,
    'policy_rationale',     v_req.policy_rationale,
    'escalated_assets',     v_req.escalated_assets,
    'configured_approvals', v_req.configured_approvals,
    'enforced_approvals',   v_req.enforced_approvals,
    'created_at',           v_req.created_at,
    'timeout_at',           v_req.timeout_at,
    'decision',             v_req.decision::text,
    'decided_at',           v_req.decided_at,
    'invoker_name',         v_invoker,
    'viewer_is_invoker',    v_uid = v_req.agent_invoker_id,
    'viewer_can_decide',    fao_private.has_role(v_uid, 'approver'::public.fao_app_role, v_req.agent_id)
                            AND v_uid <> v_req.agent_invoker_id)));
END;
$$;

COMMENT ON FUNCTION public.fao_hitl_get(text) IS
  'FAO-GOV-004, FAO-GOV-007: one request for the signed-in caller (identity from auth.uid() only). Members with a right to the row get the request and viewer flags; everyone else gets the same NOT_AUTHORISED body for existing, decided and missing ids. Never writes the request or the ledger.';

-- ----------------------------------------------------------------------------
-- 3. fao_hitl_decide (FAO-GOV-004, FAO-GOV-001, FAO-REC-001)
-- ----------------------------------------------------------------------------
-- The only way a decision is recorded. All in one transaction:
--   1. session (NO_SESSION; the anonymous path)
--   2. id, decision (APPROVED or REJECTED only) and notes (INVALID_INPUT)
--   3. caller holds some honoured role (NOT_AUTHORISED)
--   4. lock the request without waiting (BUSY when another session holds it)
--   5. NOT_FOUND, EXPIRED, ALREADY_DECIDED; at or after the deadline EXPIRED
--      with the row unchanged
--   6. no run record: NO_RUN_RECORD, before any write
--   7. approver role for the agent (NOT_AUTHORISED); the invoker can never
--      decide their own run (SOD_SELF_APPROVAL)
--   8. the decision: approver from the session, time from the FinAgent clock;
--      the hitl_queue row guard re-checks every rule
--   9. HITL_RESOLVED
--  10. the run must be AWAITING_HITL (else raise, rolling everything back);
--      rollup; COMMITTED and run COMMITTED, or COMMIT_BLOCKED and run FAILED
--      (AUDIT_CHAIN_MISMATCH, ok:true, not journaled)
-- Every refusal in steps 1 to 7 is journaled with target hitl_queue, the id
-- text as key and the attempted decision, and returns no request data.
-- Any error after step 7 rolls back the decision and every ledger row.
-- Dual approval (ADR-0001) is not enforced: step 8 is the single update
-- where an approvals table would plug in.
CREATE FUNCTION public.fao_hitl_decide(p_hitl_id text, p_decision text, p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry     constant text := 'rpc:fao_hitl_decide';
  v_uid       uuid;
  v_id        bigint;
  v_key       text;
  v_attempt   jsonb;
  v_req       public.hitl_queue%ROWTYPE;
  v_found     boolean := false;
  v_busy      boolean := false;
  v_run       public.run_invocations%ROWTYPE;
  v_decision  public.hitl_decision;
  v_decided   timestamptz;
  r           jsonb;
  v_ledger    bigint;
  v_obl       text[];
  v_symbols   jsonb;
BEGIN
  v_key     := left(p_hitl_id, 20);
  v_attempt := jsonb_build_object('decision', left(p_decision, 200));

  -- 1. Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- 2. Inputs
  v_id := fao_private.parse_id(p_hitl_id);
  IF v_id IS NULL
     OR coalesce(p_decision IN ('APPROVED', 'REJECTED'), false) IS NOT TRUE
     OR (p_notes IS NOT NULL AND NOT fao_private.text_ok(p_notes, 0, 2000)) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'INVALID_INPUT');
  END IF;
  v_decision := p_decision::public.hitl_decision;

  -- 3. Some honoured role
  IF NOT fao_private.has_any_role(v_uid) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  -- 4. Lock the request; never wait behind another decider
  BEGIN
    SELECT * INTO v_req
      FROM public.hitl_queue h
     WHERE h.hitl_id = v_id
       FOR UPDATE NOWAIT;
    v_found := FOUND;
  EXCEPTION WHEN lock_not_available THEN
    v_busy := true;
  END;
  IF v_busy THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'BUSY');
  END IF;

  -- 5. State and deadline (a request with no deadline is treated as past it)
  IF NOT v_found THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_FOUND');
  END IF;
  IF v_req.decision = 'EXPIRED'::public.hitl_decision THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'EXPIRED');
  END IF;
  IF v_req.decision IN ('APPROVED'::public.hitl_decision, 'REJECTED'::public.hitl_decision) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'ALREADY_DECIDED');
  END IF;
  IF coalesce(fao_private.clock() >= v_req.timeout_at, true) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'EXPIRED');
  END IF;

  -- 6. Run record
  IF NOT EXISTS (SELECT 1 FROM public.run_invocations ri WHERE ri.correlation_id = v_req.correlation_id) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NO_RUN_RECORD');
  END IF;

  -- 7. Approver role, then segregation of duties
  IF NOT fao_private.has_role(v_uid, 'approver'::public.fao_app_role, v_req.agent_id) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;
  IF v_uid = v_req.agent_invoker_id THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'SOD_SELF_APPROVAL');
  END IF;

  -- 8. The decision. The row guard re-checks session, approver, role and
  --    deadline for every role.
  v_decided := fao_private.clock();
  UPDATE public.hitl_queue
     SET decision       = v_decision,
         approver_id    = v_uid,
         decided_at     = v_decided,
         decision_notes = p_notes
   WHERE hitl_id = v_id;

  -- 9. HITL_RESOLVED
  PERFORM fao_private.append_event(
    v_req.correlation_id,
    'HITL_RESOLVED',
    jsonb_build_object(
      'hitl_id',              v_req.hitl_id,
      'decision',             v_decision::text,
      'approver_id',          v_uid,
      'approvers',            jsonb_build_array(v_uid),
      'configured_approvals', v_req.configured_approvals,
      'enforced_approvals',   v_req.enforced_approvals,
      'agent_invoker_id',     v_req.agent_invoker_id,
      'decided_at',           v_decided,
      'sub_tier',             v_req.sub_tier::text,
      'decision_notes',       p_notes),
    'REQUIRE_HUMAN'::public.policy_outcome,
    v_req.sub_tier,
    format('FAO-GOV-004 hitl_id %s %s by approver %s; invoker %s; approvals enforced %s of configured %s',
           v_req.hitl_id, v_decision::text, v_uid, v_req.agent_invoker_id,
           v_req.enforced_approvals, v_req.configured_approvals),
    NULL,
    v_decision::text::public.hitl_status,
    v_uid,
    'SUCCESS'::public.execution_status,
    NULL);

  -- 10. The run, the rollup and the commit
  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.correlation_id = v_req.correlation_id
     FOR UPDATE;
  IF NOT FOUND OR v_run.state IS DISTINCT FROM 'AWAITING_HITL'::public.fao_run_state THEN
    RAISE EXCEPTION 'FAO-GOV-004 hitl_decide: run is not awaiting a decision'
      USING ERRCODE = '42501';
  END IF;

  r := fao_private.run_rollup(v_req.correlation_id);

  IF (r->>'chain_ok')::boolean IS NOT TRUE THEN
    PERFORM fao_private.append_event(
      v_req.correlation_id,
      'COMMIT_BLOCKED',
      jsonb_build_object('hitl_id', v_req.hitl_id, 'problems', r->'problems'),
      'BLOCKED'::public.policy_outcome,
      NULL,
      'FAO-GOV-001 audit chain incomplete; run not committed',
      NULL,
      v_decision::text::public.hitl_status,
      NULL,
      'FAILURE'::public.execution_status,
      NULL);

    UPDATE public.run_invocations
       SET state = 'FAILED', finished_at = now(), last_error = 'audit chain incomplete'
     WHERE correlation_id = v_req.correlation_id;

    RETURN fao_private.ok_result(jsonb_build_object(
      'hitl_id',             v_req.hitl_id,
      'decision',            v_decision::text,
      'decided_at',          v_decided,
      'committed',           false,
      'committed_ledger_id', NULL), 'AUDIT_CHAIN_MISMATCH');
  END IF;

  SELECT coalesce(array_agg(o.v ORDER BY o.ord), ARRAY[]::text[])
    INTO v_obl
    FROM jsonb_array_elements_text(coalesce(r->'obligations', '[]'::jsonb)) WITH ORDINALITY AS o(v, ord);
  SELECT coalesce(jsonb_agg(e.value->'asset' ORDER BY e.ord), '[]'::jsonb)
    INTO v_symbols
    FROM jsonb_array_elements(coalesce(r->'escalated_assets', '[]'::jsonb)) WITH ORDINALITY AS e(value, ord);

  v_ledger := fao_private.append_event(
    v_req.correlation_id,
    'COMMITTED',
    jsonb_build_object(
      'per_asset_summary', r->'per_asset_summary',
      'counts',            r->'counts',
      'escalated_assets',  v_symbols,
      'hitl_id',           v_req.hitl_id,
      'decision',          v_decision::text),
    (r->>'rollup_outcome')::public.policy_outcome,
    (r->>'rollup_sub_tier')::public.policy_sub_tier,
    fao_private.compose_rationale(r, 'COMMITTED')
      || format(' HITL decision: %s (hitl_id %s).', v_decision::text, v_req.hitl_id),
    v_obl,
    v_decision::text::public.hitl_status,
    v_uid,
    CASE WHEN v_decision = 'APPROVED'::public.hitl_decision
         THEN 'SUCCESS'::public.execution_status
         ELSE 'ROLLED_BACK'::public.execution_status END,
    NULL);

  UPDATE public.run_invocations
     SET state = 'COMMITTED', finished_at = now()
   WHERE correlation_id = v_req.correlation_id;

  RETURN fao_private.ok_result(jsonb_build_object(
    'hitl_id',             v_req.hitl_id,
    'decision',            v_decision::text,
    'decided_at',          v_decided,
    'committed',           true,
    'committed_ledger_id', v_ledger));
END;
$$;

COMMENT ON FUNCTION public.fao_hitl_decide(text, text, text) IS
  'FAO-GOV-004, FAO-GOV-001, FAO-REC-001: the only way a HITL decision is recorded. Approver from auth.uid() only; approver role required; the invoker is refused (SOD_SELF_APPROVAL); refused at or after the deadline; decision, HITL_RESOLVED, rollup and COMMITTED (or COMMIT_BLOCKED) in one transaction. Refusals are journaled.';

-- ----------------------------------------------------------------------------
-- 4. fao_notification_context (FAO-GOV-007)
-- ----------------------------------------------------------------------------
-- What the notifier may send for (request, kind, level), read by the gateway
-- workflow before it posts to Slack. Kind and level must be (REQUESTED, 0) or
-- (ESCALATED, 1), else raise.
--   missing request                         NOT_FOUND (ok:false, not journaled)
--   REQUESTED, not PENDING or past deadline NOT_PENDING (ok:true, send:false)
--   ESCALATED, no level-1 escalation event  NOT_PENDING
--   a SENT row already exists               ALREADY_SENT (ok:true, send:false)
--   otherwise                               send:true with the message fields
-- Approver candidates are active owners holding the approver role for the
-- agent, never the invoker, by name only. The invoker is never named.
CREATE FUNCTION public.fao_notification_context(p_hitl_id bigint, p_kind text, p_level int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req        public.hitl_queue%ROWTYPE;
  v_base       jsonb;
  v_agent_name text;
  v_target     uuid;
  v_target_nm  text;
  v_cands      jsonb;
  v_slack_url  text;
  v_channel    text;
BEGIN
  IF NOT coalesce((p_kind = 'REQUESTED' AND p_level = 0) OR (p_kind = 'ESCALATED' AND p_level = 1), false) THEN
    RAISE EXCEPTION 'FAO-GOV-007 notification_context: kind and level must be REQUESTED 0 or ESCALATED 1'
      USING ERRCODE = '22023';
  END IF;

  v_base := jsonb_build_object('send', false, 'hitl_id', p_hitl_id, 'kind', p_kind, 'level', p_level);

  SELECT * INTO v_req FROM public.hitl_queue h WHERE h.hitl_id = p_hitl_id;
  IF NOT FOUND THEN
    RETURN fao_private.refuse('rpc:fao_notification_context', 'hitl_queue', left(p_hitl_id::text, 20),
                              jsonb_build_object('hitl_id', p_hitl_id, 'kind', p_kind, 'level', p_level),
                              'NOT_FOUND', p_journal => false) || v_base;
  END IF;

  IF p_kind = 'REQUESTED' THEN
    IF v_req.decision IS DISTINCT FROM 'PENDING'::public.hitl_decision
       OR coalesce(fao_private.clock() >= v_req.timeout_at, true) THEN
      RETURN fao_private.ok_result(v_base, 'NOT_PENDING');
    END IF;
  ELSE
    SELECT (l.inputs->>'target_owner_id')::uuid
      INTO v_target
      FROM public.shadow_ledger l
     WHERE l.correlation_id = v_req.correlation_id
       AND l.inputs->>'event_type' = 'HITL_ESCALATED'
       AND l.inputs->>'hitl_id' = v_req.hitl_id::text
       AND l.inputs->>'level' = '1'
     ORDER BY l.ledger_id DESC
     LIMIT 1;
    IF NOT FOUND THEN
      RETURN fao_private.ok_result(v_base, 'NOT_PENDING');
    END IF;
    SELECT po.name INTO v_target_nm FROM public.process_owners po WHERE po.id = v_target;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.fao_notifications n
     WHERE n.hitl_id = v_req.hitl_id
       AND n.kind = p_kind
       AND n.level = p_level
       AND n.outcome = 'SENT'
  ) THEN
    RETURN fao_private.ok_result(v_base, 'ALREADY_SENT');
  END IF;

  SELECT ar.display_name INTO v_agent_name FROM public.agent_registry ar WHERE ar.agent_id = v_req.agent_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('name', po.name) ORDER BY po.name), '[]'::jsonb)
    INTO v_cands
    FROM public.process_owners po
   WHERE po.active
     AND po.id <> v_req.agent_invoker_id
     AND fao_private.has_role(po.id, 'approver'::public.fao_app_role, v_req.agent_id);

  v_slack_url := (SELECT s.value FROM public.fao_settings s WHERE s.key = 'slack_api_base_url');
  v_channel   := (SELECT s.value FROM public.fao_settings s WHERE s.key = 'slack_channel_id');

  RETURN fao_private.ok_result(jsonb_build_object(
    'send',                true,
    'hitl_id',             v_req.hitl_id,
    'kind',                p_kind,
    'level',               p_level,
    'agent_id',            v_req.agent_id,
    'agent_name',          v_agent_name,
    'risk_tier',           v_req.risk_tier::text,
    'sub_tier',            v_req.sub_tier::text,
    'timeout_at',          v_req.timeout_at,
    'approval_url',        v_req.approval_url,
    'escalated_assets',    v_req.escalated_assets,
    'approver_candidates', v_cands,
    'target_name',         v_target_nm,
    'slack_api_base_url',  v_slack_url,
    'slack_channel_id',    v_channel));
END;
$$;

COMMENT ON FUNCTION public.fao_notification_context(bigint, text, int) IS
  'FAO-GOV-007: what the notifier may send for a request, kind and level: send:true with the request summary, approval link, approver candidate names (never the invoker) and Slack settings; or NOT_FOUND, NOT_PENDING or ALREADY_SENT with send:false.';

-- ----------------------------------------------------------------------------
-- 5. fao_notification_record (FAO-GOV-007)
-- ----------------------------------------------------------------------------
-- Records one notification attempt and its ledger event in one transaction.
-- Kind and level as above, outcome SENT or FAILED, a known request and a
-- channel name, else raise. A SENT when a SENT row already exists writes
-- nothing (ALREADY_SENT, ok:true). attempt counts every earlier row for the
-- request, kind and level. The recipient is the escalation target for
-- ESCALATED. External reference and error text are stored with control
-- characters replaced, cut to 200 and 300 characters.
CREATE FUNCTION public.fao_notification_record(
  p_hitl_id      bigint,
  p_kind         text,
  p_level        int,
  p_outcome      text,
  p_channel      text,
  p_external_ref text,
  p_error        text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_req       public.hitl_queue%ROWTYPE;
  v_attempt   int;
  v_recipient uuid;
  v_ref       text;
  v_error     text;
  v_nid       bigint;
  v_ledger    bigint;
  v_dup       boolean := false;
BEGIN
  IF NOT coalesce((p_kind = 'REQUESTED' AND p_level = 0) OR (p_kind = 'ESCALATED' AND p_level = 1), false) THEN
    RAISE EXCEPTION 'FAO-GOV-007 notification_record: kind and level must be REQUESTED 0 or ESCALATED 1'
      USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_outcome IN ('SENT', 'FAILED'), false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAO-GOV-007 notification_record: outcome must be SENT or FAILED'
      USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_channel ~ '^[a-z0-9_-]{1,32}$', false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAO-GOV-007 notification_record: channel is not valid'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_req FROM public.hitl_queue h WHERE h.hitl_id = p_hitl_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAO-GOV-007 notification_record: unknown hitl_id %', coalesce(p_hitl_id::text, '<null>')
      USING ERRCODE = '22023';
  END IF;

  -- One recorder at a time per request, kind and level, so attempt numbers
  -- are exact.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('fao_notify:' || v_req.hitl_id::text || ':' || p_kind || ':' || p_level::text));

  IF p_outcome = 'SENT' AND EXISTS (
    SELECT 1
      FROM public.fao_notifications n
     WHERE n.hitl_id = v_req.hitl_id
       AND n.kind = p_kind
       AND n.level = p_level
       AND n.outcome = 'SENT'
  ) THEN
    RETURN fao_private.ok_result('{}'::jsonb, 'ALREADY_SENT');
  END IF;

  SELECT 1 + count(*)::int
    INTO v_attempt
    FROM public.fao_notifications n
   WHERE n.hitl_id = v_req.hitl_id
     AND n.kind = p_kind
     AND n.level = p_level;

  IF p_kind = 'ESCALATED' THEN
    SELECT (l.inputs->>'target_owner_id')::uuid
      INTO v_recipient
      FROM public.shadow_ledger l
     WHERE l.correlation_id = v_req.correlation_id
       AND l.inputs->>'event_type' = 'HITL_ESCALATED'
       AND l.inputs->>'hitl_id' = v_req.hitl_id::text
       AND l.inputs->>'level' = '1'
     ORDER BY l.ledger_id DESC
     LIMIT 1;
  END IF;

  v_ref   := left(regexp_replace(p_external_ref, '[[:cntrl:]]', ' ', 'g'), 200);
  v_error := left(regexp_replace(p_error, '[[:cntrl:]]', ' ', 'g'), 300);

  BEGIN
    INSERT INTO public.fao_notifications
      (hitl_id, kind, level, outcome, attempt, channel, recipient_owner_id, external_ref, error)
    VALUES
      (v_req.hitl_id, p_kind, p_level, p_outcome, v_attempt, p_channel, v_recipient, v_ref, v_error)
    RETURNING notification_id INTO v_nid;
  EXCEPTION WHEN unique_violation THEN
    -- A concurrent SENT for the same request, kind and level won.
    v_dup := true;
  END;
  IF v_dup THEN
    RETURN fao_private.ok_result('{}'::jsonb, 'ALREADY_SENT');
  END IF;

  v_ledger := fao_private.append_event(
    v_req.correlation_id,
    CASE WHEN p_outcome = 'SENT' THEN 'NOTIFICATION_SENT' ELSE 'NOTIFICATION_FAILED' END,
    jsonb_build_object(
      'hitl_id',      v_req.hitl_id,
      'kind',         p_kind,
      'level',        p_level,
      'channel',      p_channel,
      'approval_url', v_req.approval_url,
      'external_ref', v_ref,
      'attempt',      v_attempt,
      'error',        v_error),
    'REQUIRE_HUMAN'::public.policy_outcome,
    NULL,
    format('FAO-GOV-007 %s notification %s for hitl_id %s (attempt %s)', p_kind, p_outcome, v_req.hitl_id, v_attempt),
    NULL,
    v_req.decision::text::public.hitl_status,
    NULL,
    CASE WHEN p_outcome = 'SENT' THEN 'SUCCESS'::public.execution_status ELSE 'FAILURE'::public.execution_status END,
    CASE WHEN p_outcome = 'FAILED' THEN v_error END);

  RETURN fao_private.ok_result(jsonb_build_object(
    'notification_id', v_nid,
    'ledger_id',       v_ledger,
    'attempt',         v_attempt));
END;
$$;

COMMENT ON FUNCTION public.fao_notification_record(bigint, text, int, text, text, text, text) IS
  'FAO-GOV-007: records one notification attempt (fao_notifications) and its NOTIFICATION_SENT or NOTIFICATION_FAILED ledger event in one transaction. At most one SENT per request, kind and level (ALREADY_SENT writes nothing).';

-- ----------------------------------------------------------------------------
-- 6. fao_maintenance_sweep (FAO-GOV-004, FAO-GOV-007, FAO-GOV-008,
--    FAO-GOV-015)
-- ----------------------------------------------------------------------------
-- Run by the n8n sweeper every five minutes. One sweep at a time (advisory
-- lock). Each item runs in its own block: a failure adds {step, id, sqlstate}
-- to item_errors, that item's changes roll back, and the sweep continues.
--   0. checks: test clock offset and privilege drift, each journaled at most
--      once per 24 hours per distinct state (TEST_CLOCK_SET, GRANTS_DRIFT)
--   1. REQUESTED runs whose unconsumed token has expired: EXPIRED (no ledger
--      row; nothing started)
--   2. RUNNING runs past the agent execution SLA (900 s when unset): FAILED
--      event from the sweep, run FAILED
--   3. PENDING requests past their deadline: EXPIRED, HITL_EXPIRED, one
--      level-1 escalation (TIMEOUT) unless one exists, rollup, then COMMITTED
--      with FAILURE or COMMIT_BLOCKED, run EXPIRED
--   4. PENDING requests not yet due with no SENT REQUESTED notification,
--      whose latest attempt FAILED or which are older than 5 minutes with no
--      attempt: renotify while failures are below notify_max_attempts, then
--      one NOTIFICATION_FAILED escalation
--   5. level-1 escalations with no SENT ESCALATED notification and failures
--      below the limit, whose latest attempt FAILED or which are older than
--      5 minutes with no attempt: listed again, once per request (decided
--      requests are not listed)
-- Deadlines are compared with fao_private.clock(). Escalations go to the
-- agent process owner's escalation_to, else the process owner.
CREATE FUNCTION public.fao_maintenance_sweep()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now         timestamptz;
  v_max         int;
  v_offset      int := 0;
  v_drift       boolean := false;
  v_md5         text;
  v_expired_runs jsonb := '[]'::jsonb;
  v_failed_runs jsonb := '[]'::jsonb;
  v_expired_req jsonb := '[]'::jsonb;
  v_escalations jsonb := '[]'::jsonb;
  v_renotify    jsonb := '[]'::jsonb;
  v_errors      jsonb := '[]'::jsonb;
  v_corr        uuid;
  v_hid         bigint;
  v_req         public.hitl_queue%ROWTYPE;
  v_run         public.run_invocations%ROWTYPE;
  v_target      uuid;
  v_has_esc     boolean;
  v_last        text;
  v_failed      int;
  r             jsonb;
  v_obl         text[];
  v_symbols     jsonb;
  c             record;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('fao_sweep'));

  v_now := fao_private.clock();

  BEGIN
    v_max := (SELECT s.value::int FROM public.fao_settings s WHERE s.key = 'notify_max_attempts');
  EXCEPTION WHEN others THEN
    v_max := NULL;  -- a non-integer setting falls back to the default
  END;
  v_max := greatest(coalesce(v_max, 3), 1);

  -- --------------------------------------------------------------------------
  -- 0. Checks (FAO-GOV-015)
  -- --------------------------------------------------------------------------
  BEGIN
    v_offset := coalesce((SELECT tc.offset_seconds FROM fao_private.test_clock tc WHERE tc.id = 1), 0);
    IF v_offset <> 0 THEN
      v_md5 := md5('test_clock:' || v_offset::text);
      IF NOT EXISTS (
        SELECT 1
          FROM public.fao_refusal_journal j
         WHERE j.code = 'TEST_CLOCK_SET'
           AND j.entry_point = 'sweep'
           AND j.attempted->>'diff_md5' = v_md5
           AND j.at > clock_timestamp() - interval '24 hours'
      ) THEN
        PERFORM fao_private.journal_refusal('sweep', 'fao_private.test_clock', NULL,
                                            jsonb_build_object('diff_md5', v_md5), 'TEST_CLOCK_SET');
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'test_clock', 'id', NULL, 'sqlstate', SQLSTATE));
  END;

  BEGIN
    SELECT md5(string_agg(concat_ws('|', d.marker, d.object_kind, d.schema_name, d.object_name, d.grantee, d.privilege),
                          E'\n' ORDER BY d.marker, d.object_kind, d.schema_name, d.object_name, d.grantee, d.privilege))
      INTO v_md5
      FROM fao_private.grants_drift() d;
    v_drift := v_md5 IS NOT NULL;
    IF v_drift AND NOT EXISTS (
      SELECT 1
        FROM public.fao_refusal_journal j
       WHERE j.code = 'GRANTS_DRIFT'
         AND j.entry_point = 'sweep'
         AND j.attempted->>'diff_md5' = v_md5
         AND j.at > clock_timestamp() - interval '24 hours'
    ) THEN
      PERFORM fao_private.journal_refusal('sweep', 'grants', NULL,
                                          jsonb_build_object('diff_md5', v_md5), 'GRANTS_DRIFT');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'grants_drift', 'id', NULL, 'sqlstate', SQLSTATE));
  END;

  -- --------------------------------------------------------------------------
  -- 1. Unclaimed run tokens past expiry (FAO-GOV-008)
  -- --------------------------------------------------------------------------
  FOR v_corr IN
    SELECT ri.correlation_id
      FROM public.run_invocations ri
      JOIN fao_private.run_tokens t ON t.correlation_id = ri.correlation_id
     WHERE ri.state = 'REQUESTED'::public.fao_run_state
       AND t.consumed_at IS NULL
       AND t.expires_at <= v_now
     ORDER BY ri.requested_at, ri.correlation_id
  LOOP
    BEGIN
      SELECT * INTO v_run
        FROM public.run_invocations ri
       WHERE ri.correlation_id = v_corr
         AND ri.state = 'REQUESTED'::public.fao_run_state
         FOR UPDATE SKIP LOCKED;
      IF FOUND THEN
        UPDATE public.run_invocations
           SET state = 'EXPIRED', finished_at = now()
         WHERE correlation_id = v_corr;
        v_expired_runs := v_expired_runs || jsonb_build_array(v_corr);
      END IF;
    EXCEPTION WHEN others THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'expire_run', 'id', v_corr::text, 'sqlstate', SQLSTATE));
    END;
  END LOOP;

  -- --------------------------------------------------------------------------
  -- 2. Stale RUNNING runs (FAO-GOV-008)
  -- --------------------------------------------------------------------------
  FOR v_corr IN
    SELECT ri.correlation_id
      FROM public.run_invocations ri
      JOIN public.agent_registry ar ON ar.agent_id = ri.agent_id
     WHERE ri.state = 'RUNNING'::public.fao_run_state
       AND ri.claimed_at + make_interval(secs => coalesce(ar.sla_max_execution_seconds, 900)) <= v_now
     ORDER BY ri.claimed_at, ri.correlation_id
  LOOP
    BEGIN
      SELECT * INTO v_run
        FROM public.run_invocations ri
       WHERE ri.correlation_id = v_corr
         AND ri.state = 'RUNNING'::public.fao_run_state
         FOR UPDATE SKIP LOCKED;
      IF FOUND THEN
        PERFORM fao_private.append_event(
          v_corr,
          'FAILED',
          jsonb_build_object(
            'failed_node',      'timeout',
            'n8n_execution_id', v_run.n8n_execution_id,
            'source',           'sweep',
            'stage',            'before_request'),
          'BLOCKED'::public.policy_outcome,
          NULL,
          format('FAO-GOV-008 run failed at %s (%s)', 'timeout', 'sweep'),
          NULL,
          'NOT_REQUIRED'::public.hitl_status,
          NULL,
          'FAILURE'::public.execution_status,
          'timeout');
        UPDATE public.run_invocations
           SET state = 'FAILED', finished_at = now(), last_error = 'timeout'
         WHERE correlation_id = v_corr;
        v_failed_runs := v_failed_runs || jsonb_build_array(v_corr);
      END IF;
    EXCEPTION WHEN others THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'fail_run', 'id', v_corr::text, 'sqlstate', SQLSTATE));
    END;
  END LOOP;

  -- --------------------------------------------------------------------------
  -- 3. Overdue requests (FAO-GOV-004)
  -- --------------------------------------------------------------------------
  FOR v_hid IN
    SELECT h.hitl_id
      FROM public.hitl_queue h
     WHERE h.decision = 'PENDING'::public.hitl_decision
       AND h.timeout_at <= v_now
     ORDER BY h.hitl_id
  LOOP
    BEGIN
      SELECT * INTO v_req
        FROM public.hitl_queue h
       WHERE h.hitl_id = v_hid
         AND h.decision = 'PENDING'::public.hitl_decision
         FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN
        CONTINUE;  -- decided meanwhile, or locked by a decider
      END IF;

      SELECT * INTO v_run
        FROM public.run_invocations ri
       WHERE ri.correlation_id = v_req.correlation_id
         FOR UPDATE;
      IF NOT FOUND THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'expire_request', 'id', v_hid::text, 'sqlstate', 'NO_RUN_RECORD'));
        CONTINUE;
      END IF;
      IF v_run.state IS DISTINCT FROM 'AWAITING_HITL'::public.fao_run_state THEN
        RAISE EXCEPTION 'FAO-GOV-004 sweep: run % is not awaiting a decision', v_run.correlation_id
          USING ERRCODE = '42501';
      END IF;

      UPDATE public.hitl_queue
         SET decision = 'EXPIRED', decided_at = v_now
       WHERE hitl_id = v_hid;

      PERFORM fao_private.append_event(
        v_req.correlation_id,
        'HITL_EXPIRED',
        jsonb_build_object(
          'hitl_id',    v_req.hitl_id,
          'timeout_at', v_req.timeout_at,
          'expired_at', v_now,
          'source',     'sweep'),
        'REQUIRE_HUMAN'::public.policy_outcome,
        v_req.sub_tier,
        format('FAO-GOV-004 hitl_id %s expired without a decision (%s)', v_req.hitl_id, 'sweep'),
        NULL,
        'EXPIRED'::public.hitl_status,
        NULL,
        'FAILURE'::public.execution_status,
        NULL);

      v_has_esc := EXISTS (
        SELECT 1
          FROM public.shadow_ledger l
         WHERE l.correlation_id = v_req.correlation_id
           AND l.inputs->>'event_type' = 'HITL_ESCALATED'
           AND l.inputs->>'hitl_id' = v_req.hitl_id::text
           AND l.inputs->>'level' = '1');
      IF NOT v_has_esc THEN
        SELECT coalesce(po.escalation_to, po.id)
          INTO v_target
          FROM public.agent_registry ar
          JOIN public.process_owners po ON po.id = ar.process_owner_id
         WHERE ar.agent_id = v_req.agent_id;

        PERFORM fao_private.append_event(
          v_req.correlation_id,
          'HITL_ESCALATED',
          jsonb_build_object(
            'hitl_id',         v_req.hitl_id,
            'level',           1,
            'target_owner_id', v_target,
            'reason',          'TIMEOUT'),
          'REQUIRE_HUMAN'::public.policy_outcome,
          v_req.sub_tier,
          format('FAO-GOV-004 hitl_id %s escalated to level 1 (%s)', v_req.hitl_id, 'TIMEOUT'),
          NULL,
          'EXPIRED'::public.hitl_status,
          NULL,
          'SUCCESS'::public.execution_status,
          NULL);
      END IF;

      r := fao_private.run_rollup(v_req.correlation_id);
      IF (r->>'chain_ok')::boolean IS TRUE THEN
        SELECT coalesce(array_agg(o.v ORDER BY o.ord), ARRAY[]::text[])
          INTO v_obl
          FROM jsonb_array_elements_text(coalesce(r->'obligations', '[]'::jsonb)) WITH ORDINALITY AS o(v, ord);
        SELECT coalesce(jsonb_agg(e.value->'asset' ORDER BY e.ord), '[]'::jsonb)
          INTO v_symbols
          FROM jsonb_array_elements(coalesce(r->'escalated_assets', '[]'::jsonb)) WITH ORDINALITY AS e(value, ord);

        PERFORM fao_private.append_event(
          v_req.correlation_id,
          'COMMITTED',
          jsonb_build_object(
            'per_asset_summary', r->'per_asset_summary',
            'counts',            r->'counts',
            'escalated_assets',  v_symbols,
            'hitl_id',           v_req.hitl_id,
            'decision',          'EXPIRED'),
          (r->>'rollup_outcome')::public.policy_outcome,
          (r->>'rollup_sub_tier')::public.policy_sub_tier,
          fao_private.compose_rationale(r, 'COMMITTED')
            || format(' HITL decision: %s (hitl_id %s).', 'EXPIRED', v_req.hitl_id),
          v_obl,
          'EXPIRED'::public.hitl_status,
          NULL,
          'FAILURE'::public.execution_status,
          NULL);
      ELSE
        PERFORM fao_private.append_event(
          v_req.correlation_id,
          'COMMIT_BLOCKED',
          jsonb_build_object('hitl_id', v_req.hitl_id, 'problems', r->'problems'),
          'BLOCKED'::public.policy_outcome,
          NULL,
          'FAO-GOV-001 audit chain incomplete; run not committed',
          NULL,
          'EXPIRED'::public.hitl_status,
          NULL,
          'FAILURE'::public.execution_status,
          NULL);
      END IF;

      UPDATE public.run_invocations
         SET state = 'EXPIRED', finished_at = now()
       WHERE correlation_id = v_req.correlation_id;

      v_expired_req := v_expired_req || jsonb_build_array(jsonb_build_object(
        'hitl_id', v_req.hitl_id, 'correlation_id', v_req.correlation_id));
      IF NOT v_has_esc THEN
        v_escalations := v_escalations || jsonb_build_array(jsonb_build_object(
          'hitl_id', v_req.hitl_id, 'level', 1, 'reason', 'TIMEOUT'));
      END IF;
    EXCEPTION WHEN others THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'expire_request', 'id', v_hid::text, 'sqlstate', SQLSTATE));
    END;
  END LOOP;

  -- --------------------------------------------------------------------------
  -- 4. REQUESTED notifications that are due again (FAO-GOV-007)
  -- --------------------------------------------------------------------------
  FOR c IN
    SELECT h.hitl_id, h.created_at
      FROM public.hitl_queue h
     WHERE h.decision = 'PENDING'::public.hitl_decision
       AND h.timeout_at > v_now
       AND NOT EXISTS (
         SELECT 1
           FROM public.fao_notifications n
          WHERE n.hitl_id = h.hitl_id
            AND n.kind = 'REQUESTED'
            AND n.level = 0
            AND n.outcome = 'SENT')
     ORDER BY h.hitl_id
  LOOP
    BEGIN
      SELECT n.outcome
        INTO v_last
        FROM public.fao_notifications n
       WHERE n.hitl_id = c.hitl_id
         AND n.kind = 'REQUESTED'
         AND n.level = 0
       ORDER BY n.notification_id DESC
       LIMIT 1;
      IF NOT FOUND THEN
        v_last := NULL;
      END IF;

      IF (v_last = 'FAILED') OR (v_last IS NULL AND c.created_at < v_now - interval '5 minutes') THEN
        SELECT count(*)::int
          INTO v_failed
          FROM public.fao_notifications n
         WHERE n.hitl_id = c.hitl_id
           AND n.kind = 'REQUESTED'
           AND n.level = 0
           AND n.outcome = 'FAILED';

        IF v_failed < v_max THEN
          v_renotify := v_renotify || jsonb_build_array(jsonb_build_object(
            'hitl_id', c.hitl_id, 'attempt', v_failed + 1));
        ELSE
          SELECT * INTO v_req
            FROM public.hitl_queue h
           WHERE h.hitl_id = c.hitl_id
             AND h.decision = 'PENDING'::public.hitl_decision
             FOR UPDATE SKIP LOCKED;
          IF FOUND AND NOT EXISTS (
            SELECT 1
              FROM public.shadow_ledger l
             WHERE l.correlation_id = v_req.correlation_id
               AND l.inputs->>'event_type' = 'HITL_ESCALATED'
               AND l.inputs->>'hitl_id' = v_req.hitl_id::text
               AND l.inputs->>'level' = '1'
          ) THEN
            SELECT coalesce(po.escalation_to, po.id)
              INTO v_target
              FROM public.agent_registry ar
              JOIN public.process_owners po ON po.id = ar.process_owner_id
             WHERE ar.agent_id = v_req.agent_id;

            PERFORM fao_private.append_event(
              v_req.correlation_id,
              'HITL_ESCALATED',
              jsonb_build_object(
                'hitl_id',         v_req.hitl_id,
                'level',           1,
                'target_owner_id', v_target,
                'reason',          'NOTIFICATION_FAILED'),
              'REQUIRE_HUMAN'::public.policy_outcome,
              v_req.sub_tier,
              format('FAO-GOV-004 hitl_id %s escalated to level 1 (%s)', v_req.hitl_id, 'NOTIFICATION_FAILED'),
              NULL,
              'PENDING'::public.hitl_status,
              NULL,
              'SUCCESS'::public.execution_status,
              NULL);

            v_escalations := v_escalations || jsonb_build_array(jsonb_build_object(
              'hitl_id', v_req.hitl_id, 'level', 1, 'reason', 'NOTIFICATION_FAILED'));
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN others THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'renotify', 'id', c.hitl_id::text, 'sqlstate', SQLSTATE));
    END;
  END LOOP;

  -- --------------------------------------------------------------------------
  -- 5. ESCALATED notifications that are due (FAO-GOV-007)
  -- --------------------------------------------------------------------------
  FOR c IN
    SELECT h.hitl_id, e.reason, e.event_timestamp
      FROM public.hitl_queue h
      CROSS JOIN LATERAL (
        SELECT l.inputs->>'reason' AS reason, l.event_timestamp
          FROM public.shadow_ledger l
         WHERE l.correlation_id = h.correlation_id
           AND l.inputs->>'event_type' = 'HITL_ESCALATED'
           AND l.inputs->>'hitl_id' = h.hitl_id::text
           AND l.inputs->>'level' = '1'
         ORDER BY l.ledger_id DESC
         LIMIT 1) e
     WHERE h.decision IN ('PENDING'::public.hitl_decision, 'EXPIRED'::public.hitl_decision)
       AND NOT EXISTS (
         SELECT 1
           FROM public.fao_notifications n
          WHERE n.hitl_id = h.hitl_id
            AND n.kind = 'ESCALATED'
            AND n.level = 1
            AND n.outcome = 'SENT')
     ORDER BY h.hitl_id
  LOOP
    BEGIN
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_escalations) x WHERE (x->>'hitl_id')::bigint = c.hitl_id) THEN
        CONTINUE;  -- already listed by step 3 or 4 in this sweep
      END IF;

      SELECT n.outcome
        INTO v_last
        FROM public.fao_notifications n
       WHERE n.hitl_id = c.hitl_id
         AND n.kind = 'ESCALATED'
         AND n.level = 1
       ORDER BY n.notification_id DESC
       LIMIT 1;
      IF NOT FOUND THEN
        v_last := NULL;
      END IF;

      SELECT count(*)::int
        INTO v_failed
        FROM public.fao_notifications n
       WHERE n.hitl_id = c.hitl_id
         AND n.kind = 'ESCALATED'
         AND n.level = 1
         AND n.outcome = 'FAILED';

      IF v_failed < v_max
         AND ((v_last = 'FAILED') OR (v_last IS NULL AND c.event_timestamp < v_now - interval '5 minutes')) THEN
        v_escalations := v_escalations || jsonb_build_array(jsonb_build_object(
          'hitl_id', c.hitl_id, 'level', 1, 'reason', c.reason));
      END IF;
    EXCEPTION WHEN others THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('step', 'escalation_notice', 'id', c.hitl_id::text, 'sqlstate', SQLSTATE));
    END;
  END LOOP;

  RETURN fao_private.ok_result(jsonb_build_object(
    'expired_runs',         v_expired_runs,
    'failed_runs',          v_failed_runs,
    'expired_requests',     v_expired_req,
    'escalations',          v_escalations,
    'renotify',             v_renotify,
    'item_errors',          v_errors,
    'grants_drift',         v_drift,
    'clock_offset_seconds', v_offset));
END;
$$;

COMMENT ON FUNCTION public.fao_maintenance_sweep() IS
  'FAO-GOV-004, FAO-GOV-007, FAO-GOV-008, FAO-GOV-015: the five-minute sweep. Expires unclaimed run tokens and overdue requests (HITL_EXPIRED, one escalation, COMMITTED with FAILURE or COMMIT_BLOCKED), fails stale runs, lists notifications that are due, and reports privilege drift and any test clock offset. One failing item never stops the others.';

-- ----------------------------------------------------------------------------
-- 7. Revoke every function in this file from every client role. 0017 grants:
--    fao_hitl_get to authenticated; fao_hitl_decide to anon and
--    authenticated; the three workflow RPCs to fao_workflow; fao_hitl_resolve
--    to nobody.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fao_hitl_resolve(bigint, public.hitl_decision, text, text)          FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_hitl_get(text)                                                  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_hitl_decide(text, text, text)                                   FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_notification_context(bigint, text, int)                         FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_notification_record(bigint, text, int, text, text, text, text)  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_maintenance_sweep()                                             FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
