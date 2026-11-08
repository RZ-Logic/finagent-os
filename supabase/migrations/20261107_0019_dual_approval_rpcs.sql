-- ============================================================================
-- FinAgent OS: Migration 0019: dual approval RPCs and the run summary view
-- ============================================================================
-- Dual approval (ADR-0004; owner decisions DA-1 to DA-4 of 2026-11-08,
-- phase2-5/DUAL-APPROVAL.md sections 4 to 6, 8.1 and 13) for the request
-- read, the decision, the notice context and the run summary. Builds on
-- 0018, which creates public.hitl_approvals, its guards and the helpers
-- fao_private.approver_qualifies and fao_private.counted_approvals, and
-- adds the codes AWAITING_FURTHER_APPROVAL and ALREADY_APPROVED.
--
-- Replaces (CREATE OR REPLACE; same signatures, return types, SECURITY
-- DEFINER, VOLATILE and SET search_path = ''; their grants stay):
--   - public.fao_hitl_get(json) from migration 0015: the full form's
--     request gains approvals_received (approvals that count now) and
--     viewer_has_approved; viewer_can_decide needs a qualifying approver
--     grant for the request (DA-4)
--   - public.fao_hitl_decide(json) from migration 0015: one hitl_approvals
--     row per first APPROVE; a request is decided by the APPROVE that brings
--     the counted approvals to enforced_approvals (AWAITING_FURTHER_APPROVAL
--     and HITL_APPROVAL_RECORDED before that) or by any eligible REJECT
--     (DA-2); a repeat APPROVE is ALREADY_APPROVED unless the counted
--     approvals already reach enforced_approvals; the run, owner and grant
--     locks taken before any write wait at most 2s (BUSY); the caller is
--     re-checked after them, with the DA-4 qualifying-grant test
--   - public.fao_notification_context(bigint, text, int) from migration
--     0015: send:true gains enforced_approvals, approvals_received and
--     approved_by
--   - view public.fao_run_summary from migration 0016: two trailing columns,
--     enforced_approvals and approvals_recorded
--
-- Control IDs implemented:
--   FAO-GOV-004  identity only from auth.uid(); approver role through a
--                qualifying approver grant (DA-4); the invoker never
--                approves, rejects or counts; one user counts once (DA-3);
--                two approvals for CRITICAL review (DA-1); one rejection
--                closes the request (DA-2); approval, decision, ledger rows
--                and run state commit together or not at all
--   FAO-GOV-001  every new ledger row through fao_private.append_event;
--                refusals journaled in the same transaction
--   FAO-GOV-007  the notice context reports the approvals needed and
--                received, never naming the invoker
--   FAO-GOV-015  the run summary reports the enforced approval count and the
--                approvals recorded for the newest request
--
-- Revokes nothing: every object here is replaced, not created, so it keeps
-- its privileges (and the view its INSTEAD OF trigger). Must work applied on
-- its own after 0018, inside one transaction 0018 to 0020, and inside the
-- cutover bundle 0010 to 0020. No transaction control.
--
-- Rollback: see phase2-5/rollback/rollback_dual_approval.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. fao_hitl_get (FAO-GOV-004, FAO-GOV-007)
-- ----------------------------------------------------------------------------
-- Steps 1 to 6, their codes, their journaling and the K3 top-level keys are
-- the 0015 ones. The short forms (ALREADY_DECIDED, EXPIRED) keep exactly
-- request{hitl_id, decision, decided_at}. Step 7, the full form of a PENDING
-- request before its deadline, changes:
--   viewer_can_decide    has_role(approver) AND not the invoker AND a
--                        qualifying approver grant for the request
--                        (approver_qualifies, co-approver rule not applied:
--                        it never stops a rejection)
--   approvals_received   cardinality(counted_approvals): approvals that
--                        count now (new)
--   viewer_has_approved  an approval row by the viewer exists, counted or
--                        not (new)
-- A read never writes the request, the approvals or the ledger.
CREATE OR REPLACE FUNCTION public.fao_hitl_get(json)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry    constant text := 'rpc:fao_hitl_get';
  v_in       jsonb := fao_private.client_args($1, ARRAY['p_hitl_id']);
  -- Decoded body field under the old argument name.
  p_hitl_id  text := v_in->'args'->>'p_hitl_id';
  v_uid      uuid;
  v_id       bigint;
  v_key      text;
  v_attempt  jsonb;
  v_req      public.hitl_queue%ROWTYPE;
  v_agent    text;
  v_invoker  text;
  v_short    jsonb;
  v_committed boolean := false;
  v_blocked  text;
BEGIN
  v_key     := left(p_hitl_id, 20);
  v_attempt := jsonb_build_object('hitl_id', left(p_hitl_id, 200)) || (v_in->'note');

  -- 1. Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- 2. Body and input
  v_id := fao_private.parse_id(p_hitl_id);
  IF (v_in->>'ok')::boolean IS NOT TRUE OR v_id IS NULL THEN
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
    -- K3: whether the decided run was committed, and the named reason when
    -- the commit gate blocked it.
    v_committed := EXISTS (
      SELECT 1 FROM public.run_invocations ri
       WHERE ri.correlation_id = v_req.correlation_id
         AND ri.state = 'COMMITTED'::public.fao_run_state);
    SELECT coalesce(l.inputs->>'reason', l.inputs->>'code')
      INTO v_blocked
      FROM public.shadow_ledger l
     WHERE l.correlation_id = v_req.correlation_id
       AND l.inputs->>'event_type' = 'COMMIT_BLOCKED'
       AND l.inputs->>'hitl_id' = v_req.hitl_id::text
     ORDER BY l.ledger_id DESC
     LIMIT 1;
    IF v_blocked IS NULL OR v_blocked NOT IN ('AGENT_NOT_ACTIVE', 'INVOKER_NOT_ACTIVE') THEN
      v_blocked := NULL;
    END IF;
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'ALREADY_DECIDED', p_journal => false)
      || v_short
      || jsonb_build_object('committed', v_committed, 'commit_blocked_reason', v_blocked);
  END IF;
  IF v_req.decision = 'EXPIRED'::public.hitl_decision
     OR coalesce(fao_private.clock() >= v_req.timeout_at, true) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'EXPIRED', p_journal => false)
      || v_short
      || jsonb_build_object('committed', false, 'commit_blocked_reason', NULL);
  END IF;

  -- 7. The request, with the approval progress (dual approval, DA-4)
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
    'approvals_received',   cardinality(fao_private.counted_approvals(v_req.hitl_id)),
    'viewer_has_approved',  EXISTS (SELECT 1 FROM public.hitl_approvals a
                                     WHERE a.hitl_id = v_req.hitl_id
                                       AND a.approver_id = v_uid),
    'created_at',           v_req.created_at,
    'timeout_at',           v_req.timeout_at,
    'decision',             v_req.decision::text,
    'decided_at',           v_req.decided_at,
    'invoker_name',         v_invoker,
    'viewer_is_invoker',    v_uid = v_req.agent_invoker_id,
    'viewer_can_decide',    fao_private.has_role(v_uid, 'approver'::public.fao_app_role, v_req.agent_id)
                            AND v_uid <> v_req.agent_invoker_id
                            AND fao_private.approver_qualifies(v_req.hitl_id, v_uid, false)),
    -- K3: a PENDING request is never committed or blocked.
    'committed',             false,
    'commit_blocked_reason', NULL));
END;
$$;

COMMENT ON FUNCTION public.fao_hitl_get(json) IS
  'FAO-GOV-004, FAO-GOV-007: the decision view of one request for the signed-in caller (identity from auth.uid() only); body {p_hitl_id}. An approver for the agent, the invoker or a global admin gets the request with viewer flags (viewer_can_decide needs a qualifying approver grant for the request, DA-4), the approvals that count now (approvals_received) and whether the viewer has approved (viewer_has_approved); another member gets NOT_AUTHORISED for an existing row (the row stays readable to every member through the hitl_queue read policy); a caller with no honoured role gets the same NOT_AUTHORISED body for existing, decided and missing ids. The OK, ALREADY_DECIDED and EXPIRED envelopes also carry top-level committed and commit_blocked_reason (K3); ALREADY_DECIDED and EXPIRED carry request{hitl_id, decision, decided_at} only. Never writes.';

-- ----------------------------------------------------------------------------
-- 2. fao_hitl_decide (FAO-GOV-004, FAO-GOV-001, FAO-REC-001)
-- ----------------------------------------------------------------------------
-- The only client path by which a HITL approval or decision is recorded (an
-- owner-class session is outside the control, FAO-GOV-001). Body {p_hitl_id,
-- p_decision, p_notes? [null]} (IC-18). All in one transaction. Steps 1 to 7
-- are the 0015 steps, unchanged in code, order, codes and journaling:
--   1. session (NO_SESSION)
--   2. body, id, decision and notes (INVALID_INPUT)
--   3. caller holds some honoured role (NOT_AUTHORISED)
--   4. L1: lock the request without waiting (BUSY)
--   5. NOT_FOUND, EXPIRED, ALREADY_DECIDED; at or after the deadline EXPIRED
--   6. no run record: NO_RUN_RECORD
--   7. approver role for the agent (NOT_AUTHORISED); the invoker can never
--      decide their own run (SOD_SELF_APPROVAL)
-- Dual approval (DUAL-APPROVAL.md 4.3):
--   8. whether the caller already has an approval row (read only)
--   9. L2 the run row FOR UPDATE, L3 the owner rows and L4 the unrevoked
--      approver grants of the lock set (APPROVED: the earlier approvers and
--      the caller; REJECTED: the caller only), shared, by id, with
--      lock_timeout 2s and the caller's value restored right after, before
--      any write; a timeout is BUSY. The run must be AWAITING_HITL (else
--      raise). The decision time is taken here.
--  10. the caller must still hold the approver role and a qualifying
--      approver grant for the request (DA-4; for an APPROVE, one not made by
--      another approver of the request): else NOT_AUTHORISED
--  11. REJECTED decides at once (DA-2). A repeat APPROVE writes no row: it
--      decides when the counted approvals already reach enforced_approvals
--      (restore case), else ALREADY_APPROVED
--  12. a first APPROVE writes its hitl_approvals row (the row guard re-checks
--      every rule for every role)
--  13. count: below enforced_approvals, HITL_APPROVAL_RECORDED and
--      AWAITING_FURTHER_APPROVAL (nothing gated or committed); else decide
--  14. the decision (the hitl_queue row guard requires, for APPROVED, the
--      enforced number of counted approvals, the approver's among them)
--  15. HITL_RESOLVED with every counted approver (APPROVED) or the rejector
--  16. the 0015 commit path from the K2 share locks onward, unchanged: L5
--      invoker owner row and grants, L6 agent row, rollup, then the agent
--      status gate, the invoker gate, the chain gate, then the commit
-- Every refusal in steps 1 to 12 is journaled with target hitl_queue, the id
-- text as key and the attempted decision, and returns no request data. A
-- refusal in steps 9 to 12 commits only its journal row. Any error after
-- step 9 rolls back the approval row, the decision and every ledger row.
CREATE OR REPLACE FUNCTION public.fao_hitl_decide(json)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry     constant text := 'rpc:fao_hitl_decide';
  v_in        jsonb := fao_private.client_args($1, ARRAY['p_hitl_id', 'p_decision'], '{"p_notes": null}'::jsonb);
  -- Decoded body fields under the old argument names.
  p_hitl_id   text := v_in->'args'->>'p_hitl_id';
  p_decision  text := v_in->'args'->>'p_decision';
  p_notes     text := v_in->'args'->>'p_notes';
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
  v_status    public.agent_status;
  v_inv_ok    boolean;
  -- Dual approval (DUAL-APPROVAL.md 4.3)
  v_users        uuid[];
  v_counted      uuid[];
  v_approvers    uuid[];
  v_recorded     int;
  v_has_row      boolean := false;
  v_run_found    boolean := false;
  v_lock_timeout text;
  v_dup          boolean := false;
  v_suffix       text := '';
BEGIN
  v_key     := left(p_hitl_id, 20);
  v_attempt := jsonb_build_object('decision', left(p_decision, 200)) || (v_in->'note');

  -- 1. Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- 2. Body (client_args, which also holds the IC-14 media type check) and
  --    inputs
  v_id := fao_private.parse_id(p_hitl_id);
  IF (v_in->>'ok')::boolean IS NOT TRUE
     OR v_id IS NULL
     OR coalesce(p_decision IN ('APPROVED', 'REJECTED'), false) IS NOT TRUE
     OR (p_notes IS NOT NULL AND NOT fao_private.text_ok(p_notes, 0, 2000)) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'INVALID_INPUT');
  END IF;
  v_decision := p_decision::public.hitl_decision;

  -- 3. Some honoured role
  IF NOT fao_private.has_any_role(v_uid) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  -- 4. Lock the request; never wait behind another decider (L1)
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

  -- 8. Earlier approval by the caller (read only). Every approval row of a
  --    request is written by a decide call holding L1, so the answer holds
  --    until this call ends.
  v_has_row := EXISTS (SELECT 1 FROM public.hitl_approvals a
                        WHERE a.hitl_id = v_req.hitl_id AND a.approver_id = v_uid);

  -- 9. Run lock (L2) and eligibility locks (L3 owner rows, L4 unrevoked
  --    approver grants) of the lock set, bounded wait (C18). Nothing has
  --    been written yet. The setting is restored outside the inner block, so
  --    the restore runs on both paths.
  v_users := CASE WHEN v_decision = 'APPROVED'::public.hitl_decision
                  THEN ARRAY(SELECT a.approver_id FROM public.hitl_approvals a
                              WHERE a.hitl_id = v_req.hitl_id
                              ORDER BY a.approval_id) || v_uid
                  ELSE ARRAY[v_uid] END;
  v_lock_timeout := current_setting('lock_timeout');
  PERFORM set_config('lock_timeout', '2s', true);
  BEGIN
    SELECT * INTO v_run
      FROM public.run_invocations ri
     WHERE ri.correlation_id = v_req.correlation_id
       FOR UPDATE;
    v_run_found := FOUND;
    PERFORM 1 FROM public.process_owners po
      WHERE po.id = ANY (v_users)
      ORDER BY po.id
      FOR SHARE;
    PERFORM 1 FROM public.fao_user_roles ur
      WHERE ur.user_id = ANY (v_users)
        AND ur.role = 'approver'::public.fao_app_role
        AND ur.revoked_at IS NULL
      ORDER BY ur.id
      FOR SHARE;
  EXCEPTION WHEN lock_not_available THEN
    v_busy := true;
  END;
  PERFORM set_config('lock_timeout', v_lock_timeout, true);
  IF v_busy THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'BUSY');
  END IF;
  IF NOT v_run_found OR v_run.state IS DISTINCT FROM 'AWAITING_HITL'::public.fao_run_state THEN
    RAISE EXCEPTION 'FAO-GOV-004 hitl_decide: run is not awaiting a decision'
      USING ERRCODE = '42501';
  END IF;
  v_decided := fao_private.clock();

  -- 10. Caller re-check and DA-4 eligibility, both decisions: a revoke or
  --     deactivation that committed before the locks is seen here; the
  --     qualifying-grant test applies the co-approver rule to an APPROVE
  --     only (a rejection fails safe).
  IF NOT fao_private.has_role(v_uid, 'approver'::public.fao_app_role, v_req.agent_id)
     OR NOT fao_private.approver_qualifies(v_req.hitl_id, v_uid,
              v_decision = 'APPROVED'::public.hitl_decision) THEN
    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  -- 11. Branch
  IF v_decision = 'REJECTED'::public.hitl_decision THEN
    -- DA-2: one eligible rejection closes the request at once, whatever
    -- approvals exist, the caller's own included.
    v_approvers := ARRAY[v_uid];
  ELSIF v_has_row THEN
    -- A repeat approval writes no row. It decides only when the approvals
    -- that count already reach the enforced count (an earlier approver's
    -- eligibility was restored); the caller's own row is among them.
    v_counted  := fao_private.counted_approvals(v_req.hitl_id);
    v_recorded := (SELECT count(*)::int FROM public.hitl_approvals a WHERE a.hitl_id = v_req.hitl_id);
    IF cardinality(v_counted) < v_req.enforced_approvals THEN
      RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'ALREADY_APPROVED');
    END IF;
    v_approvers := v_counted;
  ELSE
    -- 12. The approval row. The hitl_approvals row guard re-checks session,
    --     approver, request state, deadline, run state, segregation of
    --     duties, role, qualifying grant, time and notes for every role.
    BEGIN
      INSERT INTO public.hitl_approvals (hitl_id, approver_id, approved_at, decision_notes)
      VALUES (v_req.hitl_id, v_uid, v_decided, p_notes);
    EXCEPTION WHEN unique_violation THEN
      v_dup := true;
    END;
    IF v_dup THEN
      RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'ALREADY_APPROVED');
    END IF;

    -- 13. Count
    v_counted  := fao_private.counted_approvals(v_req.hitl_id);
    v_recorded := (SELECT count(*)::int FROM public.hitl_approvals a WHERE a.hitl_id = v_req.hitl_id);
    IF cardinality(v_counted) < v_req.enforced_approvals THEN
      -- Partial approval: recorded, nothing decided, gated or committed.
      PERFORM fao_private.append_event(
        v_req.correlation_id,
        'HITL_APPROVAL_RECORDED',
        jsonb_build_object(
          'hitl_id',              v_req.hitl_id,
          'decision',             'APPROVED',
          'approver_id',          v_uid,
          'approvers',            to_jsonb(v_counted),
          'configured_approvals', v_req.configured_approvals,
          'enforced_approvals',   v_req.enforced_approvals,
          'agent_invoker_id',     v_req.agent_invoker_id,
          'sub_tier',             v_req.sub_tier::text,
          'decision_notes',       p_notes),
        'REQUIRE_HUMAN'::public.policy_outcome,
        v_req.sub_tier,
        format('FAO-GOV-004 hitl_id %s approval %s of %s recorded by approver %s; invoker %s; awaiting further approval',
               v_req.hitl_id, cardinality(v_counted), v_req.enforced_approvals, v_uid, v_req.agent_invoker_id)
          || CASE WHEN v_recorded > cardinality(v_counted)
                  THEN format('; %s earlier approvals no longer count', v_recorded - cardinality(v_counted))
                  ELSE '' END,
        NULL,
        'PENDING'::public.hitl_status,
        v_uid,
        'SUCCESS'::public.execution_status,
        NULL);

      RETURN fao_private.ok_result(jsonb_build_object(
        'hitl_id',             v_req.hitl_id,
        'decision',            'PENDING',
        'decided_at',          NULL,
        'committed',           false,
        'committed_ledger_id', NULL,
        'approvals_received',  cardinality(v_counted),
        'enforced_approvals',  v_req.enforced_approvals,
        'approved_at',         v_decided), 'AWAITING_FURTHER_APPROVAL');
    END IF;
    -- Deciding approval
    v_approvers := v_counted;
  END IF;

  -- 14. The decision. The hitl_queue row guard re-checks every core rule,
  --     plus (APPROVED) the enforced number of counted approvals with the
  --     approver among them, and (REJECTED) a qualifying grant.
  UPDATE public.hitl_queue
     SET decision       = v_decision,
         approver_id    = v_uid,
         decided_at     = v_decided,
         decision_notes = p_notes
   WHERE hitl_id = v_id;

  -- 15. HITL_RESOLVED. The rationale gains a suffix only when more than one
  --     approval is enforced, so a single-approval row reads as before.
  IF v_req.enforced_approvals > 1 THEN
    IF v_decision = 'REJECTED'::public.hitl_decision THEN
      v_counted  := fao_private.counted_approvals(v_req.hitl_id);
      v_recorded := (SELECT count(*)::int FROM public.hitl_approvals a WHERE a.hitl_id = v_req.hitl_id);
      v_suffix := format('; approvals received %s of %s before the rejection',
                         cardinality(v_counted), v_req.enforced_approvals);
    ELSE
      v_suffix := format('; approvers %s', array_to_string(v_approvers, ', '));
    END IF;
    IF v_recorded > cardinality(v_counted) THEN
      v_suffix := v_suffix || format('; %s earlier approvals no longer count', v_recorded - cardinality(v_counted));
    END IF;
  END IF;

  PERFORM fao_private.append_event(
    v_req.correlation_id,
    'HITL_RESOLVED',
    jsonb_build_object(
      'hitl_id',              v_req.hitl_id,
      'decision',             v_decision::text,
      'approver_id',          v_uid,
      'approvers',            to_jsonb(v_approvers),
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
           v_req.enforced_approvals, v_req.configured_approvals)
      || v_suffix,
    NULL,
    v_decision::text::public.hitl_status,
    v_uid,
    'SUCCESS'::public.execution_status,
    NULL);

  -- 16. The commit path. The run row is the one locked in step 9.
  -- FAO-GOV-004 (fix round 5, K2): the run's invoker must still be an active
  -- owner holding the invoker grant for the agent. The share locks order
  -- this decision against a deactivation or a revoke of that grant (both
  -- update these rows); a new grant is not waited for, which can only turn
  -- a refusal into an allow on a later decision, never the reverse.
  PERFORM 1 FROM public.process_owners po WHERE po.id = v_run.invoker_id FOR SHARE;
  PERFORM 1 FROM public.fao_user_roles ur
    WHERE ur.user_id = v_run.invoker_id
      AND ur.role = 'invoker'::public.fao_app_role
      AND ur.revoked_at IS NULL
    FOR SHARE;
  v_inv_ok := fao_private.has_role(v_run.invoker_id, 'invoker'::public.fao_app_role, v_run.agent_id);

  -- FAO-GOV-002 (fix round 3): the registry status gate holds at commit. The
  -- share lock orders this decision against fao_admin_set_agent, which locks
  -- the row FOR UPDATE; a missing row reads as not ACTIVE (fail closed).
  SELECT ar.status INTO v_status
    FROM public.agent_registry ar
   WHERE ar.agent_id = v_run.agent_id
     FOR SHARE;

  r := fao_private.run_rollup(v_req.correlation_id);

  IF v_decision = 'APPROVED'::public.hitl_decision
     AND v_status IS DISTINCT FROM 'ACTIVE'::public.agent_status THEN
    PERFORM fao_private.append_event(
      v_req.correlation_id,
      'COMMIT_BLOCKED',
      jsonb_build_object(
        'hitl_id',      v_req.hitl_id,
        'problems',     r->'problems',
        'code',         'AGENT_NOT_ACTIVE',
        'agent_status', v_status::text),
      'BLOCKED'::public.policy_outcome,
      NULL,
      format('FAO-GOV-002 agent %s status %s at commit; approved run not committed', v_run.agent_id, coalesce(v_status::text, 'MISSING'))
        || CASE WHEN (r->>'chain_ok')::boolean IS NOT TRUE THEN '; FAO-GOV-001 audit chain incomplete' ELSE '' END,
      NULL,
      v_decision::text::public.hitl_status,
      NULL,
      'FAILURE'::public.execution_status,
      NULL);

    UPDATE public.run_invocations
       SET state = 'FAILED', finished_at = now(), last_error = 'agent not ACTIVE at commit'
     WHERE correlation_id = v_req.correlation_id;

    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'AGENT_NOT_ACTIVE')
      || jsonb_build_object(
           'hitl_id',             v_req.hitl_id,
           'decision',            v_decision::text,
           'decided_at',          v_decided,
           'committed',           false,
           'committed_ledger_id', NULL);
  END IF;

  IF v_decision = 'APPROVED'::public.hitl_decision AND v_inv_ok IS NOT TRUE THEN
    PERFORM fao_private.append_event(
      v_req.correlation_id,
      'COMMIT_BLOCKED',
      jsonb_build_object(
        'hitl_id',      v_req.hitl_id,
        'problems',     r->'problems',
        'code',         'INVOKER_NOT_ACTIVE',
        'reason',       'INVOKER_NOT_ACTIVE',
        'agent_status', v_status::text),
      'BLOCKED'::public.policy_outcome,
      NULL,
      format('FAO-GOV-004 invoker %s is no longer active or no longer an invoker for agent %s at commit; approved run not committed',
             v_run.invoker_id, v_run.agent_id)
        || CASE WHEN (r->>'chain_ok')::boolean IS NOT TRUE THEN '; FAO-GOV-001 audit chain incomplete' ELSE '' END,
      NULL,
      v_decision::text::public.hitl_status,
      NULL,
      'FAILURE'::public.execution_status,
      NULL);

    UPDATE public.run_invocations
       SET state = 'FAILED', finished_at = now(), last_error = 'invoker no longer authorised at commit'
     WHERE correlation_id = v_req.correlation_id;

    RETURN fao_private.refuse(c_entry, 'hitl_queue', v_key, v_attempt, 'INVOKER_NOT_ACTIVE')
      || jsonb_build_object(
           'hitl_id',             v_req.hitl_id,
           'decision',            v_decision::text,
           'decided_at',          v_decided,
           'committed',           false,
           'committed_ledger_id', NULL);
  END IF;

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

COMMENT ON FUNCTION public.fao_hitl_decide(json) IS
  'FAO-GOV-004, FAO-GOV-001, FAO-REC-001: the only client path by which a HITL approval or decision is recorded (an owner-class session is outside the control, FAO-GOV-001); body {p_hitl_id, p_decision, p_notes?}. Approver from auth.uid() only; approver role required, through a qualifying approver grant (DA-4: unrevoked, covering the agent, granted before the request was created, not by the invoker; for an APPROVE, not only grants made by another approver of the request), else NOT_AUTHORISED; the invoker is refused (SOD_SELF_APPROVAL); refused at or after the deadline. Every first APPROVE by a user writes one hitl_approvals row; a repeat APPROVE writes none and is ALREADY_APPROVED unless the approvals that count already reach enforced_approvals, when it decides. An APPROVE that leaves fewer counted approvals than enforced_approvals returns AWAITING_FURTHER_APPROVAL with HITL_APPROVAL_RECORDED and decides nothing; the APPROVE that reaches it, or any eligible REJECT, decides the request: HITL_RESOLVED, rollup and COMMITTED (or COMMIT_BLOCKED with AGENT_NOT_ACTIVE, INVOKER_NOT_ACTIVE or an incomplete chain) in one transaction. Locks taken before any write wait at most 2s (BUSY). Refusals are journaled.';

-- ----------------------------------------------------------------------------
-- 3. fao_notification_context (FAO-GOV-007)
-- ----------------------------------------------------------------------------
-- The 0015 body, codes and envelopes. The send:true envelope gains:
--   enforced_approvals  the request's frozen count
--   approvals_received  cardinality(counted_approvals): approvals that count
--                       now (DA-4 applied in full)
--   approved_by         [{name}] of the counted approvers in approval order;
--                       never the invoker (counted approvals exclude the
--                       invoker); [] when none
-- approver_candidates is unchanged (every active owner holding the approver
-- role for the agent, never the invoker, those who approved included; not
-- filtered by DA-4: the notice is an alert, the database decides).
CREATE OR REPLACE FUNCTION public.fao_notification_context(p_hitl_id bigint, p_kind text, p_level int)
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
  v_counted    uuid[];
  v_approved_by jsonb;
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
    -- FAO-GOV-007 (U11, fix round 5): a target deactivated since the
    -- escalation is never named; the next eligible target is, or none (the
    -- sweep then reports NO_ESCALATION_TARGET for the operator).
    v_target := fao_private.notice_target(v_req.hitl_id, v_target);
    -- FAO-GOV-004: the invoker is never named, even as an escalation target;
    -- nor an inactive owner (belt and braces over notice_target).
    SELECT po.name INTO v_target_nm FROM public.process_owners po
     WHERE po.id = v_target AND po.id <> v_req.agent_invoker_id AND po.active;
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

  -- FAO-GOV-004 (dual approval): the approvals that count now and the names
  -- of those approvers, in approval order.
  v_counted := fao_private.counted_approvals(v_req.hitl_id);
  SELECT coalesce(jsonb_agg(jsonb_build_object('name', po.name) ORDER BY u.ord), '[]'::jsonb)
    INTO v_approved_by
    FROM unnest(v_counted) WITH ORDINALITY AS u(id, ord)
    JOIN public.process_owners po ON po.id = u.id;

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
    'enforced_approvals',  v_req.enforced_approvals,
    'approvals_received',  cardinality(v_counted),
    'approved_by',         v_approved_by,
    'target_name',         v_target_nm,
    'slack_api_base_url',  v_slack_url,
    'slack_channel_id',    v_channel));
END;
$$;

COMMENT ON FUNCTION public.fao_notification_context(bigint, text, int) IS
  'FAO-GOV-007: what the notifier may send for a request, kind and level: send:true with the request summary, approval link, approver candidate names (never the invoker), the enforced approval count, the approvals received and the names of those approvers (never the invoker), and Slack settings; or NOT_FOUND, NOT_PENDING or ALREADY_SENT with send:false.';

-- ----------------------------------------------------------------------------
-- 4. fao_run_summary (FAO-GOV-015, FAO-GOV-008)
-- ----------------------------------------------------------------------------
-- The 0016 view with two columns added at the end: enforced_approvals (the
-- newest request's frozen count) and approvals_recorded (its approval rows,
-- eligible or not; members and the reader read hitl_approvals under its RLS
-- policy). Both NULL for a run with no request. Every existing column keeps
-- its name, type and position (CREATE OR REPLACE VIEW requires it); the
-- grants and the INSTEAD OF trigger fao_run_summary_read_only stay.
CREATE OR REPLACE VIEW public.fao_run_summary WITH (security_invoker = true) AS
WITH ev AS (
  SELECT correlation_id, min(agent_id) AS agent_id,
         min(event_timestamp) AS started_at, max(event_timestamp) AS latest_event_at,
         count(*) AS event_count,
         count(*) FILTER (WHERE inputs->>'event_type' = 'COMMITTED'
                            AND hitl_status IS DISTINCT FROM 'EXPIRED'::public.hitl_status) AS committed_count,
         coalesce(bool_or(inputs->>'event_type' = 'COMMIT_BLOCKED'), false) AS commit_blocked,
         count(*) FILTER (WHERE inputs->>'event_type' = 'CORRECTION') AS correction_count,
         max(ledger_id) FILTER (WHERE inputs->>'event_type' = 'COMMITTED'
                                AND hitl_status IS DISTINCT FROM 'EXPIRED'::public.hitl_status) AS last_committed_id
  FROM public.shadow_ledger GROUP BY correlation_id)
SELECT ev.correlation_id, ev.agent_id, ri.invoker_id, ri.invoked_via, ri.state::text AS run_state,
       ev.started_at, ev.latest_event_at, ev.event_count,
       hq.hitl_id, hq.decision::text AS hitl_decision, hq.decided_at, hq.approver_id,
       lc.policy_outcome::text AS latest_committed_outcome, lc.status::text AS latest_committed_status,
       ev.committed_count, ev.commit_blocked, ev.correction_count, (ri.correlation_id IS NOT NULL) AS has_run_record,
       hq.enforced_approvals,
       hq.approvals_recorded
FROM ev
LEFT JOIN public.run_invocations ri ON ri.correlation_id = ev.correlation_id
LEFT JOIN LATERAL (SELECT h.hitl_id, h.decision, h.decided_at, h.approver_id,
                          h.enforced_approvals,
                          (SELECT count(*) FROM public.hitl_approvals a
                            WHERE a.hitl_id = h.hitl_id) AS approvals_recorded
                     FROM public.hitl_queue h
                    WHERE h.correlation_id = ev.correlation_id
                    ORDER BY h.hitl_id DESC LIMIT 1) hq ON true
LEFT JOIN public.shadow_ledger lc ON lc.ledger_id = ev.last_committed_id;

COMMENT ON VIEW public.fao_run_summary IS
  'FAO-GOV-015, FAO-GOV-008: one row per correlation id in the Shadow Ledger: run record fields, newest request and decision (approver_id is the user whose call decided it), latest COMMITTED outcome and status (a COMMITTED row with hitl_status EXPIRED is never counted: an expired request is not a commit), commit-blocked and correction counts, and for the newest request its enforced approval count and the number of approvals recorded (approval rows, eligible or not). Security invoker; readable by members and the reader under RLS.';
