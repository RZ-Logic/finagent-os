-- ============================================================================
-- FinAgent OS — Migration 0005b: hitl_queue SoD Trigger (Loud Rejection)
-- ============================================================================
-- Supplements Migration 0005 with a BEFORE UPDATE trigger on hitl_queue
-- that enforces segregation of duties with a RAISE EXCEPTION instead of
-- silent RLS filtering.
--
-- RATIONALE:
-- Migration 0005 enforces SoD via an RLS policy on UPDATE. The RLS check
-- works (verified empirically: a violating UPDATE affects zero rows), but
-- the rejection is SILENT — a naive consumer who doesn't check the row
-- state afterward might wrongly believe the approval landed.
--
-- In a SOX-regulated financial environment, silent rejection of a control
-- violation is a weaker posture than loud rejection. An auditor wants to
-- see clearly-attributed exceptions in logs, not inferred "this update
-- affected zero rows because policy, we think". A trigger that RAISES
-- EXCEPTION with the FAO-GOV-004 Control ID in the message gives:
--
--   1. A clearly-attributed error at the call site
--   2. A named Control ID any engineer can look up in SOX-MAPPING.md
--   3. Forensic visibility — the violating row and role are captured
--
-- The RLS policy remains in place (defense in depth). Two independent
-- layers enforce the same rule:
--
--   Layer 1 (RLS):     auth.uid() != agent_invoker_id in USING/WITH CHECK
--                      → filters violating rows from visibility
--   Layer 2 (trigger): BEFORE UPDATE checks auth.uid() = agent_invoker_id
--                      → RAISES EXCEPTION, transaction aborts
--
-- This matches the pattern used for FAO-GOV-001 (append-only on shadow_ledger)
-- where the trigger is the loud enforcement mechanism.
--
-- Control IDs implemented:
--   FAO-GOV-004  Segregation of Duties (reinforcement with loud rejection)
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

-- ----------------------------------------------------------------------------
-- TRIGGER FUNCTION: hitl_queue_enforce_sod()
-- ----------------------------------------------------------------------------
-- Fires BEFORE UPDATE on hitl_queue. Checks whether the authenticated
-- user (auth.uid()) equals the row's agent_invoker_id. If they match,
-- raises an exception with the FAO-GOV-004 Control ID.
--
-- Note on service_role: when the update comes from a service_role
-- connection (administrative override, e.g. cancelling a hung request),
-- auth.uid() returns NULL because there's no authenticated end user.
-- We let those updates through — administrative bypass is legitimate.
--
-- Note on the RLS interaction: because RLS on UPDATE already filters out
-- rows where auth.uid() = agent_invoker_id for authenticated users, this
-- trigger will rarely fire from a normal Supabase client. It DOES fire if:
--   (a) Someone disables RLS or runs as a bypass role but still has an
--       authenticated JWT set — the trigger catches them.
--   (b) A future migration weakens RLS — the trigger remains as guard.
-- Defense in depth.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.hitl_queue_enforce_sod()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  current_user_id UUID;
BEGIN
  -- auth.uid() is a Supabase helper that extracts the authenticated user's
  -- UUID from the JWT claims set on the current session. Returns NULL when
  -- no JWT is set (e.g. service_role administrative connections, direct
  -- postgres role) — we explicitly allow those through.
  current_user_id := (SELECT auth.uid());

  -- If no authenticated user is present (administrative access), allow
  -- the update. RLS policies still apply independently.
  IF current_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- The core SoD check: approver cannot be the invoker.
  IF current_user_id = OLD.agent_invoker_id THEN
    RAISE EXCEPTION
      'FAO-GOV-004: Segregation of Duties violation. Process owner % cannot approve their own agent invocation (hitl_id=%, agent_invoker_id=%).',
      current_user_id, OLD.hitl_id, OLD.agent_invoker_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Additional check: if the NEW row state is attempting to set approver_id
  -- equal to agent_invoker_id, reject. Covers the case where someone
  -- tries to spoof the approver identity in the NEW row itself.
  IF NEW.approver_id IS NOT NULL AND NEW.approver_id = NEW.agent_invoker_id THEN
    RAISE EXCEPTION
      'FAO-GOV-004: Segregation of Duties violation. approver_id cannot equal agent_invoker_id (hitl_id=%).',
      NEW.hitl_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.hitl_queue_enforce_sod() IS
  'FAO-GOV-004 reinforcement: BEFORE UPDATE trigger that raises an exception if the authenticated user equals the row''s agent_invoker_id, or if the new approver_id equals agent_invoker_id. Defense-in-depth complement to the RLS policy.';

-- ----------------------------------------------------------------------------
-- Wire the trigger to the table
-- ----------------------------------------------------------------------------

CREATE TRIGGER hitl_queue_sod_guard
  BEFORE UPDATE ON public.hitl_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.hitl_queue_enforce_sod();

COMMENT ON TRIGGER hitl_queue_sod_guard ON public.hitl_queue IS
  'FAO-GOV-004: Fires before UPDATE to raise an exception on SoD violations. Complementary to the RLS policy in Migration 0005.';
