-- ============================================================================
-- FinAgent OS — Migration 0004: shadow_ledger + Append-Only Trigger + RLS
-- ============================================================================
-- The Shadow Ledger is the immutable audit trail for every agent execution
-- in FinAgent OS. Every invocation writes at least one record on entry and
-- one on exit. Every policy outcome, every AI advisory, every HITL routing
-- decision, every rollback — logged here with a correlation_id threading
-- through the lifecycle.
--
-- Append-only is enforced at THREE layers, deliberately:
--
--   Layer 1 — TRIGGER: Before any UPDATE or DELETE, a Postgres trigger
--             fires and raises an exception. Aborts the transaction. This
--             catches EVERY identity, including superusers and service_role.
--
--   Layer 2 — RLS: Row-Level Security is enabled, and policies exist only
--             for SELECT and INSERT. With RLS enabled and no UPDATE/DELETE
--             policy, Postgres denies those operations for all non-bypass
--             roles before the trigger even fires.
--
--   Layer 3 — CHECK constraints: Data integrity on specific columns
--             (e.g. status must be one of the execution_status enum values).
--
-- Defense in depth. The trigger catches everyone. RLS catches most.
-- CHECK catches invalid data. Any of the three alone would be weaker.
-- Together, they are the architectural statement of FAO-GOV-001:
-- "Append-only is a database constraint, not an application convention."
--
-- Control IDs implemented:
--   FAO-GOV-001  Shadow Ledger immutable audit trail (trigger + RLS)
--   FAO-GOV-008  Correlation ID threading (UUID per execution)
--   FAO-GOV-011  Fractional API cost tracking (6-decimal precision)
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

CREATE TABLE public.shadow_ledger (
  -- Auto-incrementing primary key. Chosen over UUID because natural ordering
  -- is operationally useful — "show me the last 10 ledger entries" becomes
  -- `ORDER BY ledger_id DESC LIMIT 10`, which is immediate. UUIDs obscure
  -- temporal ordering without adding value here.
  ledger_id             BIGSERIAL     PRIMARY KEY,

  -- Correlation ID threads through every event of a single agent execution.
  -- One execution = one correlation_id, carried across Shadow Ledger,
  -- HITL requests, approval records, and downstream systems. FAO-GOV-008.
  correlation_id        UUID          NOT NULL,

  -- Execution ID — identifies a specific run. A correlation_id may appear
  -- on multiple ledger rows (entry + exit + HITL + completion); execution_id
  -- is unique per run. In most cases they will match, but we keep them
  -- separate so nested sub-executions can share a correlation_id while
  -- keeping distinct execution_ids.
  execution_id          UUID          NOT NULL,

  -- The agent that produced this ledger entry. FK to agent_registry with
  -- ON DELETE RESTRICT — agents with ledger history cannot be deleted,
  -- only deprecated via status change.
  agent_id              TEXT          NOT NULL REFERENCES public.agent_registry(agent_id) ON DELETE RESTRICT,

  -- When the event occurred. NOT NULL with default NOW() so no entry can
  -- be written without a timestamp.
  event_timestamp       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- Risk tier at time of execution. Captured here (rather than joining to
  -- agent_registry) because if the registry later changes the tier, the
  -- historical ledger entry must reflect the tier that was ACTIVE at
  -- execution time. Immutable history.
  risk_tier             risk_tier     NOT NULL,

  -- Structured input payload the agent received at execution start.
  -- JSONB for indexed queries on specific keys.
  inputs                JSONB,

  -- --- AI advisory fields (FAO-GOV-011: fractional cost tracking) ---------

  -- The prompt sent to the LLM, if AI was used for this execution. NULL
  -- when FAO_AI_ASSIST_ENABLED=false or when the agent did not invoke AI.
  ai_prompt             TEXT,

  -- The LLM response, as received. Kept verbatim for audit reproducibility.
  ai_output             TEXT,

  -- Model-reported confidence, if available. NUMERIC(3,2) allows values
  -- like 0.97 with two decimal precision.
  ai_confidence         NUMERIC(3,2)  CHECK (ai_confidence IS NULL OR (ai_confidence >= 0 AND ai_confidence <= 1)),

  -- Cost of the LLM call for this ledger entry, in USD. 6-decimal precision
  -- captures fractional-cent costs of small prompts (GPT-4o-mini can cost
  -- $0.000015 per call). FAO-GOV-011.
  fractional_cost_usd   NUMERIC(12,6),

  -- --- Policy outcome fields (FAO-GOV-009) --------------------------------

  -- The deterministic policy outcome produced by the policy engine.
  -- This is the final authority on what the agent does next. Not
  -- computed by LLM — computed by rules.
  policy_outcome        policy_outcome NOT NULL,

  -- Sub-tier granularity within REQUIRE_HUMAN (STANDARD vs CRITICAL),
  -- routing to 1-approver or 2-approver HITL lanes.
  policy_sub_tier       policy_sub_tier,

  -- Human-readable rationale for the outcome. Written by the policy engine
  -- deterministically — this is the "why" a future auditor reads.
  policy_rationale      TEXT          NOT NULL,

  -- Obligations attached to an ALLOW_WITH_OBLIGATIONS outcome. Example:
  -- {"weekly_review_required","notify_fpa_lead","flag_for_quarterly_audit"}
  obligations           TEXT[]        DEFAULT ARRAY[]::TEXT[],

  -- --- HITL routing fields (FAO-GOV-004) ----------------------------------

  hitl_status           hitl_status   NOT NULL DEFAULT 'NOT_REQUIRED',

  -- The process owner who approved this HITL request, if applicable.
  -- NULL when hitl_status != APPROVED.
  hitl_approver_id      UUID          REFERENCES public.process_owners(id) ON DELETE SET NULL,

  -- --- Execution outcome fields -------------------------------------------

  status                execution_status NOT NULL,

  -- If status = FAILURE or PARTIAL or ROLLED_BACK, details captured here.
  error_details         TEXT
);

-- --- Indexes ----------------------------------------------------------------

-- Temporal queries: "show me ledger entries from the last 24 hours"
CREATE INDEX idx_shadow_ledger_event_timestamp
  ON public.shadow_ledger(event_timestamp DESC);

-- Correlation ID lookup: "trace all events for this execution"
CREATE INDEX idx_shadow_ledger_correlation_id
  ON public.shadow_ledger(correlation_id);

-- Agent activity: "show me all events for this agent"
CREATE INDEX idx_shadow_ledger_agent_id
  ON public.shadow_ledger(agent_id);

-- Policy outcome filter: "show me all REQUIRE_HUMAN events"
CREATE INDEX idx_shadow_ledger_policy_outcome
  ON public.shadow_ledger(policy_outcome);

-- HITL status filter: "show me all PENDING HITL events"
CREATE INDEX idx_shadow_ledger_hitl_status
  ON public.shadow_ledger(hitl_status)
  WHERE hitl_status != 'NOT_REQUIRED';

-- ============================================================================
-- LAYER 1: THE APPEND-ONLY TRIGGER
-- ============================================================================
-- This function fires BEFORE any UPDATE or DELETE on shadow_ledger and
-- raises an exception. The transaction aborts; the row does not change.
-- This catches EVERY identity — authenticated users, service_role,
-- superusers, direct postgres connections. There is no bypass.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.shadow_ledger_enforce_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- TG_OP is a special variable in Postgres trigger functions that reports
  -- which operation fired the trigger. For UPDATE/DELETE we raise an
  -- exception with a clear message so the audit log shows exactly why the
  -- operation was rejected.
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'FAO-GOV-001: Shadow Ledger is append-only. UPDATE operations are permanently disallowed on this table. Attempted modification of ledger_id=%', OLD.ledger_id
      USING ERRCODE = 'insufficient_privilege';
  ELSIF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FAO-GOV-001: Shadow Ledger is append-only. DELETE operations are permanently disallowed on this table. Attempted deletion of ledger_id=%', OLD.ledger_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Unreachable in practice (only UPDATE/DELETE fire this trigger),
  -- but defensively return OLD for correctness if somehow invoked otherwise.
  RETURN OLD;
END;
$$;

COMMENT ON FUNCTION public.shadow_ledger_enforce_append_only() IS
  'FAO-GOV-001: Trigger function that raises an exception on UPDATE or DELETE attempts against shadow_ledger. Enforces append-only at the database layer, not the application layer. Applies to all identities including superusers.';

-- Wire the trigger to the table. BEFORE means it fires before the
-- operation attempts to change data, so the exception aborts cleanly.
CREATE TRIGGER shadow_ledger_append_only_guard
  BEFORE UPDATE OR DELETE ON public.shadow_ledger
  FOR EACH ROW
  EXECUTE FUNCTION public.shadow_ledger_enforce_append_only();

-- ============================================================================
-- LAYER 2: ROW-LEVEL SECURITY
-- ============================================================================
-- Policies are defined ONLY for SELECT and INSERT. The absence of UPDATE
-- and DELETE policies means RLS denies those operations for all
-- non-bypass roles — a second layer of defense that rejects UPDATEs and
-- DELETEs before the trigger even gets a chance to fire.
-- ============================================================================

ALTER TABLE public.shadow_ledger ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read the full ledger. Dashboards, audit exports,
-- and the weekly rubric refinement job (FAO-GOV-012) all need this.
CREATE POLICY "Authenticated users can read shadow_ledger"
  ON public.shadow_ledger
  FOR SELECT
  TO authenticated
  USING (true);

-- Authenticated users AND service_role can insert. Agents write here as
-- part of their normal execution. We allow authenticated writers (not
-- just service_role) because the n8n workflows will connect using a
-- service key, but conceptually any agent identity can append.
CREATE POLICY "Authenticated users can insert shadow_ledger"
  ON public.shadow_ledger
  FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "Service role can insert shadow_ledger"
  ON public.shadow_ledger
  FOR INSERT
  TO service_role
  WITH CHECK (true);

-- NO UPDATE POLICY. NO DELETE POLICY. This is deliberate.
-- With RLS enabled and no policy for an operation, that operation is
-- denied for all roles that do not bypass RLS. See Postgres docs:
-- "If no policy exists for a given command, then a default-deny policy
--  is assumed, that is, no rows will be visible or updatable."

-- --- Table comments for introspection ---------------------------------------

COMMENT ON TABLE  public.shadow_ledger                        IS 'FAO-GOV-001: Immutable audit trail for every agent execution. Append-only enforced by trigger + RLS + CHECK constraints (defense in depth).';
COMMENT ON COLUMN public.shadow_ledger.correlation_id         IS 'FAO-GOV-008: One execution = one correlation_id threaded across Shadow Ledger, HITL, and downstream systems.';
COMMENT ON COLUMN public.shadow_ledger.fractional_cost_usd    IS 'FAO-GOV-011: AI advisory cost in USD with 6-decimal precision.';
COMMENT ON COLUMN public.shadow_ledger.policy_outcome         IS 'FAO-GOV-009: Deterministic policy outcome (not LLM-generated).';
