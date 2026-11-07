-- ============================================================================
-- FinAgent OS — Seed 0002: process_owners
-- ============================================================================
-- Seeds the three baseline process owner identities used throughout the
-- platform demos and the reconciliation agent's HITL routing.
--
-- Prerequisites:
--   1. Migration 20260420_0002_process_owners.sql has run successfully.
--   2. Three Supabase Auth users have been created via Dashboard
--      (Authentication → Users → Add User, with Auto Confirm User = ON):
--        - sarah.chen@finagent-os.demo      (Controller)
--        - marcus.patel@finagent-os.demo    (CFO)
--        - aisha.okonkwo@finagent-os.demo   (FP&A Lead)
--
-- Design notes:
--   - UUIDs are NOT hardcoded. The seed joins auth.users by email, so the
--     same script works in any environment where those three auth users
--     have been created with matching emails.
--   - Escalation is populated via a second UPDATE pass because the
--     hierarchy is self-referential (Aisha → Sarah → Marcus) and rows
--     cannot reference themselves before they exist.
--   - Running this seed more than once will fail on the UNIQUE(email)
--     constraint. That is intentional: seeds are one-time, not
--     idempotent. Re-seed only a fresh database; never re-seed one that
--     holds evidence. TRUNCATE is refused on process_owners and on every
--     table that references it (FAO-GOV-001, phase 2-5 migration 0013).
--   - Phase 2-5: the first statement sets fao.change_reason, which every
--     change to process_owners now needs (FAO-GOV-002). The closing check
--     raises unless exactly three owners exist, because the inserts below
--     silently add zero rows when the Auth users are missing.
--
-- Escalation hierarchy:
--   Aisha Okonkwo  (FP&A Lead)   →  Sarah Chen  (Controller)
--   Sarah Chen     (Controller)  →  Marcus Patel (CFO)
--   Marcus Patel   (CFO)         →  NULL (top of hierarchy)
--
-- Author: Rizwan Ahmed, ACCA · Velocyt Consulting
-- Date:   2026-04-20
-- ============================================================================

-- FAO-GOV-002: change reason for this session (required by the
-- process_owners triggers).
SELECT set_config('fao.change_reason', 'seed 0002', false);

-- --- Pass 1: Insert the three rows without escalation ----------------------

INSERT INTO public.process_owners (id, name, role, email, escalation_to)
SELECT u.id, 'Sarah Chen', 'Controller', 'sarah.chen@finagent-os.demo', NULL
FROM auth.users u WHERE u.email = 'sarah.chen@finagent-os.demo';

INSERT INTO public.process_owners (id, name, role, email, escalation_to)
SELECT u.id, 'Marcus Patel', 'CFO', 'marcus.patel@finagent-os.demo', NULL
FROM auth.users u WHERE u.email = 'marcus.patel@finagent-os.demo';

INSERT INTO public.process_owners (id, name, role, email, escalation_to)
SELECT u.id, 'Aisha Okonkwo', 'FP&A Lead', 'aisha.okonkwo@finagent-os.demo', NULL
FROM auth.users u WHERE u.email = 'aisha.okonkwo@finagent-os.demo';

-- --- Pass 2: Populate the escalation chain ---------------------------------

-- Sarah (Controller) escalates to Marcus (CFO)
UPDATE public.process_owners
SET escalation_to = (
  SELECT id FROM public.process_owners WHERE email = 'marcus.patel@finagent-os.demo'
)
WHERE email = 'sarah.chen@finagent-os.demo';

-- Aisha (FP&A Lead) escalates to Sarah (Controller)
UPDATE public.process_owners
SET escalation_to = (
  SELECT id FROM public.process_owners WHERE email = 'sarah.chen@finagent-os.demo'
)
WHERE email = 'aisha.okonkwo@finagent-os.demo';

-- Marcus (CFO) has no escalation target — left NULL.

-- --- Check: exactly three owners -------------------------------------------
-- The inserts above add zero rows, silently, when an Auth user is missing.
-- Fail loudly instead (FAO-GOV-013: every agent needs a named owner).
DO $$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM public.process_owners;
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'FAO-GOV-013 seed 0002: expected exactly 3 process owners, found %; create the three Auth users first', v_n
      USING ERRCODE = '22023';
  END IF;
END
$$;
