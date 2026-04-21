-- ============================================================================
-- FinAgent OS — Migration 0002: process_owners Table + RLS
-- ============================================================================
-- Creates the identity anchor for FinAgent OS governance. Every agent,
-- every HITL approval, every materiality threshold review references a
-- process_owner. The table's primary key is a foreign key to Supabase's
-- built-in auth.users table — so every process_owner is backed by a real
-- authenticated identity, not a free-text string. This directly satisfies
-- FAO-GOV-013 (Process Owner Named on Every Agent) and the JD requirement:
-- "No build goes to production without a named Process Owner."
--
-- Control IDs implemented:
--   FAO-GOV-013  Process Owner Named on Every Agent (identity layer)
--
-- Notes:
--   - RLS is enabled on this table (Supabase's automatic-RLS setting created
--     a default policy on table creation; we replace it with explicit ones).
--   - SELECT is granted to all authenticated users because agent_registry,
--     hitl_queue, and shadow_ledger all reference process_owners and need
--     to resolve names/roles when rendering records.
--   - INSERT/UPDATE/DELETE are restricted to the service_role Postgres role,
--     i.e. administrative access only. In production, adding a new process
--     owner is a deliberate governed change, not something an agent does.
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

-- The table itself
CREATE TABLE public.process_owners (
  -- Primary key: FK to auth.users(id). Cascade on delete so removing a
  -- Supabase auth user also removes the process_owner record — preserves
  -- referential integrity without orphaned rows.
  id            UUID         PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Human-readable name. Appears in HITL approval UI and audit exports.
  name          TEXT         NOT NULL,

  -- Role title within the finance org. Examples: Controller, CFO, FP&A Lead,
  -- Treasurer, Tax Director. Kept as TEXT rather than ENUM so new roles can
  -- be added without a schema migration.
  role          TEXT         NOT NULL,

  -- Email address. Used for HITL notification routing and Slack identity
  -- mapping. Should match the email on the linked auth.users row.
  email         TEXT         NOT NULL UNIQUE,

  -- Self-referential FK for escalation hierarchy. NULL means this process
  -- owner is at the top of the escalation chain (typically the CFO).
  escalation_to UUID         REFERENCES public.process_owners(id) ON DELETE SET NULL,

  -- Standard timestamps
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Index on escalation_to for fast chain traversal when rendering org hierarchy.
CREATE INDEX idx_process_owners_escalation_to
  ON public.process_owners(escalation_to);

-- Enable RLS (automatic-RLS setting should already have done this; explicit
-- re-enable is harmless and documents intent).
ALTER TABLE public.process_owners ENABLE ROW LEVEL SECURITY;

-- --- RLS Policies ------------------------------------------------------------

-- SELECT: authenticated users can read all process_owners.
-- Rationale: the process_owners table is organizational context, not
-- sensitive data. Agent workflows, HITL routing, and audit exports all
-- need to look up owners by id, so broad SELECT is required for the
-- platform to function.
CREATE POLICY "Authenticated users can read process_owners"
  ON public.process_owners
  FOR SELECT
  TO authenticated
  USING (true);

-- INSERT/UPDATE/DELETE: only the service_role can modify process_owners.
-- Rationale: adding, changing, or removing a process owner is a deliberate
-- governance action performed by an administrator via the Supabase
-- dashboard or via a service-role-authenticated backend process. No
-- end-user identity should be able to mutate this table directly.
CREATE POLICY "Only service_role can insert process_owners"
  ON public.process_owners
  FOR INSERT
  TO service_role
  WITH CHECK (true);

CREATE POLICY "Only service_role can update process_owners"
  ON public.process_owners
  FOR UPDATE
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Only service_role can delete process_owners"
  ON public.process_owners
  FOR DELETE
  TO service_role
  USING (true);

-- --- Comments for introspection ---------------------------------------------

COMMENT ON TABLE  public.process_owners                 IS 'FAO-GOV-013: Named identities responsible for agents, approvals, and threshold reviews. FK to auth.users ensures every owner is a real authenticated identity.';
COMMENT ON COLUMN public.process_owners.id              IS 'FK to auth.users(id). Cascade delete.';
COMMENT ON COLUMN public.process_owners.escalation_to   IS 'Self-FK for escalation chain. NULL = top of hierarchy.';
