-- ============================================================================
-- FinAgent OS: Migration 0018: dual approval schema and guards
-- ============================================================================
-- Dual approval (owner decisions DA-1 to DA-4 of 2026-11-08, ADR-0004):
--   1. public.hitl_approvals: one row per approval of a HITL request, written
--      only by fao_hitl_decide with the approver's own session, append-only
--      (no UPDATE or DELETE) for every role, the owner included; members read
--      it under RLS. The INSERT rules trust the session's auth.uid(): an
--      owner-class session that sets its own request.jwt.claims can insert a
--      row as any eligible approver (the owner is outside the control,
--      FAO-GOV-001).
--   2. fao_private.approver_qualifies: the one statement of the DA-4
--      qualifying approver grant test (unrevoked, covering the agent, granted
--      strictly before the request was created, not by the invoker; with the
--      co-approver rule, not only by another approver of the request).
--   3. Row and statement guards on hitl_approvals; no TRUNCATE.
--   4. fao_private.counted_approvals: the approvals of a request that count
--      now (approver eligible and holding a qualifying grant).
--   5. The hitl_queue row guard: a new request records the registry approval
--      threshold and enforces it only for CRITICAL review (DA-1); an APPROVED
--      decision needs enforced_approvals counted approvals, the approver's
--      among them; a REJECTED decision needs a qualifying grant (DA-4).
--   6. append_event accepts HITL_APPROVAL_RECORDED; the fixed codes gain
--      AWAITING_FURTHER_APPROVAL and ALREADY_APPROVED; create_request sets
--      enforced_approvals by DA-1.
--   7. Report: PENDING CRITICAL requests created before this file keep
--      enforced_approvals 1 (no hitl_queue row is updated here).
--
-- Control IDs implemented:
--   FAO-GOV-004  dual approval for CRITICAL review: approvals recorded per
--                approver, one user counts once, never the invoker, only
--                through a qualifying approver grant (DA-4); no APPROVED
--                decision without its counted approvals, for every role
--   FAO-GOV-001  approvals are append-only evidence; the new ledger event
--                type is written only through append_event
--   FAO-GOV-008  fixed codes and messages for the two new results
--
-- Replaces (CREATE OR REPLACE, same signatures, volatility, security and
-- search_path):
--   - fao_private.hitl_queue_guard_row()   (migration 0013)
--   - fao_private.append_event(...)        (migration 0012)
--   - fao_private.code_message(text)       (migration 0011)
--   - fao_private.code_http(text)          (migration 0011)
--   - fao_private.create_request(uuid, jsonb) (migration 0012)
--   - the COMMENT on hitl_queue.enforced_approvals (migration 0010)
--
-- Must work applied on its own, as one transaction with 0019 and 0020 on a
-- live core, and inside the cutover bundle 0010 to 0020: no CREATE INDEX
-- CONCURRENTLY, no VACUUM, no transaction control, no enum change, no
-- configuration table change.
--
-- Rollback: see phase2-5/rollback/rollback_dual_approval.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Table public.hitl_approvals (FAO-GOV-004, FAO-GOV-001)
-- ----------------------------------------------------------------------------
CREATE TABLE public.hitl_approvals (
  approval_id     bigserial    PRIMARY KEY,
  hitl_id         bigint       NOT NULL
                  CONSTRAINT hitl_approvals_hitl_id_fkey
                  REFERENCES public.hitl_queue(hitl_id) ON DELETE RESTRICT,
  approver_id     uuid         NOT NULL
                  CONSTRAINT hitl_approvals_approver_id_fkey
                  REFERENCES public.process_owners(id) ON DELETE RESTRICT,
  approved_at     timestamptz  NOT NULL,
  decision_notes  text         NULL
                  CONSTRAINT hitl_approvals_notes_length
                  CHECK (decision_notes IS NULL OR length(decision_notes) <= 2000),
  CONSTRAINT hitl_approvals_one_per_approver UNIQUE (hitl_id, approver_id)
);

ALTER TABLE public.hitl_approvals ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE    public.hitl_approvals                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON SEQUENCE public.hitl_approvals_approval_id_seq FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

COMMENT ON TABLE public.hitl_approvals IS
  'FAO-GOV-004: one row per approval of a HITL request (dual approval, ADR-0004). Written by fao_hitl_decide with the approver''s own session (client roles have no other path; an owner-class session that sets its own JWT claims can insert as any eligible approver, outside the control per FAO-GOV-001); one row per approver per request; append-only (no UPDATE or DELETE) for every role, the owner included (row guard fao_private.hitl_approvals_guard_row). Members read under RLS (has_any_role).';
COMMENT ON COLUMN public.hitl_approvals.approver_id IS
  'FAO-GOV-004: the signed-in approver (auth.uid()), never the invoker, holding the approver role for the agent when the row was written.';
COMMENT ON COLUMN public.hitl_approvals.approved_at IS
  'FAO-GOV-004: the FinAgent clock (fao_private.clock()) at the approval.';

-- ----------------------------------------------------------------------------
-- 2. RLS (FAO-GOV-004): members read every row; no write policy exists and
--    no client role holds a write grant. Same USING as hitl_queue (patch
--    round 6 P6 form: the helper runs once per statement).
-- ----------------------------------------------------------------------------
CREATE POLICY "FAO members read hitl_approvals"
  ON public.hitl_approvals
  FOR SELECT
  TO authenticated
  USING ((select fao_private.has_any_role((select auth.uid()))));

-- ----------------------------------------------------------------------------
-- 3. approver_qualifies (FAO-GOV-004, DA-4)
-- ----------------------------------------------------------------------------
-- For request R and user U: true when U holds an unrevoked approver grant
-- covering R's agent (global or per agent), granted strictly before R was
-- created, not granted by R's invoker (a NULL granted_by qualifies); with
-- p_co_approver_rule, also not granted by another user who has an approval
-- row on R (raw rows, counted or not, so no recursion). False for a missing
-- request or user; never raises. Does not call has_role: the callers keep
-- has_role (active owner row, U12 frame rule) and the invoker exclusion.
CREATE FUNCTION fao_private.approver_qualifies(p_hitl_id bigint, p_uid uuid, p_co_approver_rule boolean)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN coalesce((
    SELECT EXISTS (
             SELECT 1
               FROM public.fao_user_roles ur
              WHERE ur.user_id = p_uid
                AND ur.role = 'approver'::public.fao_app_role
                AND ur.revoked_at IS NULL
                AND (ur.agent_id IS NULL OR ur.agent_id = h.agent_id)
                AND ur.granted_at < h.created_at
                AND ur.granted_by IS DISTINCT FROM h.agent_invoker_id
                AND (p_co_approver_rule IS NOT TRUE
                     OR ur.granted_by IS NULL
                     OR NOT EXISTS (SELECT 1
                                      FROM public.hitl_approvals a
                                     WHERE a.hitl_id = h.hitl_id
                                       AND a.approver_id = ur.granted_by
                                       AND a.approver_id IS DISTINCT FROM p_uid)))
      FROM public.hitl_queue h
     WHERE h.hitl_id = p_hitl_id), false);
END;
$$;

COMMENT ON FUNCTION fao_private.approver_qualifies(bigint, uuid, boolean) IS
  'FAO-GOV-004 (DA-4): true when the user holds a qualifying approver grant for the request: unrevoked, covering the agent (global or per agent), granted strictly before the request was created, not granted by the invoker (a NULL granted_by qualifies); with p_co_approver_rule, also not granted by another approver of the request (any hitl_approvals row of another user). False for a missing request or user. Reads grant rows only (owner_active and the invoker check stay in the callers). No grants.';

-- ----------------------------------------------------------------------------
-- 4. Guards on hitl_approvals (FAO-GOV-004, FAO-GOV-001)
-- ----------------------------------------------------------------------------
-- Hold for every role, the owner included; no branch skips a rule when no
-- session user is set. The INSERT rules judge the user auth.uid() names, so
-- an owner-class session that sets its own JWT claims passes them as that
-- user (owner outside the control, FAO-GOV-001).
--   statement: any write by a role outside the owner class is refused
--              (backstop; no client role holds a write grant).
--   row:       UPDATE and DELETE refused (append-only); INSERT only by the
--              signed-in approver, for a PENDING request before its
--              deadline whose run awaits a decision, never the invoker,
--              holding the approver role for the agent and a qualifying
--              approver grant not made by another approver of the request
--              (DA-4), at the FinAgent clock, with valid notes.
CREATE FUNCTION fao_private.hitl_approvals_guard_stmt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF current_user NOT IN ('postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'FAO-GOV-004: direct % on hitl_approvals is not permitted; approvals are recorded only through fao_hitl_decide', TG_OP
      USING ERRCODE = '42501';
  END IF;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION fao_private.hitl_approvals_guard_stmt() IS
  'FAO-GOV-004: statement trigger on hitl_approvals that refuses any write by a role outside the owner class. Backstop; no client role holds a write grant.';

CREATE FUNCTION fao_private.hitl_approvals_guard_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid;
  v_req public.hitl_queue%ROWTYPE;
  v_run public.run_invocations%ROWTYPE;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    RAISE EXCEPTION 'FAO-GOV-004: approvals cannot be changed or deleted (approval_id %)', OLD.approval_id
      USING ERRCODE = '42501';
  END IF;

  -- INSERT
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'FAO-GOV-004: an approval needs a signed-in approver (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;
  IF NEW.approver_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'FAO-GOV-004: the approver must be the signed-in user (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_req FROM public.hitl_queue h WHERE h.hitl_id = NEW.hitl_id;
  IF NOT FOUND
     OR v_req.decision IS DISTINCT FROM 'PENDING'::public.hitl_decision
     OR (fao_private.clock() < v_req.timeout_at) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAO-GOV-004: approvals are recorded only for a PENDING request before its deadline (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_run FROM public.run_invocations ri WHERE ri.correlation_id = v_req.correlation_id;
  IF NOT FOUND OR v_run.state IS DISTINCT FROM 'AWAITING_HITL'::public.fao_run_state THEN
    RAISE EXCEPTION 'FAO-GOV-004: approvals are recorded only while the run awaits a decision (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  IF NEW.approver_id = v_req.agent_invoker_id OR NEW.approver_id = v_run.invoker_id THEN
    RAISE EXCEPTION 'FAO-GOV-004: segregation of duties: the invoker cannot approve their own run (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  IF NOT fao_private.has_role(NEW.approver_id, 'approver'::public.fao_app_role, v_req.agent_id) THEN
    RAISE EXCEPTION 'FAO-GOV-004: the approver does not hold the approver role for this agent (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  -- DA-4: a qualifying grant that was not made by another approver of the request.
  IF NOT fao_private.approver_qualifies(NEW.hitl_id, NEW.approver_id, true) THEN
    RAISE EXCEPTION 'FAO-GOV-004: the approver holds no qualifying approver grant for this request (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  IF NEW.approved_at IS DISTINCT FROM fao_private.clock() THEN
    RAISE EXCEPTION 'FAO-GOV-004: the approval time must be the FinAgent clock (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  IF NEW.decision_notes IS NOT NULL AND NOT fao_private.text_ok(NEW.decision_notes, 0, 2000) THEN
    RAISE EXCEPTION 'FAO-GOV-004: approval notes are not valid (hitl_id %)', NEW.hitl_id
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fao_private.hitl_approvals_guard_row() IS
  'FAO-GOV-004: row trigger on hitl_approvals for every role: no UPDATE or DELETE; an INSERT only by the signed-in approver, for a PENDING request before its deadline whose run awaits a decision, never the invoker, holding the approver role for the agent and a qualifying approver grant not made by another approver of the request (DA-4), at the FinAgent clock, with valid notes.';

CREATE TRIGGER hitl_approvals_guard_stmt
  BEFORE INSERT OR UPDATE OR DELETE ON public.hitl_approvals
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.hitl_approvals_guard_stmt();
CREATE TRIGGER hitl_approvals_guard_row
  BEFORE INSERT OR UPDATE OR DELETE ON public.hitl_approvals
  FOR EACH ROW EXECUTE FUNCTION fao_private.hitl_approvals_guard_row();
CREATE TRIGGER hitl_approvals_deny_truncate
  BEFORE TRUNCATE ON public.hitl_approvals
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();

-- ----------------------------------------------------------------------------
-- 5. counted_approvals (FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- The approver ids, in approval order, of the approvals of a request that
-- count now: approver not the invoker (request or run), holding the
-- approver role for the agent with an active owner row (has_role), and
-- holding a qualifying approver grant not made by another approver of the
-- request (approver_qualifies with the co-approver rule, DA-4), applied in
-- full on every call. LANGUAGE plpgsql (C17): role_query_allowed honours a
-- question about another user only when the nearest frame is a PL/pgSQL
-- FinAgent function. Never raises; a missing request gives an empty array.
CREATE FUNCTION fao_private.counted_approvals(p_hitl_id bigint)
RETURNS uuid[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v uuid[];
BEGIN
  SELECT coalesce(array_agg(a.approver_id ORDER BY a.approval_id), ARRAY[]::uuid[])
    INTO v
    FROM public.hitl_approvals a
    JOIN public.hitl_queue h ON h.hitl_id = a.hitl_id
    LEFT JOIN public.run_invocations ri ON ri.correlation_id = h.correlation_id
   WHERE a.hitl_id = p_hitl_id
     AND a.approver_id <> h.agent_invoker_id
     AND a.approver_id IS DISTINCT FROM ri.invoker_id
     AND fao_private.has_role(a.approver_id, 'approver'::public.fao_app_role, h.agent_id)
     AND fao_private.approver_qualifies(a.hitl_id, a.approver_id, true);
  RETURN v;
END;
$$;

COMMENT ON FUNCTION fao_private.counted_approvals(bigint) IS
  'FAO-GOV-004: the approver ids, in approval order, of the approvals of a request that count now: approver not the invoker, still holding the approver role for the agent with an active owner row (has_role), and holding a qualifying approver grant for the request not made by another approver of it (approver_qualifies, DA-4). Empty array when none. LANGUAGE plpgsql so has_role answers for other users (U12 caller rule). No grants.';

-- ----------------------------------------------------------------------------
-- 6. hitl_queue row guard (FAO-GOV-004), replacing the 0013 body
-- ----------------------------------------------------------------------------
-- Holds for every role, the owner included. There is no branch that skips a
-- rule when no session user is set. Rules about the deciding user judge the
-- user auth.uid() names, so an owner-class session that sets its own JWT
-- claims passes them as that user (owner outside the control, FAO-GOV-001).
--   DELETE: refused.
--   INSERT: PENDING with no approver, decision time or notes; a RUNNING run
--           record with the same agent, invoker and tier; tier not BLOCKED;
--           no other request for the run; deadline in the future;
--           configured_approvals equal to the registry approval threshold
--           and enforced_approvals equal to it for CRITICAL review, else 1
--           (DA-1).
--   UPDATE: only a PENDING row may change; only decision, approver_id,
--           decided_at and decision_notes may change;
--           to APPROVED or REJECTED: the approver is the session user, is not
--           the invoker, holds the approver role for the agent, and the
--           deadline has not passed; APPROVED also needs at least
--           enforced_approvals counted approvals with the approver among
--           them; REJECTED also needs a qualifying approver grant (DA-4);
--           to EXPIRED: no approver, and the deadline has passed;
--           anything else (PENDING to PENDING included): refused.
CREATE OR REPLACE FUNCTION fao_private.hitl_queue_guard_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid;
  v_frozen text[] := ARRAY['decision', 'approver_id', 'decided_at', 'decision_notes'];
  v_threshold int;
  v_counted uuid[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FAO-GOV-004: hitl_queue rows cannot be deleted'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.decision IS DISTINCT FROM 'PENDING'::public.hitl_decision
       OR NEW.approver_id IS NOT NULL
       OR NEW.decided_at IS NOT NULL
       OR NEW.decision_notes IS NOT NULL THEN
      RAISE EXCEPTION 'FAO-GOV-004: a request must be created PENDING with no approver, decision time or notes'
        USING ERRCODE = '42501';
    END IF;
    IF NEW.risk_tier IS NOT DISTINCT FROM 'BLOCKED'::public.risk_tier THEN
      RAISE EXCEPTION 'FAO-GOV-004: a request cannot have tier BLOCKED'
        USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (
      SELECT 1
        FROM public.run_invocations ri
       WHERE ri.correlation_id = NEW.correlation_id
         AND ri.state = 'RUNNING'::public.fao_run_state
         AND ri.agent_id = NEW.agent_id
         AND ri.invoker_id = NEW.agent_invoker_id
         AND ri.risk_tier = NEW.risk_tier
    ) THEN
      RAISE EXCEPTION 'FAO-GOV-004: a request needs a RUNNING run record with the same agent, invoker and tier'
        USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.hitl_queue h WHERE h.correlation_id = NEW.correlation_id) THEN
      RAISE EXCEPTION 'FAO-GOV-004: the run already has a request'
        USING ERRCODE = '42501';
    END IF;
    IF (NEW.timeout_at > fao_private.clock()) IS NOT TRUE THEN
      RAISE EXCEPTION 'FAO-GOV-004: a request needs a deadline in the future'
        USING ERRCODE = '42501';
    END IF;
    SELECT ar.approval_threshold INTO v_threshold
      FROM public.agent_registry ar
     WHERE ar.agent_id = NEW.agent_id;
    IF NEW.configured_approvals IS DISTINCT FROM v_threshold
       OR NEW.enforced_approvals IS DISTINCT FROM
            (CASE WHEN NEW.sub_tier IS NOT DISTINCT FROM 'CRITICAL'::public.policy_sub_tier
                  THEN NEW.configured_approvals ELSE 1 END) THEN
      RAISE EXCEPTION 'FAO-GOV-004: a request must record the registry approval threshold and enforce it only for CRITICAL review'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF OLD.decision IS DISTINCT FROM 'PENDING'::public.hitl_decision THEN
    RAISE EXCEPTION 'FAO-GOV-004: decided requests are immutable (hitl_id %)', OLD.hitl_id
      USING ERRCODE = '42501';
  END IF;

  IF (to_jsonb(NEW) - v_frozen) IS DISTINCT FROM (to_jsonb(OLD) - v_frozen) THEN
    RAISE EXCEPTION 'FAO-GOV-004: only the decision fields of a request may change (hitl_id %)', OLD.hitl_id
      USING ERRCODE = '42501';
  END IF;

  IF NEW.decision IN ('APPROVED'::public.hitl_decision, 'REJECTED'::public.hitl_decision) THEN
    BEGIN
      v_uid := auth.uid();
    EXCEPTION WHEN others THEN
      v_uid := NULL;
    END;
    IF v_uid IS NULL THEN
      RAISE EXCEPTION 'FAO-GOV-004: a decision needs a signed-in approver (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    IF NEW.approver_id IS DISTINCT FROM v_uid THEN
      RAISE EXCEPTION 'FAO-GOV-004: the approver must be the signed-in user (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    IF NEW.approver_id = OLD.agent_invoker_id THEN
      RAISE EXCEPTION 'FAO-GOV-004: segregation of duties: the invoker cannot decide their own run (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    IF NOT fao_private.has_role(NEW.approver_id, 'approver'::public.fao_app_role, OLD.agent_id) THEN
      RAISE EXCEPTION 'FAO-GOV-004: the approver does not hold the approver role for this agent (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    IF (fao_private.clock() < OLD.timeout_at) IS NOT TRUE THEN
      RAISE EXCEPTION 'FAO-GOV-004: the request deadline has passed (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    IF NEW.decision = 'APPROVED'::public.hitl_decision THEN
      v_counted := fao_private.counted_approvals(OLD.hitl_id);
      IF cardinality(v_counted) < OLD.enforced_approvals
         OR NOT (NEW.approver_id = ANY (v_counted)) THEN
        RAISE EXCEPTION 'FAO-GOV-004: an approval decision needs the enforced number of counted approvals, the approver''s among them (hitl_id %)', OLD.hitl_id
          USING ERRCODE = '42501';
      END IF;
    ELSIF NOT fao_private.approver_qualifies(OLD.hitl_id, NEW.approver_id, false) THEN
      RAISE EXCEPTION 'FAO-GOV-004: the approver holds no qualifying approver grant for this request (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.decision = 'EXPIRED'::public.hitl_decision THEN
    IF NEW.approver_id IS NOT NULL THEN
      RAISE EXCEPTION 'FAO-GOV-004: an expired request has no approver (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    IF (fao_private.clock() >= OLD.timeout_at) IS NOT TRUE THEN
      RAISE EXCEPTION 'FAO-GOV-004: a request cannot expire before its deadline (hitl_id %)', OLD.hitl_id
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'FAO-GOV-004: transition not permitted on hitl_queue (hitl_id %)', OLD.hitl_id
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION fao_private.hitl_queue_guard_row() IS
  'FAO-GOV-004: row trigger on hitl_queue for every role: no DELETE; inserts only PENDING for a RUNNING run, with configured_approvals equal to the registry threshold and enforced_approvals equal to it for CRITICAL review, else 1; decided rows immutable; frozen fields; APPROVED or REJECTED only by the signed-in approver who is not the invoker and holds a qualifying approver grant for the request (DA-4), before the deadline; APPROVED only with at least enforced_approvals counted approvals in hitl_approvals, the approver''s among them; EXPIRED only after the deadline.';

COMMENT ON COLUMN public.hitl_queue.enforced_approvals IS
  'FAO-GOV-004: approval count enforced for this request, set at creation by DA-1: configured_approvals for CRITICAL review, else 1 (ADR-0004; requests created before 0018 keep 1). Frozen.';

-- ----------------------------------------------------------------------------
-- 7. append_event (FAO-GOV-001), replacing the 0012 body: the allowed list
--    gains HITL_APPROVAL_RECORDED (written by fao_hitl_decide for an
--    approval that does not decide the request). Nothing else changes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fao_private.append_event(
  p_correlation_id   uuid,
  p_event_type       text,
  p_inputs           jsonb,
  p_policy_outcome   public.policy_outcome,
  p_sub_tier         public.policy_sub_tier,
  p_rationale        text,
  p_obligations      text[],
  p_hitl_status      public.hitl_status,
  p_hitl_approver_id uuid,
  p_status           public.execution_status,
  p_error            text,
  p_corrects         bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v   record;
  v_id bigint;
BEGIN
  IF p_event_type IS NULL OR p_event_type NOT IN (
       'STARTED', 'ASSET_RECONCILED', 'FAILED', 'RUN_REFUSED', 'HITL_REQUESTED',
       'NOTIFICATION_SENT', 'NOTIFICATION_FAILED', 'HITL_RESOLVED', 'HITL_APPROVAL_RECORDED',
       'HITL_EXPIRED', 'HITL_ESCALATED', 'COMMITTED', 'COMMIT_BLOCKED', 'CORRECTION') THEN
    RAISE EXCEPTION 'FAO-GOV-001 append_event: unknown event type %', coalesce(p_event_type, '<null>')
      USING ERRCODE = '22023';
  END IF;

  IF p_inputs IS NOT NULL AND jsonb_typeof(p_inputs) <> 'object' THEN
    RAISE EXCEPTION 'FAO-GOV-001 append_event: inputs must be an object'
      USING ERRCODE = '22023';
  END IF;

  v := fao_private.run_context(p_correlation_id);

  INSERT INTO public.shadow_ledger (
    correlation_id, execution_id, agent_id, risk_tier, inputs,
    policy_outcome, policy_sub_tier, policy_rationale, obligations,
    hitl_status, hitl_approver_id, status, error_details, corrects_ledger_id
  )
  VALUES (
    p_correlation_id, v.execution_id, v.agent_id, v.risk_tier,
    coalesce(p_inputs, '{}'::jsonb) || jsonb_build_object('event_type', p_event_type),
    p_policy_outcome, p_sub_tier, p_rationale, coalesce(p_obligations, ARRAY[]::text[]),
    coalesce(p_hitl_status, 'NOT_REQUIRED'::public.hitl_status), p_hitl_approver_id,
    p_status, p_error, p_corrects
  )
  RETURNING ledger_id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION fao_private.append_event(uuid, text, jsonb, public.policy_outcome, public.policy_sub_tier, text, text[], public.hitl_status, uuid, public.execution_status, text, bigint) IS
  'FAO-GOV-001: the only insert point for database-written ledger events. Context from run_context, inputs.event_type forced, timestamp from the database. Returns ledger_id.';

-- ----------------------------------------------------------------------------
-- 8. Fixed codes (FAO-GOV-008), replacing the 0011 bodies: two results added
--    after ALREADY_SENT (AWAITING_FURTHER_APPROVAL 200, ALREADY_APPROVED
--    409). An unknown code still raises.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fao_private.code_message(p_code text)
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
    WHEN 'INVOKER_NOT_ACTIVE'   THEN 'The invoker is no longer authorised for this agent.'
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
    WHEN 'AWAITING_FURTHER_APPROVAL' THEN 'Approval recorded. This request needs more approvals before it is decided.'
    WHEN 'ALREADY_APPROVED'     THEN 'You have already approved this request.'
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

CREATE OR REPLACE FUNCTION fao_private.code_http(p_code text)
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
    WHEN 'INVOKER_NOT_ACTIVE'   THEN 409
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
    WHEN 'AWAITING_FURTHER_APPROVAL' THEN 200
    WHEN 'ALREADY_APPROVED'     THEN 409
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
-- 9. create_request (FAO-GOV-004, FAO-GOV-007), replacing the 0012 body
-- ----------------------------------------------------------------------------
-- Opens the HITL request for a RUNNING run whose rollup needs review and
-- appends HITL_REQUESTED, in the caller's transaction (fao_run_finalize).
--   1. The run and its agent; the agent must be ACTIVE with an SLA for HITL
--      resolution, else raise.
--   2. The approval link base from settings; missing raises.
--   3. The id is taken from the sequence first, so the link can be stored on
--      insert (no later update of a frozen field).
--   4. Insert the request: tier and invoker from the run, review sub-tier,
--      rationale, configured approvals from the registry, enforced approvals
--      by DA-1 (the configured count for CRITICAL review, else 1), approval
--      link, escalated assets, deadline from the clock.
--   5. Append HITL_REQUESTED.
--   6. Return {hitl_id, approval_url, timeout_at, hitl_requested_ledger_id}.
-- The hitl_queue row guard re-checks the insert against the run and the
-- registry.
CREATE OR REPLACE FUNCTION fao_private.create_request(p_correlation_id uuid, p_rollup jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_run       public.run_invocations%ROWTYPE;
  v_agent     public.agent_registry%ROWTYPE;
  v_base      text;
  v_channel   text;
  v_id        bigint;
  v_url       text;
  v_timeout   timestamptz;
  v_sub_tier  public.policy_sub_tier;
  v_rationale text;
  v_escalated jsonb;
  v_ledger_id bigint;
  v_enforced  int;
BEGIN
  IF p_rollup IS NULL
     OR (p_rollup->>'chain_ok')::boolean IS NOT TRUE
     OR (p_rollup->>'hitl_required')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAO-GOV-004 create_request: the rollup does not require review'
      USING ERRCODE = '22023';
  END IF;

  -- 1
  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.correlation_id = p_correlation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAO-GOV-004 create_request: no run record for %', p_correlation_id
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_agent
    FROM public.agent_registry ar
   WHERE ar.agent_id = v_run.agent_id;
  IF NOT FOUND
     OR v_agent.status <> 'ACTIVE'::public.agent_status
     OR v_agent.sla_max_hitl_resolution_hrs IS NULL THEN
    RAISE EXCEPTION 'FAO-GOV-004 create_request: agent % cannot open a request', v_run.agent_id
      USING ERRCODE = '42501';
  END IF;

  -- 2
  v_base := rtrim((SELECT s.value FROM public.fao_settings s WHERE s.key = 'approval_app_base_url'), '/');
  IF v_base IS NULL OR v_base = '' THEN
    RAISE EXCEPTION 'FAO-GOV-007 create_request: approval_app_base_url is not set'
      USING ERRCODE = '22023';
  END IF;
  v_channel := (SELECT s.value FROM public.fao_settings s WHERE s.key = 'slack_channel_id');

  -- 3
  v_id      := nextval(pg_catalog.pg_get_serial_sequence('public.hitl_queue', 'hitl_id'));
  v_url     := v_base || '/?hitl_id=' || v_id::text;
  v_timeout := fao_private.clock() + make_interval(hours => v_agent.sla_max_hitl_resolution_hrs);

  v_sub_tier  := coalesce(p_rollup->>'review_sub_tier', 'STANDARD')::public.policy_sub_tier;
  v_enforced  := CASE WHEN v_sub_tier = 'CRITICAL'::public.policy_sub_tier
                      THEN v_agent.approval_threshold ELSE 1 END;
  v_rationale := fao_private.compose_rationale(p_rollup, 'HITL_REQUEST');
  v_escalated := coalesce(p_rollup->'escalated_assets', '[]'::jsonb);

  -- 4
  INSERT INTO public.hitl_queue (
    hitl_id, correlation_id, agent_id, agent_invoker_id, risk_tier, sub_tier,
    policy_rationale, timeout_at, configured_approvals, enforced_approvals,
    approval_url, escalated_assets
  )
  VALUES (
    v_id, v_run.correlation_id, v_run.agent_id, v_run.invoker_id, v_run.risk_tier, v_sub_tier,
    v_rationale, v_timeout, v_agent.approval_threshold, v_enforced,
    v_url, v_escalated
  );

  -- 5
  v_ledger_id := fao_private.append_event(
    v_run.correlation_id,
    'HITL_REQUESTED',
    jsonb_build_object(
      'hitl_id',              v_id,
      'agent_invoker_id',     v_run.invoker_id,
      'timeout_at',           v_timeout,
      'sub_tier',             v_sub_tier,
      'configured_approvals', v_agent.approval_threshold,
      'enforced_approvals',   v_enforced,
      'approval_url',         v_url,
      'notification_channel', 'slack',
      'slack_channel_id',     v_channel,
      'escalated_assets',     v_escalated,
      'per_asset_summary',    coalesce(p_rollup->'per_asset_summary', '[]'::jsonb)),
    'REQUIRE_HUMAN'::public.policy_outcome,
    v_sub_tier,
    v_rationale,
    NULL,
    'PENDING'::public.hitl_status,
    NULL,
    'SUCCESS'::public.execution_status,
    NULL);

  -- 6
  RETURN jsonb_build_object(
    'hitl_id',                  v_id,
    'approval_url',             v_url,
    'timeout_at',               v_timeout,
    'hitl_requested_ledger_id', v_ledger_id);
END;
$$;

COMMENT ON FUNCTION fao_private.create_request(uuid, jsonb) IS
  'FAO-GOV-004, FAO-GOV-007: opens the HITL request for a run that needs review (configured approvals from the registry; enforced approvals equal to it for CRITICAL review, else 1, both frozen; review sub-tier; approval link from settings plus the id only; deadline from the agent SLA) and appends HITL_REQUESTED in the same transaction.';

-- ----------------------------------------------------------------------------
-- 10. Revoke the four new functions from every client role. No client role
--     is ever granted any of them (0020 grants only SELECT on the table).
--     The replaced functions keep the privileges 0017 left them.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION fao_private.approver_qualifies(bigint, uuid, boolean) FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.counted_approvals(bigint)                  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.hitl_approvals_guard_stmt()                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.hitl_approvals_guard_row()                 FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

-- ----------------------------------------------------------------------------
-- 11. Legacy report (DA-1, last sentence): requests PENDING when this file
--     lands keep the enforced_approvals frozen at their creation (1). The
--     owner copies the number into the log.
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM public.hitl_queue
   WHERE decision = 'PENDING'
     AND sub_tier = 'CRITICAL'
     AND enforced_approvals < configured_approvals;
  RAISE NOTICE 'FAO-GOV-004 0018: % PENDING CRITICAL requests created before dual approval keep enforced_approvals 1', v_n;
END $$;
