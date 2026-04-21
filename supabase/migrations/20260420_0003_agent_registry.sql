-- ============================================================================
-- FinAgent OS — Migration 0003: agent_registry Table + RLS
-- ============================================================================
-- The Agent Registry is the formalized control population for FinAgent OS.
-- No agent executes without a row in this table. Every registry row names a
-- process owner, declares a risk tier, lists SOX control IDs, and documents
-- data sources, production targets, and rollback procedure.
--
-- The registry row IS the gate — agent workflows read this table at execution
-- start and refuse to proceed if the record is missing or incomplete.
--
-- This directly satisfies the JD's governance checklist:
--   "Classify all automation builds by risk tier before work begins.
--    No build goes to production without a named Process Owner, documented
--    data flows, access controls, and audit logging confirmed."
--
-- Control IDs implemented:
--   FAO-GOV-002  Agent Registry (formalized control population)
--   FAO-GOV-003  Risk-Tier Classification (GREEN/AMBER/RED)
--   FAO-GOV-013  Process Owner Named on Every Agent (FK to process_owners)
--   FAO-GOV-014  AI Disabled by Default (ai_advisory_enabled default FALSE)
--
-- Seeding:
--   This migration creates the table empty. Agent rows are seeded in a
--   separate file on Apr 22 when the flagship + stubs are registered.
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

CREATE TABLE public.agent_registry (
  -- Stable slug identifier used in workflow code. Example: 'reserve_recon_v1'.
  -- Chosen over UUID for this PK because agent_ids appear in n8n workflow
  -- references, CLI commands, and log lines where a human-readable key is
  -- more useful than a random UUID.
  agent_id                    TEXT          PRIMARY KEY,

  -- Human-readable name. Example: 'Reserve Reconciliation Agent'.
  display_name                TEXT          NOT NULL,

  -- Risk tier classification. Enum allows GREEN/AMBER/RED/BLOCKED but a
  -- CHECK constraint below restricts agent tiers to GREEN/AMBER/RED.
  -- BLOCKED is reserved for policy outcomes, never for an agent's operating
  -- tier (see SOX-MAPPING.md principle #2).
  risk_tier                   risk_tier     NOT NULL,

  -- Operational status. STUB_DOCUMENTED is the initial state for the three
  -- stub modules (Close Orchestrator, Variance Analyzer, Treasury Monitor)
  -- which inherit governance controls but cannot execute.
  status                      agent_status  NOT NULL DEFAULT 'STUB_DOCUMENTED',

  -- n8n workflow identifier. NULL for stubs until the workflow is built.
  -- Example: 'fao_reserve_recon_v1'.
  workflow_id                 TEXT,

  -- Number of human approvers required for REQUIRE_HUMAN outcomes at this
  -- agent's risk tier. GREEN/AMBER agents typically 1; RED agents typically 2.
  approval_threshold          INT           NOT NULL DEFAULT 1 CHECK (approval_threshold >= 1),

  -- List of SOX Control IDs this agent implements or inherits. Examples:
  -- {'FAO-GOV-001','FAO-GOV-004','FAO-REC-001','FAO-REC-006'}.
  sox_control_ids             TEXT[]        NOT NULL DEFAULT ARRAY[]::TEXT[],

  -- AI advisory feature flag. DEFAULT FALSE implements FAO-GOV-014: AI is
  -- disabled by default. Enabling AI is an explicit, logged configuration
  -- change. System operates deterministically with this flag off.
  ai_advisory_enabled         BOOLEAN       NOT NULL DEFAULT FALSE,

  -- Plain-English description of the rollback procedure for this agent.
  -- Referenced by FAO-GOV-005 (Rollback Engine) when a commit fails or HITL
  -- rejects the outcome. Required, not nullable — every agent must declare
  -- how to undo its work.
  rollback_procedure          TEXT          NOT NULL,

  -- JSONB declaration of data sources. Example:
  -- {"wallet": "Fireblocks REST API /v1/vault/accounts",
  --  "ledger": "NetSuite GL saved search ID 12345"}
  -- JSONB (not JSON) for indexed queries on specific keys.
  data_sources                JSONB         NOT NULL DEFAULT '{}'::JSONB,

  -- JSONB declaration of production target systems this agent writes to or
  -- informs. Examples: {"primary": "NetSuite", "secondary": "Shadow Ledger"}.
  production_targets          JSONB         NOT NULL DEFAULT '{}'::JSONB,

  -- SLA: maximum seconds for a single execution. Exceeding this triggers
  -- an alert, not a rollback. Enables observability on agent performance
  -- drift over time.
  sla_max_execution_seconds   INT           CHECK (sla_max_execution_seconds IS NULL OR sla_max_execution_seconds > 0),

  -- SLA: maximum hours before a HITL request must be resolved. Exceeding
  -- this escalates to the next process owner in the chain.
  sla_max_hitl_resolution_hrs INT           CHECK (sla_max_hitl_resolution_hrs IS NULL OR sla_max_hitl_resolution_hrs > 0),

  -- FK to process_owners. Named owner required for every agent.
  process_owner_id            UUID          NOT NULL REFERENCES public.process_owners(id) ON DELETE RESTRICT,

  -- Standard timestamps
  created_at                  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- Enforce that agent operating tier is never BLOCKED — BLOCKED is a
  -- policy outcome only, not a classification for an agent.
  CONSTRAINT agent_operating_tier_not_blocked
    CHECK (risk_tier != 'BLOCKED')
);

-- Indexes -------------------------------------------------------------------

-- Lookups by process_owner for "what agents does this owner supervise?"
CREATE INDEX idx_agent_registry_process_owner
  ON public.agent_registry(process_owner_id);

-- Status filter is common in dashboards ("show me all ACTIVE agents").
CREATE INDEX idx_agent_registry_status
  ON public.agent_registry(status);

-- GIN index on sox_control_ids for "which agents implement FAO-GOV-004?"
-- queries. GIN is the standard Postgres index for array containment.
CREATE INDEX idx_agent_registry_sox_controls
  ON public.agent_registry USING GIN (sox_control_ids);

-- RLS -----------------------------------------------------------------------

ALTER TABLE public.agent_registry ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read the full registry. Agents read this table
-- at execution start to validate their own registration; dashboards read
-- it to render agent lists; audit exports read it to correlate control IDs.
CREATE POLICY "Authenticated users can read agent_registry"
  ON public.agent_registry
  FOR SELECT
  TO authenticated
  USING (true);

-- Only service_role can mutate the registry. Registering, updating, or
-- deprecating an agent is a deliberate governance action performed by
-- an administrator — never by an agent or an end-user identity.
CREATE POLICY "Only service_role can insert agent_registry"
  ON public.agent_registry
  FOR INSERT
  TO service_role
  WITH CHECK (true);

CREATE POLICY "Only service_role can update agent_registry"
  ON public.agent_registry
  FOR UPDATE
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Only service_role can delete agent_registry"
  ON public.agent_registry
  FOR DELETE
  TO service_role
  USING (true);

-- Comments for introspection -----------------------------------------------

COMMENT ON TABLE  public.agent_registry                        IS 'FAO-GOV-002: Formalized control population. No agent executes without a row here. Risk tier, SOX controls, process owner, rollback procedure, and data sources all declared.';
COMMENT ON COLUMN public.agent_registry.agent_id               IS 'Stable slug identifier (human-readable). Used in workflow code.';
COMMENT ON COLUMN public.agent_registry.risk_tier              IS 'FAO-GOV-003: GREEN/AMBER/RED. BLOCKED forbidden via CHECK constraint.';
COMMENT ON COLUMN public.agent_registry.sox_control_ids        IS 'Array of Control IDs (FAO-GOV-*, FAO-REC-*) this agent implements or inherits.';
COMMENT ON COLUMN public.agent_registry.ai_advisory_enabled    IS 'FAO-GOV-014: Default FALSE. AI disabled by default.';
COMMENT ON COLUMN public.agent_registry.process_owner_id       IS 'FAO-GOV-013: Named process owner required. FK to process_owners.';
