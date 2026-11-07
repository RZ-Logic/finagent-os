-- ============================================================================
-- FinAgent OS: Migration 0010: workflow role, private schema, new tables and
-- changes to existing tables
-- ============================================================================
-- Builds the storage that phases 2 to 5 rely on. No function, policy or
-- trigger is created here: helpers come in 0011 and 0012, guards and
-- policies in 0013, RPCs in 0014 to 0016 and the grant allow-list in 0017.
-- Until 0017 runs, no client role holds any privilege on anything this file
-- creates.
--
-- Control IDs implemented:
--   FAO-GOV-001  Audit evidence: refusal journal and admin audit tables
--                (append-only, triggers attached in 0011); ledger rows can
--                reference the row they correct; history foreign keys
--                become ON DELETE RESTRICT so evidence cannot be removed by
--                deleting a person
--   FAO-GOV-002  Settings table (fao_settings) and per-agent run rate limit
--                (agent_registry.max_runs_per_hour)
--   FAO-GOV-004  Application roles (fao_user_roles); hitl_queue coherence
--                rule extended for EXPIRED; no-self-approval and tier CHECKs;
--                frozen approval counts on every request
--   FAO-GOV-007  Notification attempts (fao_notifications)
--   FAO-GOV-008  Run records (run_invocations) and single-use run tokens
--                stored only as a hash (fao_private.run_tokens)
--
-- Replaces:
--   - the CASCADE and SET NULL delete rules on process_owners.id,
--     process_owners.escalation_to, hitl_queue.approver_id,
--     shadow_ledger.hitl_approver_id and
--     materiality_thresholds.last_reviewed_by (all become RESTRICT)
--   - the hitl_decision_coherence CHECK from migration 0005 (superset; every
--     existing row still passes)
--
-- Must work both applied on its own and inside one transaction with 0011 to
-- 0017: no CREATE INDEX CONCURRENTLY, no VACUUM, no transaction control.
-- The fao_workflow role is created NOLOGIN with no password. LOGIN and the
-- password are set outside migrations (local setup script, or the runbook).
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- FAO-GOV-002: this file changes configuration tables (structure only).
SELECT set_config('fao.change_reason', 'migration 20261107_0010_roles_schema_tables.sql', true);

-- ----------------------------------------------------------------------------
-- 1. Workflow role (FAO-GOV-008). The n8n Postgres credential logs in as this
--    role. NOINHERIT and NOBYPASSRLS: it holds only what 0017 grants it.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'fao_workflow') THEN
    CREATE ROLE fao_workflow NOLOGIN NOINHERIT NOBYPASSRLS;
  END IF;
END
$$;

ALTER ROLE fao_workflow SET statement_timeout = '30s';

-- ----------------------------------------------------------------------------
-- 2. Private schema. Not in PostgREST's exposed schemas; no client role has
--    USAGE until 0017 grants authenticated USAGE for the two RLS helpers.
-- ----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS fao_private;
REVOKE ALL ON SCHEMA fao_private FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

COMMENT ON SCHEMA fao_private IS
  'FAO-GOV-001: private helpers and secret-bearing tables for FinAgent OS. Never exposed through PostgREST.';

-- ----------------------------------------------------------------------------
-- 3. pgcrypto (already present on Supabase): random token bytes and digests.
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ----------------------------------------------------------------------------
-- 4. New tables (section 2.2 of the build spec, exactly).
-- ----------------------------------------------------------------------------

-- FAO-GOV-008: one row per requested run. The invoker comes from the session
-- (fao_run_start), never from an argument. No token material is stored here.
CREATE TABLE public.run_invocations (
  correlation_id    uuid                  PRIMARY KEY DEFAULT gen_random_uuid(),
  execution_id      uuid                  NOT NULL DEFAULT gen_random_uuid(),
  agent_id          text                  NOT NULL REFERENCES public.agent_registry(agent_id) ON DELETE RESTRICT,
  invoker_id        uuid                  NOT NULL REFERENCES public.process_owners(id) ON DELETE RESTRICT,
  risk_tier         public.risk_tier      NOT NULL CHECK (risk_tier <> 'BLOCKED'),
  invoked_via       text                  NOT NULL CHECK (invoked_via IN ('mcp','cli','test')),
  reason            text                  NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
  idempotency_key   text                  NOT NULL CHECK (idempotency_key ~ '^[A-Za-z0-9_-]{8,64}$'),
  state             public.fao_run_state  NOT NULL DEFAULT 'REQUESTED',
  asset_scope       text[],
  n8n_execution_id  text                  UNIQUE,
  requested_at      timestamptz           NOT NULL DEFAULT now(),
  claimed_at        timestamptz,
  finished_at       timestamptz,
  last_error        text,
  CONSTRAINT run_invocations_invoker_idempotency_key UNIQUE (invoker_id, idempotency_key)
);

-- Rate limit lookups: runs by an invoker for an agent in the last hour.
CREATE INDEX idx_run_invocations_invoker_agent_requested
  ON public.run_invocations (invoker_id, agent_id, requested_at);

-- Sweeper lookups: runs that are not yet terminal.
CREATE INDEX idx_run_invocations_open_state
  ON public.run_invocations (state)
  WHERE state IN ('REQUESTED','RUNNING','AWAITING_HITL');

-- FAO-GOV-008: single-use run tokens, stored only as a hash. Private schema;
-- owner only.
CREATE TABLE fao_private.run_tokens (
  correlation_id  uuid         PRIMARY KEY REFERENCES public.run_invocations(correlation_id) ON DELETE RESTRICT,
  token_hash      bytea        NOT NULL UNIQUE,
  expires_at      timestamptz  NOT NULL,
  issued_at       timestamptz  NOT NULL DEFAULT now(),
  consumed_at     timestamptz
);

-- FAO-GOV-004: application roles. A NULL agent_id means all agents. Rows are
-- revoked (revoked_at set), never deleted (guard in 0013).
CREATE TABLE public.fao_user_roles (
  id          bigserial            PRIMARY KEY,
  user_id     uuid                 NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  role        public.fao_app_role  NOT NULL,
  agent_id    text                 NULL REFERENCES public.agent_registry(agent_id) ON DELETE RESTRICT,
  granted_by  uuid                 NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  granted_at  timestamptz          NOT NULL DEFAULT now(),
  revoked_at  timestamptz,
  reason      text                 NOT NULL CHECK (length(reason) BETWEEN 1 AND 500)
);

CREATE UNIQUE INDEX fao_user_roles_active_key
  ON public.fao_user_roles (user_id, role, coalesce(agent_id, '*'))
  WHERE revoked_at IS NULL;

-- FAO-GOV-002: settings. Keys are a closed list.
CREATE TABLE public.fao_settings (
  key         text         PRIMARY KEY CHECK (key IN ('approval_app_base_url','slack_api_base_url','slack_channel_id','notify_max_attempts','journal_cap_per_minute')),
  value       text         NOT NULL,
  updated_at  timestamptz  NOT NULL DEFAULT now()
);

-- Test clock (local tests only). Empty in every deployed project; the sweep
-- reports and journals any non-zero offset.
CREATE TABLE fao_private.test_clock (
  id              int          PRIMARY KEY CHECK (id = 1),
  offset_seconds  int          NOT NULL CHECK (offset_seconds BETWEEN 0 AND 2592000),
  set_at          timestamptz  NOT NULL DEFAULT now(),
  reason          text         NOT NULL
);

-- FAO-GOV-001: refusals returned by FinAgent RPCs, journaled in the same
-- transaction. Append-only (triggers in 0011). actor_uid is authoritative
-- only when session_role = 'authenticator'.
CREATE TABLE public.fao_refusal_journal (
  refusal_id    bigserial    PRIMARY KEY,
  at            timestamptz  NOT NULL DEFAULT clock_timestamp(),
  actor_uid     uuid,
  db_role       text         NOT NULL,
  session_role  text         NOT NULL,
  entry_point   text         NOT NULL,
  target_table  text,
  target_key    text,
  attempted     jsonb        NOT NULL,
  code          text         NOT NULL,
  message       text         NOT NULL
);

CREATE INDEX idx_fao_refusal_journal_actor_role_at
  ON public.fao_refusal_journal (actor_uid, db_role, at);

CREATE INDEX idx_fao_refusal_journal_anonymous_role_at
  ON public.fao_refusal_journal (db_role, at)
  WHERE actor_uid IS NULL;

-- FAO-GOV-001: before and after images of every change to a configuration
-- table, with the change reason. Append-only (triggers in 0011).
CREATE TABLE public.fao_admin_audit (
  audit_id      bigserial    PRIMARY KEY,
  at            timestamptz  NOT NULL DEFAULT clock_timestamp(),
  table_name    text         NOT NULL,
  op            text         NOT NULL,
  row_key       jsonb,
  old_row       jsonb,
  new_row       jsonb,
  actor_uid     uuid,
  db_role       text         NOT NULL,
  session_role  text         NOT NULL,
  txid          bigint       NOT NULL,
  reason        text         NOT NULL
);

-- FAO-GOV-007: every notification attempt. At most one SENT row per
-- (request, kind, level). Append-only (triggers in 0011).
CREATE TABLE public.fao_notifications (
  notification_id     bigserial    PRIMARY KEY,
  hitl_id             bigint       NOT NULL REFERENCES public.hitl_queue(hitl_id) ON DELETE RESTRICT,
  kind                text         NOT NULL CHECK (kind IN ('REQUESTED','ESCALATED')),
  level               int          NOT NULL DEFAULT 0 CHECK (level IN (0,1)),
  outcome             text         NOT NULL CHECK (outcome IN ('SENT','FAILED')),
  attempt             int          NOT NULL CHECK (attempt >= 1),
  channel             text         NOT NULL,
  recipient_owner_id  uuid         NULL REFERENCES public.process_owners(id) ON DELETE RESTRICT,
  external_ref        text,
  error               text,
  at                  timestamptz  NOT NULL DEFAULT clock_timestamp()
);

CREATE UNIQUE INDEX fao_notifications_sent_key
  ON public.fao_notifications (hitl_id, kind, level)
  WHERE outcome = 'SENT';

-- Row level security: on for all eight tables. The six public tables get
-- SELECT policies in 0013; the two private tables never get a policy.
ALTER TABLE public.run_invocations      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fao_user_roles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fao_settings         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fao_refusal_journal  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fao_admin_audit      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fao_notifications    ENABLE ROW LEVEL SECURITY;
ALTER TABLE fao_private.run_tokens      ENABLE ROW LEVEL SECURITY;
ALTER TABLE fao_private.test_clock      ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 5. Revoke everything on the new tables and sequences. Supabase's default
--    privileges grant new public objects to the API roles; nothing here may
--    rely on them. 0017 grants the allow-list.
-- ----------------------------------------------------------------------------
REVOKE ALL ON TABLE public.run_invocations      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE public.fao_user_roles       FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE public.fao_settings         FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE public.fao_refusal_journal  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE public.fao_admin_audit      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE public.fao_notifications    FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE fao_private.run_tokens      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON TABLE fao_private.test_clock      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

REVOKE ALL ON SEQUENCE public.fao_user_roles_id_seq                  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON SEQUENCE public.fao_refusal_journal_refusal_id_seq     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON SEQUENCE public.fao_admin_audit_audit_id_seq           FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON SEQUENCE public.fao_notifications_notification_id_seq  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;

-- ----------------------------------------------------------------------------
-- 6. Changes to existing tables. Adding a column with a constant default
--    neither rewrites rows nor fires row triggers, so the shadow_ledger
--    append-only trigger is not involved.
-- ----------------------------------------------------------------------------

-- process_owners (FAO-GOV-013, FAO-GOV-004): an owner can be deactivated
-- instead of deleted; email is unique ignoring case.
ALTER TABLE public.process_owners
  ADD COLUMN active boolean NOT NULL DEFAULT true;

CREATE UNIQUE INDEX process_owners_email_lower_key
  ON public.process_owners (lower(email));

-- agent_registry (FAO-GOV-002): per-agent run rate limit for fao_run_start.
ALTER TABLE public.agent_registry
  ADD COLUMN max_runs_per_hour int NOT NULL DEFAULT 6
    CONSTRAINT agent_max_runs_per_hour_range CHECK (max_runs_per_hour BETWEEN 1 AND 60);

-- hitl_queue (FAO-GOV-004): approval counts frozen at creation, the approval
-- link, and the assets that caused the review.
ALTER TABLE public.hitl_queue
  ADD COLUMN configured_approvals int   NOT NULL DEFAULT 1 CHECK (configured_approvals >= 1),
  ADD COLUMN enforced_approvals   int   NOT NULL DEFAULT 1 CHECK (enforced_approvals >= 1),
  ADD COLUMN approval_url         text,
  ADD COLUMN escalated_assets     jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Coherence rule extended for EXPIRED. A superset of the 0005 rule, so every
-- existing row passes and the constraint is validated.
ALTER TABLE public.hitl_queue DROP CONSTRAINT hitl_decision_coherence;
ALTER TABLE public.hitl_queue ADD CONSTRAINT hitl_decision_coherence CHECK (
  (decision = 'PENDING' AND approver_id IS NULL AND decided_at IS NULL)
  OR (decision IN ('APPROVED','REJECTED') AND approver_id IS NOT NULL AND decided_at IS NOT NULL)
  OR (decision = 'EXPIRED' AND approver_id IS NULL AND decided_at IS NOT NULL)
);

-- NOT VALID: enforced for every new or changed row; historical rows stay as
-- evidence exactly as recorded.
ALTER TABLE public.hitl_queue ADD CONSTRAINT hitl_no_self_approval
  CHECK (approver_id IS NULL OR approver_id <> agent_invoker_id) NOT VALID;
ALTER TABLE public.hitl_queue ADD CONSTRAINT hitl_tier_not_blocked
  CHECK (risk_tier <> 'BLOCKED') NOT VALID;

-- shadow_ledger (FAO-GOV-001): a CORRECTION row references the row it
-- corrects; the original is never changed.
ALTER TABLE public.shadow_ledger
  ADD COLUMN corrects_ledger_id bigint NULL REFERENCES public.shadow_ledger(ledger_id) ON DELETE RESTRICT;

CREATE INDEX idx_shadow_ledger_corr_event
  ON public.shadow_ledger (correlation_id, (inputs->>'event_type'));

-- History foreign keys become ON DELETE RESTRICT (FAO-GOV-001): deleting a
-- person must never delete or blank out evidence that names them. Constraint
-- names are looked up from pg_constraint, never assumed; each is dropped and
-- re-added under the same name.
DO $$
DECLARE
  r      record;
  c      record;
  v_name text;
  v_n    int;
BEGIN
  FOR r IN
    SELECT *
      FROM (VALUES
        (1, 'process_owners',         'id',               'auth',   'users',          'id'),
        (2, 'process_owners',         'escalation_to',    'public', 'process_owners', 'id'),
        (3, 'hitl_queue',             'approver_id',      'public', 'process_owners', 'id'),
        (4, 'shadow_ledger',          'hitl_approver_id', 'public', 'process_owners', 'id'),
        (5, 'materiality_thresholds', 'last_reviewed_by', 'public', 'process_owners', 'id')
      ) AS t(ord, tbl, col, ref_schema, ref_tbl, ref_col)
     ORDER BY ord
  LOOP
    v_name := NULL;
    v_n := 0;
    FOR c IN
      SELECT con.conname
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class cl      ON cl.oid = con.conrelid
        JOIN pg_catalog.pg_namespace ns  ON ns.oid = cl.relnamespace
        JOIN pg_catalog.pg_attribute att ON att.attrelid = cl.oid AND att.attname = r.col
       WHERE ns.nspname = 'public'
         AND cl.relname = r.tbl
         AND con.contype = 'f'
         AND con.conkey = ARRAY[att.attnum]
       ORDER BY con.conname
    LOOP
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.tbl, c.conname);
      v_name := coalesce(v_name, c.conname);
      v_n := v_n + 1;
    END LOOP;

    IF v_n = 0 THEN
      RAISE EXCEPTION 'FAO-GOV-001 migration 0010: expected a foreign key on public.%.%, found none', r.tbl, r.col
        USING ERRCODE = '22023';
    END IF;

    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I.%I(%I) ON DELETE RESTRICT',
      r.tbl, v_name, r.col, r.ref_schema, r.ref_tbl, r.ref_col
    );
  END LOOP;
END
$$;

-- ----------------------------------------------------------------------------
-- 7. Comments naming each new table's control.
-- ----------------------------------------------------------------------------
COMMENT ON TABLE public.run_invocations IS
  'FAO-GOV-008: one row per requested run. Invoker taken from the session by fao_run_start; state moves are guarded (0013). No token material is stored here.';
COMMENT ON TABLE fao_private.run_tokens IS
  'FAO-GOV-008: single-use run tokens, stored only as a hash, consumed by fao_run_claim. Owner only.';
COMMENT ON TABLE public.fao_user_roles IS
  'FAO-GOV-004: application roles (invoker, approver, admin, reader). NULL agent_id means all agents. Revoked, never deleted.';
COMMENT ON TABLE public.fao_settings IS
  'FAO-GOV-002: FinAgent OS settings (closed key list). Changes need fao.change_reason and are audited.';
COMMENT ON TABLE fao_private.test_clock IS
  'Test clock offset for local tests only. Empty in every deployed project; the maintenance sweep reports and journals any offset.';
COMMENT ON TABLE public.fao_refusal_journal IS
  'FAO-GOV-001: refusals returned by FinAgent RPCs, journaled in the same transaction with a per-actor flood cap. Append-only.';
COMMENT ON TABLE public.fao_admin_audit IS
  'FAO-GOV-001: before and after images of every change to a configuration table, with actor and change reason. Append-only.';
COMMENT ON TABLE public.fao_notifications IS
  'FAO-GOV-007: every HITL notification attempt and its outcome. At most one SENT row per request, kind and level. Append-only.';

COMMENT ON COLUMN public.process_owners.active IS
  'FAO-GOV-013: false deactivates the owner without deleting evidence that names them.';
COMMENT ON COLUMN public.agent_registry.max_runs_per_hour IS
  'FAO-GOV-002: maximum runs per invoker per hour for this agent (1 to 60), enforced by fao_run_start.';
COMMENT ON COLUMN public.hitl_queue.configured_approvals IS
  'FAO-GOV-004: approval count configured in the registry when the request was created (frozen).';
COMMENT ON COLUMN public.hitl_queue.enforced_approvals IS
  'FAO-GOV-004: approval count enforced today (1; dual approval is not yet enforced, ADR-0001). Frozen.';
COMMENT ON COLUMN public.shadow_ledger.corrects_ledger_id IS
  'FAO-GOV-001: set only on a CORRECTION row; references the ledger row it corrects. The original row is never changed.';
