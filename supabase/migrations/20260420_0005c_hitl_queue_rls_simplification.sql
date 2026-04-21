-- ============================================================================
-- FinAgent OS — Migration 0005c: Remove SoD RLS Policy (Trigger is Sole Enforcer)
-- ============================================================================
-- CORRECTION to Migration 0005. The original migration layered a USING
-- clause on the UPDATE RLS policy that encoded the SoD rule (auth.uid() !=
-- agent_invoker_id). Combined with Migration 0005b's trigger, this created
-- redundant enforcement on the same vector: RLS filtered the violating
-- row silently, so the trigger never got the chance to raise its loud
-- exception.
--
-- The trigger is the stronger enforcement mechanism for a SOX environment
-- because it produces a named exception with the FAO-GOV-004 Control ID
-- and the offending UUIDs, rather than a silent "UPDATE 0 rows" result.
-- Silent rejection of control violations is weaker audit posture than
-- a loud, attributed exception.
--
-- This migration drops the SoD-specific USING clause from the UPDATE RLS
-- policy, replacing it with a permissive policy that allows authenticated
-- users to attempt UPDATEs. The trigger (Migration 0005b) is now the sole
-- enforcement point for SoD, and its rejection is loud and forensic.
--
-- The SELECT policy remains unchanged — authenticated users can still
-- read the queue. Only the UPDATE enforcement mechanism is restructured.
--
-- Control IDs implemented:
--   FAO-GOV-004  Segregation of Duties (trigger is sole enforcer)
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

-- Drop the restrictive UPDATE policy from Migration 0005
DROP POLICY IF EXISTS "SoD: approver cannot be invoker" ON public.hitl_queue;

-- Replace with a permissive UPDATE policy. Any authenticated user can
-- attempt an UPDATE; the trigger decides whether it succeeds.
CREATE POLICY "Authenticated users can attempt hitl_queue updates"
  ON public.hitl_queue
  FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

COMMENT ON POLICY "Authenticated users can attempt hitl_queue updates"
  ON public.hitl_queue IS
  'Permissive UPDATE policy. SoD enforcement is delegated to the BEFORE UPDATE trigger hitl_queue_sod_guard (Migration 0005b), which raises FAO-GOV-004 exceptions loudly.';
