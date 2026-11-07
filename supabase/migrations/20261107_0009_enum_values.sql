-- ============================================================================
-- FinAgent OS: Migration 0009: enum values and new enum types
-- ============================================================================
-- Adds the vocabulary that phases 2 to 5 need before any table or function
-- can use it. This file runs on its own: Postgres does not allow a new enum
-- value to be used in the transaction that adds it, so 0009 must commit
-- before 0010 to 0017 are applied.
--
-- Control IDs implemented:
--   FAO-GOV-004  HITL Gateway: hitl_decision and hitl_status gain EXPIRED, so
--                a request that times out is closed with an explicit,
--                recorded outcome instead of staying PENDING forever
--   FAO-GOV-008  Run lifecycle: fao_run_state names every state a run moves
--                through (REQUESTED, RUNNING, AWAITING_HITL, COMMITTED,
--                FAILED, EXPIRED)
--   FAO-GOV-004  Application roles: fao_app_role (invoker, approver, admin,
--                reader) for public.fao_user_roles
--
-- Replaces: nothing. Migration 0001 created hitl_decision and hitl_status;
-- this file only adds a value to each.
--
-- Rollback: see phase2-5/rollback/rollback_core.sql. Postgres cannot drop an
-- enum value, so EXPIRED stays after a rollback; nothing references it once
-- the later objects are dropped.
--
-- Types carry USAGE to PUBLIC by design, so no REVOKE is needed here.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

ALTER TYPE public.hitl_decision ADD VALUE IF NOT EXISTS 'EXPIRED';
ALTER TYPE public.hitl_status   ADD VALUE IF NOT EXISTS 'EXPIRED';

-- FAO-GOV-008: run lifecycle states.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_type t
      JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'public' AND t.typname = 'fao_run_state'
  ) THEN
    CREATE TYPE public.fao_run_state AS ENUM (
      'REQUESTED', 'RUNNING', 'AWAITING_HITL', 'COMMITTED', 'FAILED', 'EXPIRED'
    );
  END IF;
END
$$;

-- FAO-GOV-004: application roles held in public.fao_user_roles.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_type t
      JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'public' AND t.typname = 'fao_app_role'
  ) THEN
    CREATE TYPE public.fao_app_role AS ENUM (
      'invoker', 'approver', 'admin', 'reader'
    );
  END IF;
END
$$;

COMMENT ON TYPE public.fao_run_state IS
  'FAO-GOV-008: lifecycle of a run in public.run_invocations. REQUESTED, RUNNING, AWAITING_HITL, COMMITTED, FAILED, EXPIRED.';
COMMENT ON TYPE public.fao_app_role IS
  'FAO-GOV-004: application roles granted in public.fao_user_roles. invoker, approver, admin, reader.';
