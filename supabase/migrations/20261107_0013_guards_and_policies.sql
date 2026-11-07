-- ============================================================================
-- FinAgent OS: Migration 0013: legacy closure, guard triggers, RLS policies
-- and trigger attachment
-- ============================================================================
-- 1. Closes every HITL request still PENDING from before run records existed
--    (EXPIRED, with a HITL_EXPIRED ledger event), before any new guard exists.
-- 2. Replaces the v1 SoD trigger with guards that hold for every role:
--    decisions only through the decision
--    RPC, decided rows immutable, frozen fields frozen, run and token state
--    machines enforced, role grants revoked instead of deleted.
-- 3. Replaces the v1 RLS policies: members read the evidence tables, admin
--    and reader read the journal, audit, notifications and settings, the
--    workflow role reads thresholds; no client write policy remains.
-- 4. Attaches the generic triggers from 0011: no TRUNCATE on every FinAgent
--    table, change reason and admin audit on configuration tables, updated_at.
--
-- Control IDs implemented:
--   FAO-GOV-001  no TRUNCATE for any role (the owner included, unless the
--                trigger is disabled); member-only reads of the ledger
--   FAO-GOV-002  change reason and audit images for configuration tables
--   FAO-GOV-004  decisions recorded only by fao_hitl_decide: approver from the
--                session, never the invoker, holding the approver role, before
--                the deadline; decided rows immutable; frozen request fields
--   FAO-GOV-008  run and run token state machines; legacy requests closed
--
-- Replaces:
--   - trigger hitl_queue_sod_guard and function public.hitl_queue_enforce_sod()
--     (migration 0005b), superseded by guards that apply to every role
--   - the v1 policies on hitl_queue, shadow_ledger, process_owners,
--     agent_registry and materiality_thresholds (0002 to 0006, 0005c)
--
-- Must work applied on its own and inside one transaction with 0010 to 0017.
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Legacy closure, first (FAO-GOV-004, FAO-GOV-008)
-- ----------------------------------------------------------------------------
-- Every hitl_queue row still PENDING with no run record is closed as EXPIRED
-- with a HITL_EXPIRED event (source cutover). This runs before the new guards
-- exist; the v1 trigger lets it through because no session user is set. On a
-- fresh local database it closes nothing. The logic is a function (no grants)
-- so the tests can prove it.
CREATE FUNCTION fao_private.close_legacy_requests()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r     record;
  v_now timestamptz := now();
  v_n   int := 0;
BEGIN
  FOR r IN
    SELECT h.hitl_id, h.correlation_id, h.sub_tier, h.timeout_at
      FROM public.hitl_queue h
     WHERE h.decision = 'PENDING'
       AND NOT EXISTS (SELECT 1 FROM public.run_invocations ri WHERE ri.correlation_id = h.correlation_id)
     ORDER BY h.hitl_id
       FOR UPDATE
  LOOP
    UPDATE public.hitl_queue
       SET decision       = 'EXPIRED',
           decided_at     = v_now,
           decision_notes = 'closed at phase 2-5 cutover'
     WHERE hitl_id = r.hitl_id;

    PERFORM fao_private.append_event(
      r.correlation_id,
      'HITL_EXPIRED',
      jsonb_build_object(
        'hitl_id',    r.hitl_id,
        'timeout_at', r.timeout_at,
        'expired_at', v_now,
        'source',     'cutover'),
      'REQUIRE_HUMAN'::public.policy_outcome,
      r.sub_tier,
      format('FAO-GOV-004 hitl_id %s expired without a decision (%s)', r.hitl_id, 'cutover'),
      NULL,
      'EXPIRED'::public.hitl_status,
      NULL,
      'FAILURE'::public.execution_status,
      NULL);

    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$$;

COMMENT ON FUNCTION fao_private.close_legacy_requests() IS
  'FAO-GOV-004, FAO-GOV-008: closes PENDING requests that have no run record as EXPIRED with a HITL_EXPIRED event (source cutover). Called once by migration 0013 before the guards exist; returns the number closed.';

REVOKE ALL ON FUNCTION fao_private.close_legacy_requests() FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

SELECT set_config('fao.change_reason', 'migration 0013: close requests created before run records existed', true);
SELECT fao_private.close_legacy_requests() AS legacy_requests_closed;

-- FAO-GOV-004 (fix round 2 R31): the tier CHECK comes after the closure. A
-- NOT VALID CHECK still applies to UPDATEs, so added earlier (it was in 0010)
-- it refused the closure of a v1 PENDING request with tier BLOCKED and the
-- whole cutover bundle aborted. Closed BLOCKED rows stay as recorded; every
-- new or changed row is checked from here on.
ALTER TABLE public.hitl_queue ADD CONSTRAINT hitl_tier_not_blocked
  CHECK (risk_tier <> 'BLOCKED') NOT VALID;

-- ----------------------------------------------------------------------------
-- 2. Retire the v1 SoD trigger (superseded by the guards below).
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS hitl_queue_sod_guard ON public.hitl_queue;
DROP FUNCTION IF EXISTS public.hitl_queue_enforce_sod();

-- ----------------------------------------------------------------------------
-- 3. hitl_queue statement guard (FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- Any INSERT, UPDATE or DELETE on hitl_queue whose current role is not the
-- owner class is refused. No client role holds a write grant in wave 1, so
-- this is a backstop against a future accidental grant. Writes by the
-- FinAgent functions run as their owner and pass on to the row guard.
CREATE FUNCTION fao_private.hitl_queue_guard_stmt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF current_user NOT IN ('postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'FAO-GOV-004: direct % on hitl_queue is not permitted; decisions are recorded only through fao_hitl_decide', TG_OP
      USING ERRCODE = '42501';
  END IF;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION fao_private.hitl_queue_guard_stmt() IS
  'FAO-GOV-004: statement trigger on hitl_queue that refuses any write by a role outside the owner class. Backstop; no client role holds a write grant.';

-- ----------------------------------------------------------------------------
-- 4. hitl_queue row guard (FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- Holds for every role, the owner included. There is no branch that skips a
-- rule when no session user is set.
--   DELETE: refused.
--   INSERT: PENDING with no approver, decision time or notes; one enforced
--           approval; a RUNNING run record with the same agent, invoker and
--           tier; tier not BLOCKED; no other request for the run; deadline in
--           the future.
--   UPDATE: only a PENDING row may change; only decision, approver_id,
--           decided_at and decision_notes may change;
--           to APPROVED or REJECTED: the approver is the session user, is not
--           the invoker, holds the approver role for the agent, and the
--           deadline has not passed;
--           to EXPIRED: no approver, and the deadline has passed;
--           anything else (PENDING to PENDING included): refused.
CREATE FUNCTION fao_private.hitl_queue_guard_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid;
  v_frozen text[] := ARRAY['decision', 'approver_id', 'decided_at', 'decision_notes'];
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
    IF NEW.enforced_approvals IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'FAO-GOV-004: a request must be created with one enforced approval'
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
  'FAO-GOV-004: row trigger on hitl_queue for every role: no DELETE; inserts only PENDING for a RUNNING run; decided rows immutable; frozen fields; APPROVED or REJECTED only by the signed-in approver who is not the invoker, before the deadline; EXPIRED only after it.';

-- ----------------------------------------------------------------------------
-- 5. Run, token and role guards (FAO-GOV-008, FAO-GOV-004)
-- ----------------------------------------------------------------------------

-- Run state machine. DELETE refused. Identity and request fields frozen.
-- asset_scope and n8n_execution_id may be set once (from NULL). States:
--   REQUESTED     -> RUNNING | EXPIRED
--   RUNNING       -> AWAITING_HITL | COMMITTED | FAILED
--   AWAITING_HITL -> COMMITTED | FAILED | EXPIRED
--   COMMITTED, FAILED, EXPIRED are terminal: a finished run never changes.
-- An unchanged state is allowed for the permitted column updates.
CREATE FUNCTION fao_private.run_invocations_guard_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FAO-GOV-008: run records cannot be deleted'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.correlation_id  IS DISTINCT FROM OLD.correlation_id
     OR NEW.execution_id    IS DISTINCT FROM OLD.execution_id
     OR NEW.agent_id        IS DISTINCT FROM OLD.agent_id
     OR NEW.invoker_id      IS DISTINCT FROM OLD.invoker_id
     OR NEW.risk_tier       IS DISTINCT FROM OLD.risk_tier
     OR NEW.invoked_via     IS DISTINCT FROM OLD.invoked_via
     OR NEW.reason          IS DISTINCT FROM OLD.reason
     OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
     OR NEW.requested_at    IS DISTINCT FROM OLD.requested_at THEN
    RAISE EXCEPTION 'FAO-GOV-008: frozen run record fields cannot change (correlation %)', OLD.correlation_id
      USING ERRCODE = '42501';
  END IF;

  IF OLD.asset_scope IS NOT NULL AND NEW.asset_scope IS DISTINCT FROM OLD.asset_scope THEN
    RAISE EXCEPTION 'FAO-GOV-008: the run asset scope is set once (correlation %)', OLD.correlation_id
      USING ERRCODE = '42501';
  END IF;

  IF OLD.n8n_execution_id IS NOT NULL AND NEW.n8n_execution_id IS DISTINCT FROM OLD.n8n_execution_id THEN
    RAISE EXCEPTION 'FAO-GOV-008: the run execution id is set once (correlation %)', OLD.correlation_id
      USING ERRCODE = '42501';
  END IF;

  IF OLD.state IN ('COMMITTED'::public.fao_run_state, 'FAILED'::public.fao_run_state, 'EXPIRED'::public.fao_run_state) THEN
    IF to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
      RAISE EXCEPTION 'FAO-GOV-008: a finished run cannot change (correlation %)', OLD.correlation_id
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.state IS DISTINCT FROM OLD.state THEN
    IF NOT (
         (OLD.state = 'REQUESTED'     AND NEW.state IN ('RUNNING', 'EXPIRED'))
      OR (OLD.state = 'RUNNING'       AND NEW.state IN ('AWAITING_HITL', 'COMMITTED', 'FAILED'))
      OR (OLD.state = 'AWAITING_HITL' AND NEW.state IN ('COMMITTED', 'FAILED', 'EXPIRED'))
    ) THEN
      RAISE EXCEPTION 'FAO-GOV-008: run state % cannot move to % (correlation %)', OLD.state, NEW.state, OLD.correlation_id
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fao_private.run_invocations_guard_row() IS
  'FAO-GOV-008: row trigger on run_invocations: no DELETE, frozen identity and request fields, asset scope and execution id set once, forward-only state machine, finished runs immutable.';

-- Run tokens: DELETE refused; correlation frozen; hash, expiry and issue time
-- may change only while the token is unconsumed (a replay issues a new token
-- on the same row); consumed_at is set once.
CREATE FUNCTION fao_private.run_tokens_guard_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FAO-GOV-008: run tokens cannot be deleted'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.correlation_id IS DISTINCT FROM OLD.correlation_id THEN
    RAISE EXCEPTION 'FAO-GOV-008: a run token cannot move to another run'
      USING ERRCODE = '42501';
  END IF;

  IF OLD.consumed_at IS NOT NULL THEN
    IF NEW.token_hash  IS DISTINCT FROM OLD.token_hash
       OR NEW.expires_at  IS DISTINCT FROM OLD.expires_at
       OR NEW.issued_at   IS DISTINCT FROM OLD.issued_at
       OR NEW.consumed_at IS DISTINCT FROM OLD.consumed_at THEN
      RAISE EXCEPTION 'FAO-GOV-008: a consumed run token cannot change'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fao_private.run_tokens_guard_row() IS
  'FAO-GOV-008: row trigger on fao_private.run_tokens: no DELETE, correlation frozen, token fields change only while unconsumed, consumed_at set once.';

-- Role grants: DELETE refused; only revoked_at may change, and only from NULL.
CREATE FUNCTION fao_private.user_roles_guard_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FAO-GOV-004: role grants are revoked, never deleted'
      USING ERRCODE = '42501';
  END IF;

  IF (to_jsonb(NEW) - 'revoked_at') IS DISTINCT FROM (to_jsonb(OLD) - 'revoked_at') THEN
    RAISE EXCEPTION 'FAO-GOV-004: only revoked_at may change on a role grant (id %)', OLD.id
      USING ERRCODE = '42501';
  END IF;

  IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
    RAISE EXCEPTION 'FAO-GOV-004: a revoked role grant cannot change (id %)', OLD.id
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fao_private.user_roles_guard_row() IS
  'FAO-GOV-004: row trigger on fao_user_roles: no DELETE; only revoked_at may change, once, from NULL.';

-- ----------------------------------------------------------------------------
-- 6. Policies on hitl_queue (FAO-GOV-004): members read; no write policy.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated users can read hitl_queue"            ON public.hitl_queue;
DROP POLICY IF EXISTS "Only service_role can insert hitl_queue"            ON public.hitl_queue;
DROP POLICY IF EXISTS "Service role can update hitl_queue"                 ON public.hitl_queue;
DROP POLICY IF EXISTS "Authenticated users can attempt hitl_queue updates" ON public.hitl_queue;
DROP POLICY IF EXISTS "SoD: approver cannot be invoker"                    ON public.hitl_queue;

CREATE POLICY "FAO members read hitl_queue"
  ON public.hitl_queue
  FOR SELECT
  TO authenticated
  USING (fao_private.has_any_role((select auth.uid())));

-- ----------------------------------------------------------------------------
-- 7. Policies on shadow_ledger (FAO-GOV-001): members read; no write policy.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Authenticated users can insert shadow_ledger" ON public.shadow_ledger;
DROP POLICY IF EXISTS "Service role can insert shadow_ledger"        ON public.shadow_ledger;
DROP POLICY IF EXISTS "Authenticated users can read shadow_ledger"   ON public.shadow_ledger;

CREATE POLICY "FAO members read shadow_ledger"
  ON public.shadow_ledger
  FOR SELECT
  TO authenticated
  USING (fao_private.has_any_role((select auth.uid())));

COMMENT ON FUNCTION public.shadow_ledger_enforce_append_only() IS
  'FAO-GOV-001: trigger function that raises on UPDATE or DELETE against shadow_ledger. It refuses every application role and the owner in normal operation; the table owner can disable triggers, which is outside the control (owner trust class). New rows are written only by the FinAgent database functions.';

-- ----------------------------------------------------------------------------
-- 8. Other policies (FAO-GOV-004, FAO-GOV-001, FAO-GOV-002)
-- ----------------------------------------------------------------------------
CREATE POLICY "FAO members read run_invocations"
  ON public.run_invocations
  FOR SELECT
  TO authenticated
  USING (fao_private.has_any_role((select auth.uid())));

CREATE POLICY "Own, admin or reader reads roles"
  ON public.fao_user_roles
  FOR SELECT
  TO authenticated
  USING (
    user_id = (select auth.uid())
    OR fao_private.has_role((select auth.uid()), 'admin', NULL)
    OR fao_private.has_role((select auth.uid()), 'reader', NULL)
  );

CREATE POLICY "Admin or reader reads fao_refusal_journal"
  ON public.fao_refusal_journal
  FOR SELECT
  TO authenticated
  USING (
    fao_private.has_role((select auth.uid()), 'admin', NULL)
    OR fao_private.has_role((select auth.uid()), 'reader', NULL)
  );

CREATE POLICY "Admin or reader reads fao_admin_audit"
  ON public.fao_admin_audit
  FOR SELECT
  TO authenticated
  USING (
    fao_private.has_role((select auth.uid()), 'admin', NULL)
    OR fao_private.has_role((select auth.uid()), 'reader', NULL)
  );

CREATE POLICY "Admin or reader reads fao_notifications"
  ON public.fao_notifications
  FOR SELECT
  TO authenticated
  USING (
    fao_private.has_role((select auth.uid()), 'admin', NULL)
    OR fao_private.has_role((select auth.uid()), 'reader', NULL)
  );

CREATE POLICY "Admin or reader reads fao_settings"
  ON public.fao_settings
  FOR SELECT
  TO authenticated
  USING (
    fao_private.has_role((select auth.uid()), 'admin', NULL)
    OR fao_private.has_role((select auth.uid()), 'reader', NULL)
  );

CREATE POLICY "Workflow reads thresholds"
  ON public.materiality_thresholds
  FOR SELECT
  TO fao_workflow
  USING (true);

-- The authenticated SELECT policies on process_owners, agent_registry and
-- materiality_thresholds stay. Their service_role write policies go: no
-- client role writes configuration tables directly.
DROP POLICY IF EXISTS "Only service_role can insert process_owners"         ON public.process_owners;
DROP POLICY IF EXISTS "Only service_role can update process_owners"         ON public.process_owners;
DROP POLICY IF EXISTS "Only service_role can delete process_owners"         ON public.process_owners;
DROP POLICY IF EXISTS "Only service_role can insert agent_registry"         ON public.agent_registry;
DROP POLICY IF EXISTS "Only service_role can update agent_registry"         ON public.agent_registry;
DROP POLICY IF EXISTS "Only service_role can delete agent_registry"         ON public.agent_registry;
DROP POLICY IF EXISTS "Only service_role can insert materiality_thresholds" ON public.materiality_thresholds;
DROP POLICY IF EXISTS "Only service_role can update materiality_thresholds" ON public.materiality_thresholds;
DROP POLICY IF EXISTS "Only service_role can delete materiality_thresholds" ON public.materiality_thresholds;

-- ----------------------------------------------------------------------------
-- 9. Trigger attachment
-- ----------------------------------------------------------------------------

-- FAO-GOV-001: no TRUNCATE on any FinAgent table, for any role, the owner
-- included (the three evidence tables got theirs in 0011).
CREATE TRIGGER shadow_ledger_deny_truncate
  BEFORE TRUNCATE ON public.shadow_ledger
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER hitl_queue_deny_truncate
  BEFORE TRUNCATE ON public.hitl_queue
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER run_invocations_deny_truncate
  BEFORE TRUNCATE ON public.run_invocations
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER process_owners_deny_truncate
  BEFORE TRUNCATE ON public.process_owners
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER agent_registry_deny_truncate
  BEFORE TRUNCATE ON public.agent_registry
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER materiality_thresholds_deny_truncate
  BEFORE TRUNCATE ON public.materiality_thresholds
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER fao_user_roles_deny_truncate
  BEFORE TRUNCATE ON public.fao_user_roles
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER fao_settings_deny_truncate
  BEFORE TRUNCATE ON public.fao_settings
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER run_tokens_deny_truncate
  BEFORE TRUNCATE ON fao_private.run_tokens
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();
CREATE TRIGGER test_clock_deny_truncate
  BEFORE TRUNCATE ON fao_private.test_clock
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.deny_truncate();

-- FAO-GOV-002: configuration tables need a change reason (statement level)
-- and every changed row is audited with before and after images (row level).
-- Trigger arguments name the key columns recorded in fao_admin_audit.row_key.
CREATE TRIGGER process_owners_require_change_reason
  BEFORE INSERT OR UPDATE OR DELETE ON public.process_owners
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.require_change_reason();
CREATE TRIGGER process_owners_admin_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.process_owners
  FOR EACH ROW EXECUTE FUNCTION fao_private.admin_audit('id');

CREATE TRIGGER agent_registry_require_change_reason
  BEFORE INSERT OR UPDATE OR DELETE ON public.agent_registry
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.require_change_reason();
CREATE TRIGGER agent_registry_admin_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.agent_registry
  FOR EACH ROW EXECUTE FUNCTION fao_private.admin_audit('agent_id');

CREATE TRIGGER materiality_thresholds_require_change_reason
  BEFORE INSERT OR UPDATE OR DELETE ON public.materiality_thresholds
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.require_change_reason();
CREATE TRIGGER materiality_thresholds_admin_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.materiality_thresholds
  FOR EACH ROW EXECUTE FUNCTION fao_private.admin_audit('asset_symbol', 'scope');

CREATE TRIGGER fao_user_roles_require_change_reason
  BEFORE INSERT OR UPDATE OR DELETE ON public.fao_user_roles
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.require_change_reason();
CREATE TRIGGER fao_user_roles_admin_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.fao_user_roles
  FOR EACH ROW EXECUTE FUNCTION fao_private.admin_audit('id');

CREATE TRIGGER fao_settings_require_change_reason
  BEFORE INSERT OR UPDATE OR DELETE ON public.fao_settings
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.require_change_reason();
CREATE TRIGGER fao_settings_admin_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.fao_settings
  FOR EACH ROW EXECUTE FUNCTION fao_private.admin_audit('key');

CREATE TRIGGER test_clock_require_change_reason
  BEFORE INSERT OR UPDATE OR DELETE ON fao_private.test_clock
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.require_change_reason();
CREATE TRIGGER test_clock_admin_audit
  AFTER INSERT OR UPDATE OR DELETE ON fao_private.test_clock
  FOR EACH ROW EXECUTE FUNCTION fao_private.admin_audit('id');

-- updated_at kept current without the caller supplying it.
CREATE TRIGGER process_owners_touch_updated_at
  BEFORE UPDATE ON public.process_owners
  FOR EACH ROW EXECUTE FUNCTION fao_private.touch_updated_at();
CREATE TRIGGER agent_registry_touch_updated_at
  BEFORE UPDATE ON public.agent_registry
  FOR EACH ROW EXECUTE FUNCTION fao_private.touch_updated_at();
CREATE TRIGGER materiality_thresholds_touch_updated_at
  BEFORE UPDATE ON public.materiality_thresholds
  FOR EACH ROW EXECUTE FUNCTION fao_private.touch_updated_at();
CREATE TRIGGER fao_settings_touch_updated_at
  BEFORE UPDATE ON public.fao_settings
  FOR EACH ROW EXECUTE FUNCTION fao_private.touch_updated_at();

-- FAO-GOV-004, FAO-GOV-008: the guards from steps 3 to 5.
CREATE TRIGGER hitl_queue_guard_stmt
  BEFORE INSERT OR UPDATE OR DELETE ON public.hitl_queue
  FOR EACH STATEMENT EXECUTE FUNCTION fao_private.hitl_queue_guard_stmt();
CREATE TRIGGER hitl_queue_guard_row
  BEFORE INSERT OR UPDATE OR DELETE ON public.hitl_queue
  FOR EACH ROW EXECUTE FUNCTION fao_private.hitl_queue_guard_row();
CREATE TRIGGER run_invocations_guard_row
  BEFORE UPDATE OR DELETE ON public.run_invocations
  FOR EACH ROW EXECUTE FUNCTION fao_private.run_invocations_guard_row();
CREATE TRIGGER run_tokens_guard_row
  BEFORE UPDATE OR DELETE ON fao_private.run_tokens
  FOR EACH ROW EXECUTE FUNCTION fao_private.run_tokens_guard_row();
CREATE TRIGGER user_roles_guard_row
  BEFORE UPDATE OR DELETE ON public.fao_user_roles
  FOR EACH ROW EXECUTE FUNCTION fao_private.user_roles_guard_row();

-- ----------------------------------------------------------------------------
-- 10. Revoke every function in this file from every client role. Trigger
--     functions and the legacy closure are never granted to anyone (0017).
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION fao_private.hitl_queue_guard_stmt()     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.hitl_queue_guard_row()      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.run_invocations_guard_row() FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.run_tokens_guard_row()      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.user_roles_guard_row()      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.close_legacy_requests()     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
