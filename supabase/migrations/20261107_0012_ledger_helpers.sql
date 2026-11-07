-- ============================================================================
-- FinAgent OS: Migration 0012: ledger helpers
-- ============================================================================
-- The private helpers every FinAgent RPC uses to write and read the Shadow
-- Ledger: the run context, the single insert point for database-written
-- events, the one rollup implementation (in SQL, replacing both JavaScript
-- rollups in the workflow exports), the fixed rationale wording, and HITL
-- request creation.
--
-- These come before the guards (0013) because the legacy closure in 0013
-- appends HITL_EXPIRED events through append_event.
--
-- Control IDs implemented:
--   FAO-GOV-001  append_event is the only insert point for database-written
--                ledger events (RUN_REFUSED excepted, see 0014); timestamps,
--                execution id, agent and tier always come from the database
--   FAO-GOV-004  create_request opens a HITL request with frozen approval
--                counts, review sub-tier and escalated assets, and appends
--                HITL_REQUESTED in the same transaction
--   FAO-GOV-007  the approval link is built from the approval_app_base_url
--                setting and the request id only
--   FAO-GOV-008  run_context threads correlation, execution id, agent and tier
--   FAO-REC-001  run_rollup: worst-asset rule over per-asset outcomes; the
--                audit chain (one STARTED, one ASSET_RECONCILED per asset in
--                scope) is checked before any rollup is produced; no units are
--                ever summed across assets and no aggregate ratio exists
--
-- Replaces: the Aggregate Rollup and rationale logic that lived in the
-- workflow Code nodes (one implementation now, in the database).
--
-- Every function: schema fao_private, SECURITY DEFINER, SET search_path = '',
-- fully qualified names, no client grants (revoked at the end of this file;
-- 0017 grants nothing on them).
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- run_context (FAO-GOV-008)
-- ----------------------------------------------------------------------------
-- The execution id, agent and tier for a correlation id.
--   1. From run_invocations when the run record exists (has_run_record true).
--   2. Else (runs from before run records existed) agent and tier from the
--      newest hitl_queue row for the correlation, execution id from the
--      earliest ledger row (the correlation id itself when the request has no
--      ledger row at all).
--   3. Else agent, tier and execution id from the earliest ledger row.
--   4. Else raise: the correlation is unknown.
CREATE FUNCTION fao_private.run_context(
  p_correlation_id uuid,
  OUT execution_id   uuid,
  OUT agent_id       text,
  OUT risk_tier      public.risk_tier,
  OUT has_run_record boolean
)
RETURNS record
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_found boolean;
BEGIN
  IF p_correlation_id IS NULL THEN
    RAISE EXCEPTION 'FAO-GOV-008 run_context: unknown correlation %', '<null>'
      USING ERRCODE = '22023';
  END IF;

  SELECT ri.execution_id, ri.agent_id, ri.risk_tier
    INTO execution_id, agent_id, risk_tier
    FROM public.run_invocations ri
   WHERE ri.correlation_id = p_correlation_id;
  IF FOUND THEN
    has_run_record := true;
    RETURN;
  END IF;

  has_run_record := false;

  SELECT h.agent_id, h.risk_tier
    INTO agent_id, risk_tier
    FROM public.hitl_queue h
   WHERE h.correlation_id = p_correlation_id
   ORDER BY h.hitl_id DESC
   LIMIT 1;
  v_found := FOUND;

  IF v_found THEN
    SELECT l.execution_id
      INTO execution_id
      FROM public.shadow_ledger l
     WHERE l.correlation_id = p_correlation_id
     ORDER BY l.ledger_id
     LIMIT 1;
    execution_id := coalesce(execution_id, p_correlation_id);
    RETURN;
  END IF;

  SELECT l.execution_id, l.agent_id, l.risk_tier
    INTO execution_id, agent_id, risk_tier
    FROM public.shadow_ledger l
   WHERE l.correlation_id = p_correlation_id
   ORDER BY l.ledger_id
   LIMIT 1;
  IF FOUND THEN
    RETURN;
  END IF;

  RAISE EXCEPTION 'FAO-GOV-008 run_context: unknown correlation %', p_correlation_id
    USING ERRCODE = '22023';
END;
$$;

COMMENT ON FUNCTION fao_private.run_context(uuid) IS
  'FAO-GOV-008: execution id, agent and tier for a correlation id, from the run record, else the newest request and earliest ledger row, else the earliest ledger row; raises for an unknown correlation.';

-- ----------------------------------------------------------------------------
-- append_event (FAO-GOV-001)
-- ----------------------------------------------------------------------------
-- The only insert point for ledger events written by database functions
-- (RUN_REFUSED excepted, 0014). Context (execution id, agent, tier) comes from
-- run_context; inputs.event_type is forced to p_event_type; event_timestamp is
-- left to its default. Only the event types of the build spec (2.10) are
-- accepted.
CREATE FUNCTION fao_private.append_event(
  p_correlation_id   uuid,
  p_event_type       text,
  p_inputs           jsonb,
  p_policy_outcome   public.policy_outcome,
  p_sub_tier         public.policy_sub_tier,
  p_rationale        text,
  p_obligations      text[],
  p_hitl_status      public.hitl_status,
  p_hitl_approver_id uuid,
  p_status           public.execution_status,
  p_error            text,
  p_corrects         bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v   record;
  v_id bigint;
BEGIN
  IF p_event_type IS NULL OR p_event_type NOT IN (
       'STARTED', 'ASSET_RECONCILED', 'FAILED', 'RUN_REFUSED', 'HITL_REQUESTED',
       'NOTIFICATION_SENT', 'NOTIFICATION_FAILED', 'HITL_RESOLVED', 'HITL_EXPIRED',
       'HITL_ESCALATED', 'COMMITTED', 'COMMIT_BLOCKED', 'CORRECTION') THEN
    RAISE EXCEPTION 'FAO-GOV-001 append_event: unknown event type %', coalesce(p_event_type, '<null>')
      USING ERRCODE = '22023';
  END IF;

  IF p_inputs IS NOT NULL AND jsonb_typeof(p_inputs) <> 'object' THEN
    RAISE EXCEPTION 'FAO-GOV-001 append_event: inputs must be an object'
      USING ERRCODE = '22023';
  END IF;

  v := fao_private.run_context(p_correlation_id);

  INSERT INTO public.shadow_ledger (
    correlation_id, execution_id, agent_id, risk_tier, inputs,
    policy_outcome, policy_sub_tier, policy_rationale, obligations,
    hitl_status, hitl_approver_id, status, error_details, corrects_ledger_id
  )
  VALUES (
    p_correlation_id, v.execution_id, v.agent_id, v.risk_tier,
    coalesce(p_inputs, '{}'::jsonb) || jsonb_build_object('event_type', p_event_type),
    p_policy_outcome, p_sub_tier, p_rationale, coalesce(p_obligations, ARRAY[]::text[]),
    coalesce(p_hitl_status, 'NOT_REQUIRED'::public.hitl_status), p_hitl_approver_id,
    p_status, p_error, p_corrects
  )
  RETURNING ledger_id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION fao_private.append_event(uuid, text, jsonb, public.policy_outcome, public.policy_sub_tier, text, text[], public.hitl_status, uuid, public.execution_status, text, bigint) IS
  'FAO-GOV-001: the only insert point for database-written ledger events. Context from run_context, inputs.event_type forced, timestamp from the database. Returns ledger_id.';

-- ----------------------------------------------------------------------------
-- run_rollup (FAO-REC-001, FAO-GOV-001)
-- ----------------------------------------------------------------------------
-- 1. expected      := run_invocations.asset_scope (NULL with no run record or
--                     before STARTED)
-- 2. started_count := STARTED rows for the correlation
-- 3. asset rows    := ASSET_RECONCILED rows ordered by ledger_id
-- 4. missing, duplicate, unexpected (each sorted)
-- 5. chain_ok      := started_count = 1, expected set, all three lists empty
-- 6. when chain_ok: per_asset_summary, counts, worst-asset rollup, review
--    sub-tier, hitl_required, obligations, escalated_assets (scope order)
-- 7. otherwise every rollup field is NULL
-- Rank: ALLOW 0, ALLOW_WITH_OBLIGATIONS 1, REQUIRE_HUMAN 2, DENY 3, BLOCKED 4.
-- Never sums units across assets; there is no aggregate ratio.
CREATE FUNCTION fao_private.run_rollup(p_correlation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expected     text[];
  v_started      int;
  v_missing      jsonb;
  v_duplicate    jsonb;
  v_unexpected   jsonb;
  v_chain_ok     boolean;
  v_problems     jsonb;
  v_summary      jsonb := '[]'::jsonb;
  v_escalated    jsonb := '[]'::jsonb;
  v_counts       jsonb;
  v_obligations  jsonb;
  v_outcome      text := 'ALLOW';
  v_sub_tier     text := NULL;
  v_worst        int  := 0;
  v_review       text := 'STANDARD';
  v_hitl         boolean := false;
  v_rank         int;
  a              record;
BEGIN
  SELECT ri.asset_scope
    INTO v_expected
    FROM public.run_invocations ri
   WHERE ri.correlation_id = p_correlation_id;

  SELECT count(*)
    INTO v_started
    FROM public.shadow_ledger l
   WHERE l.correlation_id = p_correlation_id
     AND l.inputs->>'event_type' = 'STARTED';

  -- Assets in scope with no ASSET_RECONCILED row.
  SELECT coalesce(jsonb_agg(e.sym ORDER BY e.sym), '[]'::jsonb)
    INTO v_missing
    FROM unnest(coalesce(v_expected, ARRAY[]::text[])) AS e(sym)
   WHERE NOT EXISTS (
     SELECT 1
       FROM public.shadow_ledger l
      WHERE l.correlation_id = p_correlation_id
        AND l.inputs->>'event_type' = 'ASSET_RECONCILED'
        AND l.inputs->>'asset' = e.sym);

  -- Assets recorded more than once.
  SELECT coalesce(jsonb_agg(d.sym ORDER BY d.sym), '[]'::jsonb)
    INTO v_duplicate
    FROM (
      SELECT l.inputs->>'asset' AS sym
        FROM public.shadow_ledger l
       WHERE l.correlation_id = p_correlation_id
         AND l.inputs->>'event_type' = 'ASSET_RECONCILED'
       GROUP BY l.inputs->>'asset'
      HAVING count(*) > 1
    ) d;

  -- Assets recorded that are not in scope (all of them when there is no
  -- scope). A row with no asset at all is reported as unexpected (JSON null).
  SELECT coalesce(jsonb_agg(u.sym ORDER BY u.sym), '[]'::jsonb)
    INTO v_unexpected
    FROM (
      SELECT DISTINCT l.inputs->>'asset' AS sym
        FROM public.shadow_ledger l
       WHERE l.correlation_id = p_correlation_id
         AND l.inputs->>'event_type' = 'ASSET_RECONCILED'
         AND ((l.inputs->>'asset') = ANY (coalesce(v_expected, ARRAY[]::text[]))) IS NOT TRUE
    ) u;

  v_chain_ok := v_started = 1
            AND v_expected IS NOT NULL
            AND jsonb_array_length(v_missing) = 0
            AND jsonb_array_length(v_duplicate) = 0
            AND jsonb_array_length(v_unexpected) = 0;

  v_problems := jsonb_build_object(
    'missing',       v_missing,
    'duplicate',     v_duplicate,
    'unexpected',    v_unexpected,
    'started_count', v_started);

  IF NOT v_chain_ok THEN
    RETURN jsonb_build_object(
      'chain_ok',          false,
      'problems',          v_problems,
      'rollup_outcome',    NULL,
      'rollup_sub_tier',   NULL,
      'review_sub_tier',   NULL,
      'hitl_required',     NULL,
      'per_asset_summary', NULL,
      'counts',            NULL,
      'escalated_assets',  NULL,
      'obligations',       NULL);
  END IF;

  -- Worst-asset rule, in asset-scope order (identical to the former workflow
  -- rollup): a strictly higher rank replaces outcome and sub-tier; an equal
  -- rank with CRITICAL sets CRITICAL.
  FOR a IN
    SELECT s.sym,
           s.ord,
           l.inputs->'band_status'       AS band_status,
           l.inputs->'ratio'             AS ratio,
           l.policy_outcome::text        AS outcome,
           l.policy_sub_tier::text       AS sub_tier
      FROM unnest(v_expected) WITH ORDINALITY AS s(sym, ord)
      JOIN public.shadow_ledger l
        ON l.correlation_id = p_correlation_id
       AND l.inputs->>'event_type' = 'ASSET_RECONCILED'
       AND l.inputs->>'asset' = s.sym
     ORDER BY s.ord
  LOOP
    v_rank := CASE a.outcome
                WHEN 'ALLOW'                  THEN 0
                WHEN 'ALLOW_WITH_OBLIGATIONS' THEN 1
                WHEN 'REQUIRE_HUMAN'          THEN 2
                WHEN 'DENY'                   THEN 3
                WHEN 'BLOCKED'                THEN 4
              END;

    IF v_rank > v_worst THEN
      v_worst    := v_rank;
      v_outcome  := a.outcome;
      v_sub_tier := a.sub_tier;
    ELSIF v_rank = v_worst AND a.sub_tier = 'CRITICAL' THEN
      v_sub_tier := 'CRITICAL';
    END IF;

    IF a.outcome IN ('DENY', 'BLOCKED') OR a.sub_tier = 'CRITICAL' THEN
      v_review := 'CRITICAL';
    END IF;

    v_summary := v_summary || jsonb_build_array(jsonb_build_object(
      'asset',           a.sym,
      'band_status',     coalesce(a.band_status, 'null'::jsonb),
      'ratio',           coalesce(a.ratio, 'null'::jsonb),
      'policy_outcome',  a.outcome,
      'policy_sub_tier', a.sub_tier));

    IF v_rank >= 2 THEN
      v_hitl := true;
      v_escalated := v_escalated || jsonb_build_array(jsonb_build_object(
        'asset',           a.sym,
        'policy_outcome',  a.outcome,
        'policy_sub_tier', a.sub_tier,
        'band_status',     coalesce(a.band_status, 'null'::jsonb)));
    END IF;
  END LOOP;

  SELECT jsonb_build_object(
           'ALLOW',                  count(*) FILTER (WHERE l.policy_outcome = 'ALLOW'),
           'ALLOW_WITH_OBLIGATIONS', count(*) FILTER (WHERE l.policy_outcome = 'ALLOW_WITH_OBLIGATIONS'),
           'REQUIRE_HUMAN',          count(*) FILTER (WHERE l.policy_outcome = 'REQUIRE_HUMAN'),
           'DENY',                   count(*) FILTER (WHERE l.policy_outcome = 'DENY'),
           'BLOCKED',                count(*) FILTER (WHERE l.policy_outcome = 'BLOCKED'))
    INTO v_counts
    FROM public.shadow_ledger l
   WHERE l.correlation_id = p_correlation_id
     AND l.inputs->>'event_type' = 'ASSET_RECONCILED';

  SELECT coalesce(jsonb_agg(o.ob ORDER BY o.ob), '[]'::jsonb)
    INTO v_obligations
    FROM (
      SELECT DISTINCT ob
        FROM public.shadow_ledger l
        CROSS JOIN LATERAL unnest(coalesce(l.obligations, ARRAY[]::text[])) AS ob
       WHERE l.correlation_id = p_correlation_id
         AND l.inputs->>'event_type' = 'ASSET_RECONCILED'
    ) o;

  RETURN jsonb_build_object(
    'chain_ok',          true,
    'problems',          v_problems,
    'rollup_outcome',    v_outcome,
    'rollup_sub_tier',   v_sub_tier,
    'review_sub_tier',   v_review,
    'hitl_required',     v_hitl,
    'per_asset_summary', v_summary,
    'counts',            v_counts,
    'escalated_assets',  v_escalated,
    'obligations',       v_obligations);
END;
$$;

COMMENT ON FUNCTION fao_private.run_rollup(uuid) IS
  'FAO-REC-001, FAO-GOV-001: the one rollup implementation. Checks the audit chain (one STARTED, one ASSET_RECONCILED per asset in scope, nothing unexpected), then applies the worst-asset rule. No aggregate ratio; units are never summed across assets.';

-- ----------------------------------------------------------------------------
-- compose_rationale (FAO-REC-001)
-- ----------------------------------------------------------------------------
-- The COMMITTED and HITL request rationale, one implementation for both.
-- Parts joined with one space:
--   1. FAO-REC-001 execution rollup over <n> assets.
--   2. Outcomes: <a> ALLOW, <b> ALLOW_WITH_OBLIGATIONS, <c> REQUIRE_HUMAN
--      [, <d> DENY when d > 0][, <e> BLOCKED when e > 0].
--   3. Worst-asset rule applied: execution outcome = <outcome>[ (<sub_tier>)].
--   4. When any asset has rank >= 2: Escalated assets: <SYM> (<outcome>
--      [/<sub_tier>]), ... in asset-scope order, then a full stop.
--   5. HITL_REQUEST only: Human review required (review sub-tier <tier>).
-- Raises for an unknown kind or a rollup whose chain is not intact.
CREATE FUNCTION fao_private.compose_rationale(p_rollup jsonb, p_kind text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_parts   text[] := ARRAY[]::text[];
  v_n       int;
  v_counts  jsonb;
  v_part    text;
  v_esc     text;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('COMMITTED', 'HITL_REQUEST') THEN
    RAISE EXCEPTION 'FAO-REC-001 compose_rationale: unknown kind %', coalesce(p_kind, '<null>')
      USING ERRCODE = '22023';
  END IF;

  IF p_rollup IS NULL
     OR (p_rollup->>'chain_ok')::boolean IS NOT TRUE
     OR jsonb_typeof(p_rollup->'per_asset_summary') IS DISTINCT FROM 'array'
     OR jsonb_typeof(p_rollup->'counts') IS DISTINCT FROM 'object'
     OR p_rollup->>'rollup_outcome' IS NULL THEN
    RAISE EXCEPTION 'FAO-REC-001 compose_rationale: the rollup has no intact audit chain'
      USING ERRCODE = '22023';
  END IF;

  v_n      := jsonb_array_length(p_rollup->'per_asset_summary');
  v_counts := p_rollup->'counts';

  -- 1
  v_parts := v_parts || format('FAO-REC-001 execution rollup over %s assets.', v_n);

  -- 2
  v_part := format('Outcomes: %s ALLOW, %s ALLOW_WITH_OBLIGATIONS, %s REQUIRE_HUMAN',
                   coalesce((v_counts->>'ALLOW')::int, 0),
                   coalesce((v_counts->>'ALLOW_WITH_OBLIGATIONS')::int, 0),
                   coalesce((v_counts->>'REQUIRE_HUMAN')::int, 0));
  IF coalesce((v_counts->>'DENY')::int, 0) > 0 THEN
    v_part := v_part || format(', %s DENY', (v_counts->>'DENY')::int);
  END IF;
  IF coalesce((v_counts->>'BLOCKED')::int, 0) > 0 THEN
    v_part := v_part || format(', %s BLOCKED', (v_counts->>'BLOCKED')::int);
  END IF;
  v_parts := v_parts || (v_part || '.');

  -- 3
  v_part := 'Worst-asset rule applied: execution outcome = ' || (p_rollup->>'rollup_outcome');
  IF p_rollup->>'rollup_sub_tier' IS NOT NULL THEN
    v_part := v_part || ' (' || (p_rollup->>'rollup_sub_tier') || ')';
  END IF;
  v_parts := v_parts || (v_part || '.');

  -- 4 (escalated assets come from the summary, in asset-scope order)
  SELECT string_agg(
           (e.value->>'asset') || ' (' || (e.value->>'policy_outcome')
             || CASE WHEN e.value->>'policy_sub_tier' IS NOT NULL
                     THEN '/' || (e.value->>'policy_sub_tier') ELSE '' END
             || ')',
           ', ' ORDER BY e.ord)
    INTO v_esc
    FROM jsonb_array_elements(p_rollup->'per_asset_summary') WITH ORDINALITY AS e(value, ord)
   WHERE e.value->>'policy_outcome' IN ('REQUIRE_HUMAN', 'DENY', 'BLOCKED');
  IF v_esc IS NOT NULL THEN
    v_parts := v_parts || ('Escalated assets: ' || v_esc || '.');
  END IF;

  -- 5
  IF p_kind = 'HITL_REQUEST' THEN
    v_parts := v_parts || format('Human review required (review sub-tier %s).',
                                 coalesce(p_rollup->>'review_sub_tier', 'STANDARD'));
  END IF;

  RETURN array_to_string(v_parts, ' ');
END;
$$;

COMMENT ON FUNCTION fao_private.compose_rationale(jsonb, text) IS
  'FAO-REC-001: fixed rationale wording for COMMITTED and HITL request rows (asset count, outcome counts, worst-asset rule, escalated assets, review sub-tier for requests).';

-- ----------------------------------------------------------------------------
-- create_request (FAO-GOV-004, FAO-GOV-007)
-- ----------------------------------------------------------------------------
-- Opens the HITL request for a RUNNING run whose rollup needs review and
-- appends HITL_REQUESTED, in the caller's transaction (fao_run_finalize).
--   1. The run and its agent; the agent must be ACTIVE with an SLA for HITL
--      resolution, else raise.
--   2. The approval link base from settings; missing raises.
--   3. The id is taken from the sequence first, so the link can be stored on
--      insert (no later update of a frozen field).
--   4. Insert the request: tier and invoker from the run, review sub-tier,
--      rationale, configured approvals from the registry, one enforced
--      approval, approval link, escalated assets, deadline from the clock.
--   5. Append HITL_REQUESTED.
--   6. Return {hitl_id, approval_url, timeout_at, hitl_requested_ledger_id}.
-- The hitl_queue row guard (0013) re-checks the insert against the run.
CREATE FUNCTION fao_private.create_request(p_correlation_id uuid, p_rollup jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_run       public.run_invocations%ROWTYPE;
  v_agent     public.agent_registry%ROWTYPE;
  v_base      text;
  v_channel   text;
  v_id        bigint;
  v_url       text;
  v_timeout   timestamptz;
  v_sub_tier  public.policy_sub_tier;
  v_rationale text;
  v_escalated jsonb;
  v_ledger_id bigint;
BEGIN
  IF p_rollup IS NULL
     OR (p_rollup->>'chain_ok')::boolean IS NOT TRUE
     OR (p_rollup->>'hitl_required')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAO-GOV-004 create_request: the rollup does not require review'
      USING ERRCODE = '22023';
  END IF;

  -- 1
  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.correlation_id = p_correlation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAO-GOV-004 create_request: no run record for %', p_correlation_id
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_agent
    FROM public.agent_registry ar
   WHERE ar.agent_id = v_run.agent_id;
  IF NOT FOUND
     OR v_agent.status <> 'ACTIVE'::public.agent_status
     OR v_agent.sla_max_hitl_resolution_hrs IS NULL THEN
    RAISE EXCEPTION 'FAO-GOV-004 create_request: agent % cannot open a request', v_run.agent_id
      USING ERRCODE = '42501';
  END IF;

  -- 2
  v_base := rtrim((SELECT s.value FROM public.fao_settings s WHERE s.key = 'approval_app_base_url'), '/');
  IF v_base IS NULL OR v_base = '' THEN
    RAISE EXCEPTION 'FAO-GOV-007 create_request: approval_app_base_url is not set'
      USING ERRCODE = '22023';
  END IF;
  v_channel := (SELECT s.value FROM public.fao_settings s WHERE s.key = 'slack_channel_id');

  -- 3
  v_id      := nextval(pg_catalog.pg_get_serial_sequence('public.hitl_queue', 'hitl_id'));
  v_url     := v_base || '/?hitl_id=' || v_id::text;
  v_timeout := fao_private.clock() + make_interval(hours => v_agent.sla_max_hitl_resolution_hrs);

  v_sub_tier  := coalesce(p_rollup->>'review_sub_tier', 'STANDARD')::public.policy_sub_tier;
  v_rationale := fao_private.compose_rationale(p_rollup, 'HITL_REQUEST');
  v_escalated := coalesce(p_rollup->'escalated_assets', '[]'::jsonb);

  -- 4
  INSERT INTO public.hitl_queue (
    hitl_id, correlation_id, agent_id, agent_invoker_id, risk_tier, sub_tier,
    policy_rationale, timeout_at, configured_approvals, enforced_approvals,
    approval_url, escalated_assets
  )
  VALUES (
    v_id, v_run.correlation_id, v_run.agent_id, v_run.invoker_id, v_run.risk_tier, v_sub_tier,
    v_rationale, v_timeout, v_agent.approval_threshold, 1,
    v_url, v_escalated
  );

  -- 5
  v_ledger_id := fao_private.append_event(
    v_run.correlation_id,
    'HITL_REQUESTED',
    jsonb_build_object(
      'hitl_id',              v_id,
      'agent_invoker_id',     v_run.invoker_id,
      'timeout_at',           v_timeout,
      'sub_tier',             v_sub_tier,
      'configured_approvals', v_agent.approval_threshold,
      'enforced_approvals',   1,
      'approval_url',         v_url,
      'notification_channel', 'slack',
      'slack_channel_id',     v_channel,
      'escalated_assets',     v_escalated,
      'per_asset_summary',    coalesce(p_rollup->'per_asset_summary', '[]'::jsonb)),
    'REQUIRE_HUMAN'::public.policy_outcome,
    v_sub_tier,
    v_rationale,
    NULL,
    'PENDING'::public.hitl_status,
    NULL,
    'SUCCESS'::public.execution_status,
    NULL);

  -- 6
  RETURN jsonb_build_object(
    'hitl_id',                  v_id,
    'approval_url',             v_url,
    'timeout_at',               v_timeout,
    'hitl_requested_ledger_id', v_ledger_id);
END;
$$;

COMMENT ON FUNCTION fao_private.create_request(uuid, jsonb) IS
  'FAO-GOV-004, FAO-GOV-007: opens the HITL request for a run that needs review (frozen approval counts, review sub-tier, approval link from settings plus the id only, deadline from the agent SLA) and appends HITL_REQUESTED in the same transaction.';

-- ----------------------------------------------------------------------------
-- Revoke every function in this file from every client role. No client role
-- is ever granted any of them (0017).
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION fao_private.run_context(uuid)               FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.append_event(uuid, text, jsonb, public.policy_outcome, public.policy_sub_tier, text, text[], public.hitl_status, uuid, public.execution_status, text, bigint)
                                                                   FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.run_rollup(uuid)                FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.compose_rationale(jsonb, text)  FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.create_request(uuid, jsonb)     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
