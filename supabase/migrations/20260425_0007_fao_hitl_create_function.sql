-- ============================================================================
-- FinAgent OS — Migration 0007: fao_hitl_create() function (loud zero-row)
-- ============================================================================
-- Replaces the inline INSERT...SELECT pattern in the HITL Gateway with a
-- stored function that RAISEs a named exception when either join misses.
--
-- RATIONALE:
-- The HITL Gateway's first implementation (Apr 25 morning) used an inline
-- INSERT...SELECT...FROM process_owners CROSS JOIN agent_registry pattern.
-- The intent: if either email or agent_id didn't match, the INSERT inserted
-- zero rows, RETURNING returned an empty set, and a downstream n8n Code
-- node detected the empty payload and threw an FAO-GOV-004 exception.
--
-- Empirical test (deliberate-failure path with email='nobody@finagent-os.demo')
-- revealed a silent-failure mode: n8n's Postgres node returns zero items
-- when RETURNING produces an empty set, and zero items causes downstream
-- nodes to gracefully skip rather than execute. The application-layer
-- throw lived in code that never ran.
--
-- This is the same lesson surfaced in Migration 0005 -> 0005c on hitl_queue
-- SoD: silent rejection of a control violation is weaker audit posture
-- than a loud, attributed exception. Application-layer enforcement that
-- depends on downstream-node execution is not enforcement; it's hope.
--
-- Migration 0007 moves the enforcement to the database layer where it
-- belongs. Same pattern as FAO-GOV-001 on shadow_ledger (append-only
-- trigger) and FAO-GOV-004 on hitl_queue (SoD trigger) — defense at the
-- data layer, named exception with the Control ID, loud rejection.
--
-- The function:
--   1. Resolves agent_invoker_email -> process_owners.id; raises
--      FAO-GOV-004 if not found.
--   2. Looks up sla_max_hitl_resolution_hrs from agent_registry; raises
--      FAO-GOV-004 if agent_id not found.
--   3. INSERTs the hitl_queue row using the resolved UUID and computed
--      timeout_at.
--   4. Returns the new hitl_id, agent_invoker_id, timeout_at, created_at.
--
-- Caller behavior in n8n:
--   On success — Postgres node returns 1 item, downstream nodes execute
--   normally.
--   On missed join — Postgres node receives a database exception, n8n
--   marks the node red, the workflow halts loudly with the FAO-GOV-004
--   message visible in the node's error panel.
--
-- Control IDs implemented:
--   FAO-GOV-004  HITL Gateway database-layer enforcement (loud zero-row)
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-25
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fao_hitl_create(
  p_correlation_id        uuid,
  p_agent_id              text,
  p_agent_invoker_email   text,
  p_risk_tier             public.risk_tier,
  p_sub_tier              public.policy_sub_tier,
  p_policy_rationale      text,
  p_ai_human_brief        text DEFAULT NULL
)
RETURNS TABLE (
  hitl_id           bigint,
  agent_invoker_id  uuid,
  timeout_at        timestamptz,
  created_at        timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_invoker_id  uuid;
  v_sla_hours   integer;
BEGIN
  -- ----- 1. Resolve invoker email -> UUID ---------------------------------
  SELECT po.id
    INTO v_invoker_id
    FROM public.process_owners po
   WHERE po.email = p_agent_invoker_email;

  IF v_invoker_id IS NULL THEN
    RAISE EXCEPTION
      'FAO-GOV-004 fao_hitl_create: agent_invoker_email % is not in process_owners. Check public.process_owners seed.',
      p_agent_invoker_email
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- ----- 2. Look up agent SLA from registry -------------------------------
  SELECT ar.sla_max_hitl_resolution_hrs
    INTO v_sla_hours
    FROM public.agent_registry ar
   WHERE ar.agent_id = p_agent_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'FAO-GOV-004 fao_hitl_create: agent_id % is not in agent_registry. Check public.agent_registry seed.',
      p_agent_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_sla_hours IS NULL THEN
    RAISE EXCEPTION
      'FAO-GOV-004 fao_hitl_create: agent_id % has NULL sla_max_hitl_resolution_hrs in agent_registry. STUB_DOCUMENTED agents cannot create HITL requests; promote to ACTIVE and set SLA first.',
      p_agent_id
      USING ERRCODE = 'not_null_violation';
  END IF;

  -- ----- 3. Insert + return -----------------------------------------------
  RETURN QUERY
  INSERT INTO public.hitl_queue (
    correlation_id,
    agent_id,
    agent_invoker_id,
    risk_tier,
    sub_tier,
    policy_rationale,
    ai_human_brief,
    timeout_at
  )
  VALUES (
    p_correlation_id,
    p_agent_id,
    v_invoker_id,
    p_risk_tier,
    p_sub_tier,
    p_policy_rationale,
    p_ai_human_brief,
    NOW() + make_interval(hours => v_sla_hours)
  )
  RETURNING
    hitl_queue.hitl_id,
    hitl_queue.agent_invoker_id,
    hitl_queue.timeout_at,
    hitl_queue.created_at;
END;
$$;

COMMENT ON FUNCTION public.fao_hitl_create(uuid, text, text, public.risk_tier, public.policy_sub_tier, text, text) IS
  'FAO-GOV-004: Creates a hitl_queue row with database-layer validation. RAISEs a named FAO-GOV-004 exception if agent_invoker_email is not in process_owners or agent_id is not in agent_registry. Replaces the inline INSERT...SELECT pattern that had a silent-failure mode when downstream n8n nodes never executed on zero-row results.';
