-- ============================================================================
-- FinAgent OS: Seed 0007: fao_user_roles (application roles)
-- ============================================================================
-- Grants the application roles that every FinAgent RPC and read policy
-- checks. Identity is never taken from an argument: the database reads the
-- caller from auth.uid() and looks the caller's roles up here.
--
-- Control IDs implemented:
--   FAO-GOV-004  Segregation of duties: invokers and approvers are named
--                roles; nobody may decide a run they started, whatever
--                roles they hold
--
-- Grants (all agents, agent_id NULL; reason 'seed 0007'):
--   aisha.okonkwo@finagent-os.demo   invoker, approver
--   sarah.chen@finagent-os.demo      invoker, approver
--   marcus.patel@finagent-os.demo    approver, admin
--   mcp.reader@finagent-os.demo      reader (the MCP server's service user;
--                                    no process_owners row)
--
-- Prerequisites:
--   1. Migrations through 20261107_0017 have run.
--   2. Seed 0002 has run, and the Auth user mcp.reader@finagent-os.demo
--      exists (created through the Auth admin API, never by SQL).
--
-- Users are joined from auth.users by lower(email); no UUID is hardcoded.
-- A grant that already exists and is active is left as it is, so a re-run
-- adds nothing. The closing check raises unless all four users were found,
-- because the insert silently adds zero rows for a missing user.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- FAO-GOV-002: change reason for this session (required by the
-- fao_user_roles triggers).
SELECT set_config('fao.change_reason', 'seed 0007', false);

INSERT INTO public.fao_user_roles (user_id, role, agent_id, granted_by, reason)
SELECT u.id, g.role::public.fao_app_role, NULL, NULL, 'seed 0007'
  FROM (VALUES
    ('aisha.okonkwo@finagent-os.demo', 'invoker'),
    ('aisha.okonkwo@finagent-os.demo', 'approver'),
    ('sarah.chen@finagent-os.demo',    'invoker'),
    ('sarah.chen@finagent-os.demo',    'approver'),
    ('marcus.patel@finagent-os.demo',  'approver'),
    ('marcus.patel@finagent-os.demo',  'admin'),
    ('mcp.reader@finagent-os.demo',    'reader')
  ) AS g(email, role)
  JOIN auth.users u ON lower(u.email) = lower(g.email)
ON CONFLICT (user_id, role, coalesce(agent_id, '*')) WHERE revoked_at IS NULL DO NOTHING;

-- --- Check: all four users found and every grant present -------------------
DO $$
DECLARE
  v_missing text;
  v_grants  int;
BEGIN
  SELECT string_agg(e.email, ', ' ORDER BY e.email)
    INTO v_missing
    FROM (VALUES
      ('aisha.okonkwo@finagent-os.demo'),
      ('sarah.chen@finagent-os.demo'),
      ('marcus.patel@finagent-os.demo'),
      ('mcp.reader@finagent-os.demo')
    ) AS e(email)
   WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = lower(e.email));

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAO-GOV-004 seed 0007: Auth users not found: %; create them through the Auth admin API first', v_missing
      USING ERRCODE = '22023';
  END IF;

  SELECT count(*)
    INTO v_grants
    FROM public.fao_user_roles r
    JOIN auth.users u ON u.id = r.user_id
   WHERE r.revoked_at IS NULL
     AND r.agent_id IS NULL
     AND (lower(u.email), r.role::text) IN (
       ('aisha.okonkwo@finagent-os.demo', 'invoker'),
       ('aisha.okonkwo@finagent-os.demo', 'approver'),
       ('sarah.chen@finagent-os.demo',    'invoker'),
       ('sarah.chen@finagent-os.demo',    'approver'),
       ('marcus.patel@finagent-os.demo',  'approver'),
       ('marcus.patel@finagent-os.demo',  'admin'),
       ('mcp.reader@finagent-os.demo',    'reader'));

  IF v_grants <> 7 THEN
    RAISE EXCEPTION 'FAO-GOV-004 seed 0007: expected 7 active global grants, found %', v_grants
      USING ERRCODE = '22023';
  END IF;
END
$$;
