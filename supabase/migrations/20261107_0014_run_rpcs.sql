-- ============================================================================
-- FinAgent OS: Migration 0014: run RPCs
-- ============================================================================
-- The functions that start, claim, record, finish and fail a run.
--
-- Client RPCs (PostgREST; one unnamed json body each, IC-18, decoded by
-- fao_private.client_args; body keys are the argument names of spec 2.7):
--   fao_whoami(json)     the caller's identity and honoured roles (body {})
--   fao_run_start(json)  records the invoker from the session, checks the
--                        registry, role, idempotency key and rate limit, and
--                        returns a single-use run token (stored only as a
--                        hash)
--                        (patch round 6, P5: EXPIRED replay refusals count
--                        toward the rate limit, fao_private.run_start_count;
--                        P7: inputs keys NFKC-folded, no whitespace or
--                        control characters)
-- Workflow RPCs (n8n over the fao_workflow connection, typed parameters):
--   fao_run_claim()            consumes the run token; the run starts
--   fao_ledger_append_batch()  Writer events, all or none
--   fao_run_finalize()         rollup, then COMMITTED, or the HITL request
--                              and HITL_REQUESTED, in one transaction
--   fao_run_fail()             records a failure from the error workflow
--                              (FAILED on the run, or a workflow_failures row)
--
-- Control IDs implemented:
--   FAO-GOV-001  ledger rows only through the database (DB-set timestamps and
--                context, all-or-none batches, forbidden keys refused);
--                refusals journaled in the same transaction
--   FAO-GOV-002  registry status gate (RUN_REFUSED committed with the refusal)
--   FAO-GOV-003  per-agent run rate limit
--   FAO-GOV-004  identity only from auth.uid(); never from an argument
--   FAO-GOV-008  run records, idempotency, single-use hashed run tokens, run
--                state machine, correlation threading
--   FAO-REC-001  one rollup (fao_private.run_rollup) decides commit or review
--
-- Validation pattern for client RPCs: decode the body with client_args first
-- (it never raises), then the session check, then the body result with every
-- input check (fixed message), then authorization. Expected refusals never raise:
-- they journal, set the HTTP status and return ok:false with the fixed
-- message for the code. No database error text reaches a caller.
--
-- Every function: SECURITY DEFINER, VOLATILE, SET search_path = '', fully
-- qualified names; revoked from every client role here; 0017 grants the
-- allow-list.
--
-- Rollback: see phase2-5/rollback/rollback_core.sql.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fao_whoami (FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- The signed-in caller, their owner row (when any) and the role grants that
-- has_role honours. The aal value is read from the session claims and is
-- informational only. The body must be {} (IC-18): any key, or a body that
-- client_args refuses, is INVALID_INPUT, checked after the session and before
-- the role check.
CREATE FUNCTION public.fao_whoami(json)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_in    jsonb := fao_private.client_args($1, ARRAY[]::text[], '{}'::jsonb);
  v_uid   uuid;
  v_owner public.process_owners%ROWTYPE;
  v_aal   text;
  v_roles jsonb;
BEGIN
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse('rpc:fao_whoami', NULL, NULL, v_in->'note', 'NO_SESSION');
  END IF;

  IF (v_in->>'ok')::boolean IS NOT TRUE THEN
    RETURN fao_private.refuse('rpc:fao_whoami', NULL, NULL, v_in->'note', 'INVALID_INPUT');
  END IF;

  IF NOT fao_private.has_any_role(v_uid) THEN
    RETURN fao_private.refuse('rpc:fao_whoami', 'fao_user_roles', v_uid::text, '{}'::jsonb, 'NOT_AUTHORISED');
  END IF;

  SELECT * INTO v_owner FROM public.process_owners po WHERE po.id = v_uid;

  BEGIN
    v_aal := auth.jwt()->>'aal';
  EXCEPTION WHEN others THEN
    v_aal := NULL;
  END;

  SELECT coalesce(jsonb_agg(jsonb_build_object('role', r.role::text, 'agent_id', r.agent_id)
                            ORDER BY r.role::text, r.agent_id NULLS FIRST), '[]'::jsonb)
    INTO v_roles
    FROM public.fao_user_roles r
   WHERE r.user_id = v_uid
     AND r.revoked_at IS NULL
     AND fao_private.has_role(v_uid, r.role, r.agent_id);

  RETURN fao_private.ok_result(jsonb_build_object(
    'user_id',  v_uid,
    'is_owner', v_owner.id IS NOT NULL,
    'name',     v_owner.name,
    'email',    v_owner.email,
    'active',   v_owner.active,
    'aal',      v_aal,
    'roles',    v_roles));
END;
$$;

COMMENT ON FUNCTION public.fao_whoami(json) IS
  'FAO-GOV-004, FAO-GOV-008: the signed-in caller (from auth.uid() only), their owner row and the role grants has_role honours. One json body, {} (IC-18). Refuses NO_SESSION, INVALID_INPUT (any key, or a body client_args refuses) and NOT_AUTHORISED (no role).';

-- ----------------------------------------------------------------------------
-- fao_run_start (FAO-GOV-008, FAO-GOV-002, FAO-GOV-003, FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- Patch round 6 (P5): the count the fao_run_start rate limit compares with
-- max_runs_per_hour: this invoker's runs of the agent requested in the last
-- hour plus this invoker's EXPIRED replay refusals for the agent journaled
-- in the last hour. A refusal the journal flood cap dropped is not counted;
-- it also wrote nothing.
-- Patch round 7 (L4): one clock. requested_at (now()) and the journal at
-- (clock_timestamp()) are stored in real time, so the hour is measured in
-- real time too: both are compared with now() - 1 hour, never with
-- fao_private.clock(). The test clock moves deadlines only (token expiry,
-- timeout_at, the stale-run SLA); moving it neither empties nor frees the
-- rate limit window.
CREATE FUNCTION fao_private.run_start_count(p_uid uuid, p_agent_id text, p_entry_point text)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT (SELECT count(*)
            FROM public.run_invocations ri
           WHERE ri.invoker_id = p_uid
             AND ri.agent_id = p_agent_id
             AND ri.requested_at > now() - interval '1 hour')::int
       + (SELECT count(*)
            FROM public.fao_refusal_journal j
           WHERE j.actor_uid = p_uid
             AND j.entry_point = p_entry_point
             AND j.code = 'EXPIRED'
             AND j.target_key = left(p_agent_id, 64)
             AND j.at > now() - interval '1 hour')::int
$$;

COMMENT ON FUNCTION fao_private.run_start_count(uuid, text, text) IS
  'FAO-GOV-003 (patch round 6, P5; patch round 7, L4): runs of the agent this invoker requested in the last hour plus this invoker''s EXPIRED replay refusals for the agent journaled in the last hour, both measured in real time (now(), the clock the stored timestamps use; the test clock does not move the window). fao_run_start refuses RATE_LIMITED at max_runs_per_hour. Never granted to a client role.';

-- ----------------------------------------------------------------------------
-- Body (IC-18): required p_agent_id, p_reason, p_idempotency_key; optional
-- p_invoked_via (default "mcp"); every value a JSON string or null. In order,
-- after client_args:
--   1. session (anonymous callers are refused NO_SESSION)
--   2. the body result and the inputs (INVALID_INPUT)
--   3. active owner row (NOT_AN_OWNER)
--   4. per-invoker advisory lock (serializes the idempotency and rate checks)
--   5. agent exists (UNKNOWN_AGENT); invoker role for it (NOT_AUTHORISED)
--   6. idempotency replay (fix round 2 R04: a REQUESTED run whose agent is
--      no longer ACTIVE expires, gets no new token and the call goes on to
--      the step 7 gate; round 5 K5: a run that is EXPIRED, or expires now
--      because its token expired, is refused EXPIRED (410) with its
--      correlation id and no token)
--   7. agent ACTIVE, else a committed RUN_REFUSED row and AGENT_NOT_ACTIVE
--      (RATE_LIMITED with no ledger row once the invoker has
--      max_runs_per_hour RUN_REFUSED rows for the agent in the last hour)
--   8. rate limit (RATE_LIMITED)
--   9. new run and single-use token (only its SHA-256 hash is stored)
-- Patch round 6 (P5): the rate limit counts run starts and EXPIRED replay
-- refusals together. Each replay of an expired key that is refused EXPIRED
-- writes one journal row (entry point rpc:fao_run_start, code EXPIRED, actor
-- the invoker, target the agent); those rows count toward max_runs_per_hour
-- like run starts, and a replay over the limit is refused RATE_LIMITED
-- (step 6 and step 8 use the same count).
CREATE FUNCTION public.fao_run_start(json)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry    constant text := 'rpc:fao_run_start';
  v_in       jsonb := fao_private.client_args($1,
                        ARRAY['p_agent_id', 'p_reason', 'p_idempotency_key'],
                        '{"p_invoked_via": "mcp"}'::jsonb);
  -- Decoded body fields under the old argument names (IC-18).
  p_agent_id        text := v_in->'args'->>'p_agent_id';
  p_reason          text := v_in->'args'->>'p_reason';
  p_idempotency_key text := v_in->'args'->>'p_idempotency_key';
  p_invoked_via     text := v_in->'args'->>'p_invoked_via';
  v_uid      uuid;
  v_attempt  jsonb;
  v_key      text;
  v_agent    public.agent_registry%ROWTYPE;
  v_run      public.run_invocations%ROWTYPE;
  v_tok      fao_private.run_tokens%ROWTYPE;
  v_token    text;
  v_expires  timestamptz;
  v_corr     uuid;
  v_recent   int;
BEGIN
  v_attempt := jsonb_build_object(
    'agent_id',        left(p_agent_id, 200),
    'reason',          left(p_reason, 200),
    'idempotency_key', left(p_idempotency_key, 200),
    'invoked_via',     left(p_invoked_via, 200)) || (v_in->'note');
  v_key := left(p_agent_id, 64);

  -- 1. Session
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;
  IF v_uid IS NULL THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'NO_SESSION');
  END IF;

  -- 2. Body and inputs
  IF (v_in->>'ok')::boolean IS NOT TRUE
     OR coalesce(p_agent_id ~ '^[a-z0-9_]{1,64}$', false) IS NOT TRUE
     OR NOT fao_private.text_ok(p_reason, 1, 500)
     OR coalesce(p_idempotency_key ~ '^[A-Za-z0-9_-]{8,64}$', false) IS NOT TRUE
     OR coalesce(p_invoked_via IN ('mcp', 'cli', 'test'), false) IS NOT TRUE THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'INVALID_INPUT');
  END IF;

  -- 3. Active owner
  IF NOT fao_private.owner_active(v_uid) THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'NOT_AN_OWNER');
  END IF;

  -- 4. One start at a time per invoker
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('fao_run_start:' || v_uid::text));

  -- 5. Agent and role
  SELECT * INTO v_agent FROM public.agent_registry ar WHERE ar.agent_id = p_agent_id;
  IF NOT FOUND THEN
    RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'UNKNOWN_AGENT');
  END IF;
  IF NOT fao_private.has_role(v_uid, 'invoker'::public.fao_app_role, p_agent_id) THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'NOT_AUTHORISED');
  END IF;

  -- 6. Idempotency replay
  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.invoker_id = v_uid
     AND ri.idempotency_key = p_idempotency_key
     FOR UPDATE;
  IF FOUND THEN
    IF v_run.agent_id <> p_agent_id THEN
      RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'INVALID_INPUT');
    END IF;

    -- Lock order (fix round 2 R06): the run row, then its token row, in
    -- every function that locks both (fao_run_claim does the same).
    IF v_run.state = 'REQUESTED'::public.fao_run_state
       AND v_agent.status <> 'ACTIVE'::public.agent_status THEN
      -- FAO-GOV-002 (fix round 2 R04): no new token for an agent that is no
      -- longer ACTIVE. The run expires; the registry status gate below then
      -- refuses the call (RUN_REFUSED row, AGENT_NOT_ACTIVE).
      UPDATE public.run_invocations
         SET state = 'EXPIRED', finished_at = now(), last_error = 'agent not ACTIVE at replay'
       WHERE correlation_id = v_run.correlation_id;
    ELSIF v_run.state = 'REQUESTED'::public.fao_run_state THEN
      SELECT * INTO v_tok
        FROM fao_private.run_tokens t
       WHERE t.correlation_id = v_run.correlation_id
         FOR UPDATE;

      IF FOUND AND v_tok.consumed_at IS NULL AND v_tok.expires_at > fao_private.clock() THEN
        -- Unclaimed and unexpired: a new token replaces the old one.
        v_token   := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
        v_expires := fao_private.clock() + interval '10 minutes';
        UPDATE fao_private.run_tokens
           SET token_hash = extensions.digest(v_token, 'sha256'),
               expires_at = v_expires,
               issued_at  = now()
         WHERE correlation_id = v_run.correlation_id;
        RETURN fao_private.ok_result(jsonb_build_object(
          'correlation_id',   v_run.correlation_id,
          'run_token',        v_token,
          'token_expires_at', v_expires,
          'state',            'REQUESTED',
          'replayed',         true));
      END IF;

      -- Unclaimed and expired: the run expires; no token is issued. Round 5
      -- (K5): the replay of an expired run is refused EXPIRED (410), naming
      -- the run; the expiry and the journal row commit with the refusal.
      UPDATE public.run_invocations
         SET state = 'EXPIRED', finished_at = now()
       WHERE correlation_id = v_run.correlation_id;
      -- Patch round 6 (P5): the EXPIRED refusal counts toward the rate
      -- limit; over the limit the replay is refused RATE_LIMITED (the run
      -- stays EXPIRED).
      v_recent := fao_private.run_start_count(v_uid, p_agent_id, c_entry);
      IF v_recent >= v_agent.max_runs_per_hour THEN
        RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'RATE_LIMITED');
      END IF;
      RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'EXPIRED')
        || jsonb_build_object(
             'correlation_id',   v_run.correlation_id,
             'run_token',        NULL,
             'token_expires_at', NULL,
             'state',            'EXPIRED',
             'replayed',         true);
    ELSIF v_run.state = 'EXPIRED'::public.fao_run_state THEN
      -- Round 5 (K5): an EXPIRED run is never restarted by its key.
      -- Patch round 6 (P5): the refusal counts toward the rate limit.
      v_recent := fao_private.run_start_count(v_uid, p_agent_id, c_entry);
      IF v_recent >= v_agent.max_runs_per_hour THEN
        RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'RATE_LIMITED');
      END IF;
      RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'EXPIRED')
        || jsonb_build_object(
             'correlation_id',   v_run.correlation_id,
             'run_token',        NULL,
             'token_expires_at', NULL,
             'state',            'EXPIRED',
             'replayed',         true);
    ELSE
      RETURN fao_private.ok_result(jsonb_build_object(
        'correlation_id',   v_run.correlation_id,
        'run_token',        NULL,
        'token_expires_at', NULL,
        'state',            v_run.state::text,
        'replayed',         true));
    END IF;
  END IF;

  -- 7. Registry status gate. The RUN_REFUSED row is inserted directly (there
  --    is no run record for append_event to read) and commits with the
  --    refusal, because nothing here raises.
  --    FAO-GOV-003 also bounds the append-only refusal rows: once this
  --    invoker has max_runs_per_hour RUN_REFUSED rows for the agent in the
  --    last hour, the call is refused RATE_LIMITED and no ledger row is
  --    written (the journal row stays under the journal flood cap). The
  --    per-invoker advisory lock above makes the count exact. Patch round 7
  --    (L4): event_timestamp is stored with now(), so the hour is real time
  --    (now()), the same clock as run_start_count; the test clock does not
  --    move it.
  IF v_agent.status <> 'ACTIVE'::public.agent_status THEN
    SELECT count(*)
      INTO v_recent
      FROM public.shadow_ledger l
     WHERE l.agent_id = v_agent.agent_id
       AND l.inputs ->> 'event_type' = 'RUN_REFUSED'
       AND l.inputs ->> 'invoker_id' = v_uid::text
       AND l.event_timestamp > now() - interval '1 hour';
    IF v_recent >= v_agent.max_runs_per_hour THEN
      RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'RATE_LIMITED');
    END IF;

    INSERT INTO public.shadow_ledger (
      correlation_id, execution_id, agent_id, risk_tier, inputs,
      policy_outcome, policy_sub_tier, policy_rationale, obligations,
      hitl_status, hitl_approver_id, status, error_details
    )
    VALUES (
      gen_random_uuid(), gen_random_uuid(), v_agent.agent_id, v_agent.risk_tier,
      jsonb_build_object(
        'event_type',   'RUN_REFUSED',
        'code',         'AGENT_NOT_ACTIVE',
        'agent_status', v_agent.status::text,
        'invoker_id',   v_uid),
      'DENY', NULL,
      format('FAO-GOV-002 run refused: agent %s status %s', v_agent.agent_id, v_agent.status::text),
      ARRAY[]::text[],
      'NOT_REQUIRED', NULL, 'FAILURE', NULL
    );
    RETURN fao_private.refuse(c_entry, 'agent_registry', v_key, v_attempt, 'AGENT_NOT_ACTIVE');
  END IF;

  -- 8. Rate limit per invoker and agent over the last hour (run starts and
  --    EXPIRED replay refusals, patch round 6 P5)
  v_recent := fao_private.run_start_count(v_uid, p_agent_id, c_entry);
  IF v_recent >= v_agent.max_runs_per_hour THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_key, v_attempt, 'RATE_LIMITED');
  END IF;

  -- 9. New run and its single-use token (43 URL-safe characters; only the
  --    SHA-256 hash is stored)
  v_token   := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  v_expires := fao_private.clock() + interval '10 minutes';

  INSERT INTO public.run_invocations (agent_id, invoker_id, risk_tier, invoked_via, reason, idempotency_key, state)
  VALUES (p_agent_id, v_uid, v_agent.risk_tier, p_invoked_via, p_reason, p_idempotency_key, 'REQUESTED')
  RETURNING correlation_id INTO v_corr;

  INSERT INTO fao_private.run_tokens (correlation_id, token_hash, expires_at)
  VALUES (v_corr, extensions.digest(v_token, 'sha256'), v_expires);

  RETURN fao_private.ok_result(jsonb_build_object(
    'correlation_id',   v_corr,
    'run_token',        v_token,
    'token_expires_at', v_expires,
    'state',            'REQUESTED',
    'replayed',         false));
END;
$$;

COMMENT ON FUNCTION public.fao_run_start(json) IS
  'FAO-GOV-008, FAO-GOV-002, FAO-GOV-003, FAO-GOV-004: starts a run for the signed-in invoker (identity from auth.uid() only). One json body (IC-18): p_agent_id, p_reason, p_idempotency_key, optional p_invoked_via (default mcp). Body and input checks, active owner, invoker role, idempotency replay (no new token once the agent is not ACTIVE; an expired run is refused EXPIRED 410 with its correlation id, round 5 K5, and that refusal counts toward the rate limit, patch round 6 P5), registry status gate with a committed RUN_REFUSED row (RATE_LIMITED with no row once the invoker has max_runs_per_hour of them in the last hour), rate limit (run starts plus EXPIRED replay refusals), then a single-use run token stored only as its hash.';

-- ----------------------------------------------------------------------------
-- fao_run_claim (FAO-GOV-008, FAO-GOV-002, FAO-GOV-004)
-- ----------------------------------------------------------------------------
-- The workflow consumes the run token and the run moves to RUNNING. The token
-- is looked up by its hash, and the hash is kept after consumption, so a
-- replayed token is recognised (409). Every refusal is journaled with the
-- execution id and agent attempted, never the token. In order:
--   1. inputs (INVALID_INPUT)
--   2. the token by hash, unlocked, then the run row FOR UPDATE, then the
--      token row FOR UPDATE with its hash checked again (fix round 2 R06: run
--      row before token row, the same order as the fao_run_start replay, so
--      the two cannot deadlock; a replay that rotated the hash in between
--      leaves INVALID_TOKEN)
--   3. the run's agent equals p_agent_id, the agent the calling workflow
--      serves (fix round 2 R08), else INVALID_TOKEN; nothing changes, so the
--      token stays claimable by its own workflow
--   4. consumed or not REQUESTED (ALREADY_CLAIMED)
--   5. expired (TOKEN_EXPIRED; the run expires)
--   6. the agent is still ACTIVE (fix round 2 R04, FAO-GOV-002), else
--      AGENT_NOT_ACTIVE and the run expires
--   7. the invoker still holds the invoker role for the agent with an active
--      owner row (fix round 2 R03, FAO-GOV-004), else NOT_AUTHORISED and the
--      run expires
--   8. a RUNNING holder of the execution id older than its agent's
--      sla_max_execution_seconds is failed first (round 5, K4)
--   9. RUNNING with the execution id. The id must be unique only among
--      RUNNING runs (fix round 2 R09): n8n numbers executions per instance,
--      so a new n8n database reuses ids that finished runs hold.
CREATE FUNCTION public.fao_run_claim(p_run_token text, p_n8n_execution_id text, p_agent_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_entry   constant text := 'rpc:fao_run_claim';
  v_attempt jsonb;
  v_hash    bytea;
  v_corr    uuid;
  v_tok     fao_private.run_tokens%ROWTYPE;
  v_run     public.run_invocations%ROWTYPE;
  v_status  public.agent_status;
  v_code    text;
  v_name    text;
  v_stale   public.run_invocations%ROWTYPE;
  v_sla     int;
BEGIN
  v_attempt := jsonb_build_object(
    'n8n_execution_id', left(p_n8n_execution_id, 200),
    'agent_id',         left(p_agent_id, 200));

  -- 1. Inputs
  IF coalesce(p_run_token ~ '^[A-Za-z0-9_-]{43}$', false) IS NOT TRUE
     OR coalesce(p_n8n_execution_id ~ '^[A-Za-z0-9_-]{1,64}$', false) IS NOT TRUE
     OR coalesce(p_agent_id ~ '^[a-z0-9_]{1,64}$', false) IS NOT TRUE THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', NULL, v_attempt, 'INVALID_INPUT');
  END IF;

  -- 2. Token, then run row, then token row (one lock order)
  v_hash := extensions.digest(p_run_token, 'sha256');
  SELECT t.correlation_id INTO v_corr
    FROM fao_private.run_tokens t
   WHERE t.token_hash = v_hash;
  IF NOT FOUND THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', NULL, v_attempt, 'INVALID_TOKEN');
  END IF;

  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.correlation_id = v_corr
     FOR UPDATE;

  SELECT * INTO v_tok
    FROM fao_private.run_tokens t
   WHERE t.correlation_id = v_corr
     FOR UPDATE;
  IF NOT FOUND OR v_run.correlation_id IS NULL OR v_tok.token_hash IS DISTINCT FROM v_hash THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', NULL, v_attempt, 'INVALID_TOKEN');
  END IF;

  -- 3. The token belongs to the calling workflow's agent
  IF v_run.agent_id IS DISTINCT FROM p_agent_id THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', NULL, v_attempt, 'INVALID_TOKEN');
  END IF;

  -- 4. Single use
  IF v_tok.consumed_at IS NOT NULL OR v_run.state IS DISTINCT FROM 'REQUESTED'::public.fao_run_state THEN
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_run.correlation_id::text, v_attempt, 'ALREADY_CLAIMED');
  END IF;

  -- 5. Expiry. The run expires and the refusal is journaled; both commit.
  IF v_tok.expires_at <= fao_private.clock() THEN
    UPDATE public.run_invocations
       SET state = 'EXPIRED', finished_at = now()
     WHERE correlation_id = v_run.correlation_id;
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_run.correlation_id::text, v_attempt, 'TOKEN_EXPIRED');
  END IF;

  -- 6 and 7. Authorization is checked again at claim: an agent made inactive,
  -- or an invoker revoked or deactivated, after fao_run_start cannot still
  -- run. The run expires and the refusal is journaled; both commit.
  SELECT ar.status INTO v_status FROM public.agent_registry ar WHERE ar.agent_id = v_run.agent_id;
  IF v_status IS DISTINCT FROM 'ACTIVE'::public.agent_status THEN
    v_code := 'AGENT_NOT_ACTIVE';
  ELSIF NOT fao_private.has_role(v_run.invoker_id, 'invoker'::public.fao_app_role, v_run.agent_id) THEN
    v_code := 'NOT_AUTHORISED';
  END IF;
  IF v_code IS NOT NULL THEN
    UPDATE public.run_invocations
       SET state = 'EXPIRED', finished_at = now(),
           last_error = CASE v_code WHEN 'AGENT_NOT_ACTIVE' THEN 'agent not ACTIVE at claim'
                                    ELSE 'invoker no longer authorised at claim' END
     WHERE correlation_id = v_run.correlation_id;
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_run.correlation_id::text, v_attempt, v_code);
  END IF;

  -- 8. Round 5 (K4): a RUNNING run that still holds this execution id and
  --    was claimed longer ago than its agent's sla_max_execution_seconds
  --    (default 900, the sweep's stale-run rule, BUILD-CORE 3.7) belongs to
  --    a dead or replaced n8n instance. It is failed first (FAILED row in
  --    the sweep's shape, fixed message, run FAILED), then this run claims
  --    the id. A holder inside the window is still refused ALREADY_CLAIMED
  --    by the unique index below (recorded residual, KNOWN-LIMITS U14 (d)).
  SELECT * INTO v_stale
    FROM public.run_invocations ri
   WHERE ri.n8n_execution_id = p_n8n_execution_id
     AND ri.state = 'RUNNING'::public.fao_run_state
     AND ri.correlation_id <> v_run.correlation_id
     FOR UPDATE;
  IF FOUND THEN
    SELECT coalesce(ar.sla_max_execution_seconds, 900) INTO v_sla
      FROM public.agent_registry ar
     WHERE ar.agent_id = v_stale.agent_id;
    IF v_stale.claimed_at + make_interval(secs => coalesce(v_sla, 900)) <= fao_private.clock() THEN
      PERFORM fao_private.append_event(
        v_stale.correlation_id,
        'FAILED',
        jsonb_build_object(
          'failed_node',      'timeout',
          'n8n_execution_id', v_stale.n8n_execution_id,
          'source',           'sweep',
          'stage',            'before_request'),
        'BLOCKED'::public.policy_outcome,
        NULL,
        'FAO-GOV-008 stale run failed at claim: its n8n execution id was reused by a new n8n execution',
        NULL,
        'NOT_REQUIRED'::public.hitl_status,
        NULL,
        'FAILURE'::public.execution_status,
        'stale execution id reused by a new n8n execution');
      UPDATE public.run_invocations
         SET state = 'FAILED', finished_at = now(), last_error = 'stale execution id reused by a new n8n execution'
       WHERE correlation_id = v_stale.correlation_id;
    END IF;
  END IF;

  -- 9. RUNNING. claimed_at is the statement clock (round 5, K1), so two
  --    claims of one id in one transaction still order strictly and
  --    fao_run_fail's "newest holder by claim time" is never a tie.
  BEGIN
    UPDATE public.run_invocations
       SET state = 'RUNNING', claimed_at = clock_timestamp(), n8n_execution_id = p_n8n_execution_id
     WHERE correlation_id = v_run.correlation_id;
  EXCEPTION WHEN unique_violation THEN
    -- The execution id is held by another RUNNING run.
    RETURN fao_private.refuse(c_entry, 'run_invocations', v_run.correlation_id::text, v_attempt, 'ALREADY_CLAIMED');
  END;

  UPDATE fao_private.run_tokens
     SET consumed_at = now()
   WHERE correlation_id = v_run.correlation_id;

  SELECT po.name INTO v_name FROM public.process_owners po WHERE po.id = v_run.invoker_id;

  RETURN fao_private.ok_result(jsonb_build_object(
    'correlation_id', v_run.correlation_id,
    'execution_id',   v_run.execution_id,
    'agent_id',       v_run.agent_id,
    'risk_tier',      v_run.risk_tier::text,
    'invoker_id',     v_run.invoker_id,
    'invoker_name',   v_name,
    'reason',         v_run.reason,
    'invoked_via',    v_run.invoked_via));
END;
$$;

COMMENT ON FUNCTION public.fao_run_claim(text, text, text) IS
  'FAO-GOV-008, FAO-GOV-002, FAO-GOV-004: consumes a single-use run token (looked up by its SHA-256 hash) for the calling workflow''s agent and moves the run to RUNNING with the n8n execution id (unique among RUNNING runs). Locks the run row before the token row. INVALID_INPUT, INVALID_TOKEN (unknown token or another agent''s), ALREADY_CLAIMED, TOKEN_EXPIRED, AGENT_NOT_ACTIVE and NOT_AUTHORISED (invoker revoked or deactivated) are journaled without the token; the last three expire the run. A RUNNING holder of the execution id older than its agent''s sla_max_execution_seconds is failed first (round 5, K4).';

-- ----------------------------------------------------------------------------
-- fao_ledger_append_batch (FAO-GOV-001)
-- ----------------------------------------------------------------------------
-- The Writer's only route into the ledger. All or none: the first invalid
-- item raises and nothing in the batch is stored. Errors name the item by its
-- 0-based index. The Writer may append only STARTED, ASSET_RECONCILED and
-- FAILED. Timestamps, execution id, agent and tier come from the database;
-- supplied values must match the run. STARTED fixes the run asset scope and
-- gets the invoker, channel, reason and execution id from the run record.
-- A Writer FAILED gets source 'writer', stage 'before_request' and the run's
-- n8n execution id from the database. inputs keys the database writes on any
-- event type (identity, approval, request, notification, rollup, failure and
-- refusal facts: c_reserved) are refused, except the keys the database
-- overwrites on a Writer FAILED (source, stage, n8n_execution_id), and
-- failed_node, which a Writer FAILED names itself (fix round 2 R07). Patch
-- round 7 (O3, owner decision 2026-11-08): STARTED inputs carrying
-- invoker_id, invoked_via, reason or n8n_execution_id are refused like
-- every other reserved key (nothing is written); the database still sets
-- those four values on STARTED from the run record. Round 5 (U10): the
-- reserved names are refused at any depth of inputs (arrays included) and
-- in any letter case (patch round 6, P7: compared as
-- normalize(lower(btrim(key)), NFKC), and any key holding whitespace, a
-- control character or one of the listed invisible characters is refused,
-- patch round 7 L1); the FAILED overwrites are allowed only at the top level
-- in their exact spelling, and the one nested exception is STARTED
-- inputs.fixture_provenance.<asset>.source (the flagship's documented
-- fixture provenance). Round 5 (U16 (c)): an inputs.asset on STARTED or a
-- Writer FAILED must be in the run asset scope (for STARTED, its own).
-- ASSET_RECONCILED status must agree with the outcome (fix round 2 R05):
-- PARTIAL and ROLLED_BACK are refused, and ALLOW or ALLOW_WITH_OBLIGATIONS
-- need SUCCESS.
-- AI advisory fields are refused when not null: AI advisory is off for every
-- agent (FAO-GOV-014) and wave 1 records none.
CREATE FUNCTION public.fao_ledger_append_batch(p_events jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  c_uuid      constant text   := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  c_forbidden constant text[] := ARRAY['event_timestamp', 'hitl_approver_id', 'ledger_id', 'corrects_ledger_id'];
  c_allowed   constant text[] := ARRAY[
    'correlation_id', 'event_type', 'inputs', 'policy_outcome', 'policy_sub_tier',
    'policy_rationale', 'obligations', 'status', 'error_details', 'ai_prompt',
    'ai_output', 'ai_confidence', 'fractional_cost_usd', 'hitl_status',
    'execution_id', 'agent_id', 'risk_tier'];
  -- inputs keys reserved to the database (FAO-GOV-001, FAO-GOV-004): every
  -- key the database itself writes into inputs on some event type
  c_reserved  constant text[] := ARRAY[
    'invoker_id', 'invoked_via', 'reason', 'approver_id', 'approvers',
    'agent_invoker_id', 'hitl_id', 'decision', 'decided_at', 'decision_notes',
    'source', 'stage', 'failed_node', 'n8n_execution_id',
    'approval_url', 'timeout_at', 'expired_at', 'sub_tier',
    'configured_approvals', 'enforced_approvals', 'escalated_assets',
    'notification_channel', 'slack_channel_id', 'notification_id', 'kind',
    'level', 'attempt', 'channel', 'external_ref', 'target_owner_id',
    'per_asset_summary', 'counts', 'problems', 'committed_ledger_id',
    'corrects_ledger_id', 'corrected_by', 'code', 'agent_status'];
  -- Patch round 7 (O3): STARTED may carry no reserved key; the database
  -- sets invoker_id, invoked_via, reason and n8n_execution_id itself.
  -- reserved keys a Writer FAILED may carry: the database overwrites the
  -- first three; failed_node is the Writer's own fact on FAILED
  c_failed_set  constant text[] := ARRAY['source', 'stage', 'n8n_execution_id', 'failed_node'];
  v_n         int;
  v_i         int;
  v_item      jsonb;
  v_c         uuid;
  v_corr      uuid;
  v_run       public.run_invocations%ROWTYPE;
  v_started   boolean;
  v_scope     text[];
  v_seen      text[];
  v_failed    boolean := false;
  v_last_err  text;
  v_key       text;
  v_path      text[];
  v_et        text;
  v_inputs    jsonb;
  v_outcome   public.policy_outcome;
  v_sub       public.policy_sub_tier;
  v_status    public.execution_status;
  v_hitl      public.hitl_status;
  v_rank      int;
  v_rationale text;
  v_obl       text[];
  v_err       text;
  v_asset     text;
  v_scope_js  jsonb;
  v_id        bigint;
  v_inserted  jsonb := '[]'::jsonb;
BEGIN
  -- Batch shape
  IF p_events IS NULL OR jsonb_typeof(p_events) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'FAO-GOV-001 ledger_append: events must be a JSON array'
      USING ERRCODE = '22023';
  END IF;
  v_n := jsonb_array_length(p_events);
  IF v_n < 1 OR v_n > 200 THEN
    RAISE EXCEPTION 'FAO-GOV-001 ledger_append: a batch holds 1 to 200 events, got %', v_n
      USING ERRCODE = '22023';
  END IF;

  -- Pass 1: every item is an object with the same valid correlation_id.
  FOR v_i IN 0 .. v_n - 1 LOOP
    v_item := p_events -> v_i;
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: the event is not an object', v_i
        USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_item -> 'correlation_id') IS DISTINCT FROM 'string'
       OR (v_item ->> 'correlation_id') !~ c_uuid THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: correlation_id is not a UUID', v_i
        USING ERRCODE = '22023';
    END IF;
    v_c := (v_item ->> 'correlation_id')::uuid;
    IF v_i = 0 THEN
      v_corr := v_c;
    ELSIF v_c <> v_corr THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: correlation_id differs from item 0', v_i
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- The run must exist and be RUNNING; it stays locked for the batch.
  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.correlation_id = v_corr
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAO-GOV-001 ledger_append: no run record for the batch correlation_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_run.state IS DISTINCT FROM 'RUNNING'::public.fao_run_state THEN
    RAISE EXCEPTION 'FAO-GOV-001 ledger_append: run is not RUNNING (state %)', v_run.state
      USING ERRCODE = '42501';
  END IF;

  v_started := EXISTS (
    SELECT 1 FROM public.shadow_ledger l
     WHERE l.correlation_id = v_corr AND l.inputs ->> 'event_type' = 'STARTED');
  v_scope := v_run.asset_scope;
  SELECT coalesce(array_agg(l.inputs ->> 'asset'), ARRAY[]::text[])
    INTO v_seen
    FROM public.shadow_ledger l
   WHERE l.correlation_id = v_corr AND l.inputs ->> 'event_type' = 'ASSET_RECONCILED';

  -- Pass 2: validate and append, item by item.
  FOR v_i IN 0 .. v_n - 1 LOOP
    v_item  := p_events -> v_i;
    v_asset := NULL;

    -- Keys
    FOR v_key IN SELECT k FROM jsonb_object_keys(v_item) AS k LOOP
      IF v_key = ANY (c_forbidden) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: % must be absent', v_i, v_key
          USING ERRCODE = '22023';
      END IF;
      IF NOT (v_key = ANY (c_allowed)) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: unknown field %', v_i, left(v_key, 64)
          USING ERRCODE = '22023';
      END IF;
    END LOOP;

    IF v_failed THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: no event may follow FAILED in a batch', v_i
        USING ERRCODE = '22023';
    END IF;

    -- Event type
    IF jsonb_typeof(v_item -> 'event_type') IS DISTINCT FROM 'string'
       OR (v_item ->> 'event_type') NOT IN ('STARTED', 'ASSET_RECONCILED', 'FAILED') THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: event_type must be STARTED, ASSET_RECONCILED or FAILED', v_i
        USING ERRCODE = '22023';
    END IF;
    v_et := v_item ->> 'event_type';

    -- Supplied context must equal the run's
    IF coalesce(jsonb_typeof(v_item -> 'execution_id'), 'null') <> 'null' THEN
      IF jsonb_typeof(v_item -> 'execution_id') <> 'string'
         OR (v_item ->> 'execution_id') !~ c_uuid
         OR (v_item ->> 'execution_id')::uuid <> v_run.execution_id THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: execution_id does not match the run', v_i
          USING ERRCODE = '22023';
      END IF;
    END IF;
    IF coalesce(jsonb_typeof(v_item -> 'agent_id'), 'null') <> 'null'
       AND (v_item -> 'agent_id') IS DISTINCT FROM to_jsonb(v_run.agent_id) THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: agent_id does not match the run', v_i
        USING ERRCODE = '22023';
    END IF;
    IF coalesce(jsonb_typeof(v_item -> 'risk_tier'), 'null') <> 'null'
       AND (v_item -> 'risk_tier') IS DISTINCT FROM to_jsonb(v_run.risk_tier::text) THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: risk_tier does not match the run', v_i
        USING ERRCODE = '22023';
    END IF;

    -- inputs
    IF jsonb_typeof(v_item -> 'inputs') IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs must be an object', v_i
        USING ERRCODE = '22023';
    END IF;
    v_inputs := v_item -> 'inputs';
    IF v_inputs ? 'event_type' AND (v_inputs -> 'event_type') IS DISTINCT FROM to_jsonb(v_et) THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.event_type differs from event_type', v_i
        USING ERRCODE = '22023';
    END IF;

    -- Evidence keys only the database writes are refused in Writer inputs,
    -- so a Writer row can never look as if the database set them. On a
    -- Writer FAILED the overwritten keys are instead set from the run
    -- record below (2.10); on STARTED every reserved key is refused (patch
    -- round 7, O3) and the database adds the four run keys below.
    -- Round 5 (U10): every object key at any depth (inside arrays too) is
    -- checked, in any letter case. The FAILED overwrites are allowed only
    -- at the top level and only in their exact spelling. The
    -- one nested exception is the flagship's documented fixture provenance
    -- on STARTED (inputs.fixture_provenance.<asset>.source, fixtures/README).
    FOR v_key, v_path IN
      WITH RECURSIVE walk(v, path) AS (
        SELECT v_inputs, ARRAY[]::text[]
        UNION ALL
        SELECT c.v, w.path || c.k
          FROM walk w
         CROSS JOIN LATERAL (
           SELECT e.key AS k, e.value AS v
             FROM jsonb_each(CASE WHEN jsonb_typeof(w.v) = 'object' THEN w.v END) AS e
           UNION ALL
           SELECT '[' || (a.ord - 1)::text || ']', a.value
             FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w.v) = 'array' THEN w.v END)
                  WITH ORDINALITY AS a(value, ord)
         ) AS c
         WHERE jsonb_typeof(c.v) IN ('object', 'array')
      )
      SELECT k.key, w.path
        FROM walk w
       CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(w.v) = 'object' THEN w.v END) AS k(key)
    LOOP
      -- Patch round 6 (P7), widened in patch round 7 (L1): no inputs key at
      -- any depth may hold whitespace, a control character or one of these
      -- invisible or blank characters: soft hyphen, Hangul fillers (U+115F,
      -- U+1160, U+3164), Mongolian vowel separator and variation selectors
      -- (U+180B to U+180F), zero-width spaces, joiners and marks (U+200B to
      -- U+200F), bidi embeddings and isolates (U+202A to U+202E, U+2066 to
      -- U+2069), word joiner and invisible operators (U+2060 to U+2064),
      -- Braille blank (U+2800), variation selectors (U+FE00 to U+FE0F),
      -- byte order mark, and tag characters (U+E0000 to U+E007F). The
      -- reserved match then folds case and Unicode compatibility forms
      -- (NFKC, so full-width letters match). Letters from other scripts that
      -- look Latin (Cyrillic U+0435 for "e") are not folded: such a key is
      -- kept as an ordinary Writer key and cannot replace a database-set
      -- key (KNOWN-LIMITS U17).
      IF v_key ~ '[[:space:][:cntrl:]\u0085\u00a0\u00ad\u115f\u1160\u1680\u180b-\u180f\u2000-\u200f\u2028-\u202f\u205f-\u2064\u2066-\u2069\u2800\u3000\u3164\ufe00-\ufe0f\ufeff\U000e0000-\U000e007f]' THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: an inputs key at % holds whitespace or a control character', v_i,
          coalesce(nullif(left(regexp_replace(array_to_string(v_path, '.'), '[[:cntrl:]]', ' ', 'g'), 200), ''), 'the top level')
          USING ERRCODE = '22023';
      END IF;
      IF lower(normalize(lower(btrim(v_key)), NFKC)) = ANY (c_reserved)
         AND NOT (cardinality(v_path) = 0 AND v_et = 'FAILED' AND v_key = ANY (c_failed_set))
         AND NOT (v_et = 'STARTED' AND cardinality(v_path) = 2 AND v_path[1] = 'fixture_provenance'
                  AND v_key = 'source') THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.% is set only by the database', v_i,
          left(regexp_replace(array_to_string(v_path || v_key, '.'), '[[:cntrl:]]', ' ', 'g'), 200)
          USING ERRCODE = '22023';
      END IF;
    END LOOP;

    -- Enum fields
    v_outcome := NULL;
    IF jsonb_typeof(v_item -> 'policy_outcome') = 'string' THEN
      BEGIN
        v_outcome := (v_item ->> 'policy_outcome')::public.policy_outcome;
      EXCEPTION WHEN others THEN
        v_outcome := NULL;
      END;
    END IF;
    IF v_outcome IS NULL THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: policy_outcome is not valid', v_i
        USING ERRCODE = '22023';
    END IF;

    v_sub := NULL;
    IF coalesce(jsonb_typeof(v_item -> 'policy_sub_tier'), 'null') <> 'null' THEN
      IF jsonb_typeof(v_item -> 'policy_sub_tier') = 'string' THEN
        BEGIN
          v_sub := (v_item ->> 'policy_sub_tier')::public.policy_sub_tier;
        EXCEPTION WHEN others THEN
          v_sub := NULL;
        END;
      END IF;
      IF v_sub IS NULL THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: policy_sub_tier is not valid', v_i
          USING ERRCODE = '22023';
      END IF;
    END IF;

    v_status := NULL;
    IF jsonb_typeof(v_item -> 'status') = 'string' THEN
      BEGIN
        v_status := (v_item ->> 'status')::public.execution_status;
      EXCEPTION WHEN others THEN
        v_status := NULL;
      END;
    END IF;
    IF v_status IS NULL THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: status is not valid', v_i
        USING ERRCODE = '22023';
    END IF;

    v_rank := CASE v_outcome
                WHEN 'ALLOW'                  THEN 0
                WHEN 'ALLOW_WITH_OBLIGATIONS' THEN 1
                WHEN 'REQUIRE_HUMAN'          THEN 2
                WHEN 'DENY'                   THEN 3
                WHEN 'BLOCKED'                THEN 4
              END;

    v_hitl := 'NOT_REQUIRED';
    IF coalesce(jsonb_typeof(v_item -> 'hitl_status'), 'null') <> 'null' THEN
      v_hitl := NULL;
      IF jsonb_typeof(v_item -> 'hitl_status') = 'string' THEN
        BEGIN
          v_hitl := (v_item ->> 'hitl_status')::public.hitl_status;
        EXCEPTION WHEN others THEN
          v_hitl := NULL;
        END;
      END IF;
      IF v_hitl IS NULL THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: hitl_status is not valid', v_i
          USING ERRCODE = '22023';
      END IF;
    END IF;
    IF NOT (v_hitl = 'NOT_REQUIRED'
            OR (v_hitl = 'PENDING' AND v_et = 'ASSET_RECONCILED' AND v_rank >= 2)) THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: hitl_status must be NOT_REQUIRED, or PENDING on an ASSET_RECONCILED whose outcome needs review', v_i
        USING ERRCODE = '22023';
    END IF;

    -- Text and list fields
    IF jsonb_typeof(v_item -> 'policy_rationale') IS DISTINCT FROM 'string'
       OR length(v_item ->> 'policy_rationale') NOT BETWEEN 1 AND 4000 THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: policy_rationale must be 1 to 4000 characters', v_i
        USING ERRCODE = '22023';
    END IF;
    v_rationale := v_item ->> 'policy_rationale';

    v_obl := ARRAY[]::text[];
    IF coalesce(jsonb_typeof(v_item -> 'obligations'), 'null') <> 'null' THEN
      IF jsonb_typeof(v_item -> 'obligations') <> 'array'
         OR jsonb_array_length(v_item -> 'obligations') > 50
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_item -> 'obligations') o(v)
                     WHERE jsonb_typeof(o.v) <> 'string' OR length(o.v #>> '{}') > 200) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: obligations must be at most 50 strings of at most 200 characters', v_i
          USING ERRCODE = '22023';
      END IF;
      SELECT coalesce(array_agg(o.v ORDER BY o.ord), ARRAY[]::text[])
        INTO v_obl
        FROM jsonb_array_elements_text(v_item -> 'obligations') WITH ORDINALITY AS o(v, ord);
    END IF;

    IF coalesce(jsonb_typeof(v_item -> 'ai_confidence'), 'null') <> 'null'
       AND (jsonb_typeof(v_item -> 'ai_confidence') <> 'number'
            OR (v_item ->> 'ai_confidence')::numeric NOT BETWEEN 0 AND 1) THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: ai_confidence must be a number from 0 to 1', v_i
        USING ERRCODE = '22023';
    END IF;
    IF coalesce(jsonb_typeof(v_item -> 'fractional_cost_usd'), 'null') <> 'null'
       AND jsonb_typeof(v_item -> 'fractional_cost_usd') <> 'number' THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: fractional_cost_usd must be a finite number', v_i
        USING ERRCODE = '22023';
    END IF;
    FOR v_key IN SELECT unnest(ARRAY['ai_prompt', 'ai_output', 'error_details']) LOOP
      IF coalesce(jsonb_typeof(v_item -> v_key), 'null') <> 'null'
         AND (jsonb_typeof(v_item -> v_key) <> 'string' OR length(v_item ->> v_key) > 20000) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: % must be a string of at most 20000 characters', v_i, v_key
          USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF coalesce(jsonb_typeof(v_item -> 'ai_prompt'), 'null') <> 'null'
       OR coalesce(jsonb_typeof(v_item -> 'ai_output'), 'null') <> 'null'
       OR coalesce(jsonb_typeof(v_item -> 'ai_confidence'), 'null') <> 'null'
       OR coalesce(jsonb_typeof(v_item -> 'fractional_cost_usd'), 'null') <> 'null' THEN
      RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: AI advisory fields are not recorded (FAO-GOV-014, AI advisory is off)', v_i
        USING ERRCODE = '22023';
    END IF;
    v_err := CASE WHEN jsonb_typeof(v_item -> 'error_details') = 'string' THEN v_item ->> 'error_details' END;

    -- Per event type
    IF v_et = 'STARTED' THEN
      IF v_started THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: the run already has a STARTED event', v_i
          USING ERRCODE = '22023';
      END IF;
      IF v_outcome <> 'ALLOW' OR v_status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: STARTED must be ALLOW and SUCCESS', v_i
          USING ERRCODE = '22023';
      END IF;
      v_scope_js := v_inputs -> 'asset_scope';
      IF jsonb_typeof(v_scope_js) IS DISTINCT FROM 'array'
         OR jsonb_array_length(v_scope_js) NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.asset_scope must list 1 to 50 assets', v_i
          USING ERRCODE = '22023';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_scope_js) s(v)
                  WHERE jsonb_typeof(s.v) <> 'string' OR (s.v #>> '{}') !~ '^[A-Z0-9]{1,12}$') THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.asset_scope holds an invalid asset symbol', v_i
          USING ERRCODE = '22023';
      END IF;
      IF (SELECT count(DISTINCT s.v) FROM jsonb_array_elements_text(v_scope_js) s(v)) <> jsonb_array_length(v_scope_js) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.asset_scope repeats an asset', v_i
          USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_inputs -> 'asset_count') IS DISTINCT FROM 'number'
         OR (v_inputs ->> 'asset_count')::numeric <> jsonb_array_length(v_scope_js) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.asset_count must equal the asset_scope length', v_i
          USING ERRCODE = '22023';
      END IF;

      SELECT array_agg(s.v ORDER BY s.ord)
        INTO v_scope
        FROM jsonb_array_elements_text(v_scope_js) WITH ORDINALITY AS s(v, ord);

      -- Round 5 (U16 (c)): an asset named on STARTED is one of its own scope.
      IF v_inputs ? 'asset'
         AND (jsonb_typeof(v_inputs -> 'asset') IS DISTINCT FROM 'string'
              OR ((v_inputs ->> 'asset') = ANY (v_scope)) IS NOT TRUE) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.asset is not in the run asset scope', v_i
          USING ERRCODE = '22023';
      END IF;

      -- The database, not the workflow, names who started the run and how
      -- (the Writer may not send these keys at all, patch round 7 O3).
      v_inputs := v_inputs || jsonb_build_object(
        'invoker_id',       v_run.invoker_id,
        'invoked_via',      v_run.invoked_via,
        'reason',           v_run.reason,
        'n8n_execution_id', v_run.n8n_execution_id);

      UPDATE public.run_invocations
         SET asset_scope = v_scope
       WHERE correlation_id = v_corr;
      v_started := true;

    ELSIF v_et = 'ASSET_RECONCILED' THEN
      IF NOT v_started THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: ASSET_RECONCILED needs the run STARTED event first', v_i
          USING ERRCODE = '22023';
      END IF;
      IF jsonb_typeof(v_inputs -> 'asset') IS DISTINCT FROM 'string'
         OR ((v_inputs ->> 'asset') = ANY (coalesce(v_scope, ARRAY[]::text[]))) IS NOT TRUE THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.asset is not in the run asset scope', v_i
          USING ERRCODE = '22023';
      END IF;
      v_asset := v_inputs ->> 'asset';
      IF v_asset = ANY (v_seen) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: asset % is already recorded for the run', v_i, v_asset
          USING ERRCODE = '22023';
      END IF;
      IF v_outcome IN ('ALLOW', 'ALLOW_WITH_OBLIGATIONS')
         AND jsonb_typeof(v_inputs -> 'ratio') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: ALLOW and ALLOW_WITH_OBLIGATIONS need a numeric inputs.ratio', v_i
          USING ERRCODE = '22023';
      END IF;
      -- Status and outcome agree (fix round 2 R05): an asset row never says
      -- its own reconciliation failed while the rollup counts it as clean.
      IF v_status IN ('PARTIAL', 'ROLLED_BACK') THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: ASSET_RECONCILED status must be SUCCESS or FAILURE', v_i
          USING ERRCODE = '22023';
      END IF;
      IF v_outcome IN ('ALLOW', 'ALLOW_WITH_OBLIGATIONS') AND v_status <> 'SUCCESS' THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: ALLOW and ALLOW_WITH_OBLIGATIONS need status SUCCESS', v_i
          USING ERRCODE = '22023';
      END IF;
      v_seen := v_seen || v_asset;

    ELSE
      -- FAILED
      IF v_status <> 'FAILURE' THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: FAILED must have status FAILURE', v_i
          USING ERRCODE = '22023';
      END IF;
      -- Round 5 (U16 (c)): an asset named on a Writer FAILED is in the run
      -- scope that STARTED fixed (none before STARTED).
      IF v_inputs ? 'asset'
         AND (jsonb_typeof(v_inputs -> 'asset') IS DISTINCT FROM 'string'
              OR ((v_inputs ->> 'asset') = ANY (coalesce(v_scope, ARRAY[]::text[]))) IS NOT TRUE) THEN
        RAISE EXCEPTION 'FAO-GOV-001 ledger_append: item %: inputs.asset is not in the run asset scope', v_i
          USING ERRCODE = '22023';
      END IF;
      -- The database, not the workflow, names where a Writer failure came
      -- from: the run is RUNNING, so no request exists yet (before_request),
      -- and the execution id is the one that claimed the run.
      v_inputs := v_inputs || jsonb_build_object(
        'source',           'writer',
        'stage',            'before_request',
        'n8n_execution_id', v_run.n8n_execution_id);
      v_failed   := true;
      v_last_err := v_err;
    END IF;

    v_id := fao_private.append_event(
      v_corr, v_et, v_inputs, v_outcome, v_sub, v_rationale, v_obl,
      v_hitl, NULL, v_status, v_err);

    v_inserted := v_inserted || jsonb_build_array(jsonb_build_object(
      'ledger_id',  v_id,
      'event_type', v_et,
      'asset',      v_asset));
  END LOOP;

  -- A FAILED event ends the run.
  IF v_failed THEN
    UPDATE public.run_invocations
       SET state = 'FAILED',
           finished_at = now(),
           last_error = left(coalesce(v_last_err, 'FAILED event from the Writer'), 500)
     WHERE correlation_id = v_corr;
  END IF;

  RETURN fao_private.ok_result(jsonb_build_object(
    'count',    v_n,
    'inserted', v_inserted));
END;
$$;

COMMENT ON FUNCTION public.fao_ledger_append_batch(jsonb) IS
  'FAO-GOV-001: the Writer route into the Shadow Ledger. All or none; STARTED, ASSET_RECONCILED and FAILED only; database-set timestamps and context (Writer FAILED source, stage and execution id included); forbidden keys and every inputs key the database writes on any event type refused at any depth and in any letter case (except the top-level Writer FAILED overwrites and STARTED fixture_provenance.<asset>.source, round 5 U10; STARTED may carry no invoker_id, invoked_via, reason or n8n_execution_id, the database sets them, patch round 7 O3); an inputs.asset on STARTED or FAILED must be in the run asset scope (round 5 U16 (c)); asset scope fixed by STARTED; one ASSET_RECONCILED per asset in scope, status SUCCESS or FAILURE and SUCCESS for ALLOW and ALLOW_WITH_OBLIGATIONS. Raises FAO-GOV-001 ledger_append: item <i>: <reason>.';

-- ----------------------------------------------------------------------------
-- fao_run_finalize (FAO-REC-001, FAO-GOV-004, FAO-GOV-001)
-- ----------------------------------------------------------------------------
-- One transaction. The run must be RUNNING (else raise). Fix round 2 R04: the
-- registry status gate holds at commit too, on both the COMMITTED and the
-- review branch; the agent row is read FOR SHARE, so a concurrent status
-- change waits for this finalize or is seen by it. The one rollup decides:
--   agent not ACTIVE -> (fix round 3, FAO-GOV-002, the same shape as
--                       fao_hitl_decide) COMMIT_BLOCKED with inputs.code
--                       AGENT_NOT_ACTIVE, the agent status and the rollup
--                       problems, run FAILED, no request; the refusal
--                       envelope AGENT_NOT_ACTIVE (409, journaled) with the
--                       finalize fields and state FAILED
--   invoker no longer an active owner with the invoker grant (round 5,
--                       K2, FAO-GOV-004; checked after the agent gate) ->
--                       COMMIT_BLOCKED with inputs.code and inputs.reason
--                       INVOKER_NOT_ACTIVE, run FAILED, no request; the
--                       refusal envelope INVOKER_NOT_ACTIVE (409, journaled)
--                       with the finalize fields and state FAILED
--   chain not intact -> COMMIT_BLOCKED, run FAILED, AUDIT_CHAIN_MISMATCH
--                       (ok:true, nothing committed)
--   review needed    -> request plus HITL_REQUESTED (create_request), run
--                       AWAITING_HITL
--   otherwise        -> COMMITTED, run COMMITTED
-- Any error rolls back all of it, leaving the run RUNNING.
CREATE FUNCTION public.fao_run_finalize(p_correlation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_run     public.run_invocations%ROWTYPE;
  r         jsonb;
  v_req     jsonb;
  v_ledger  bigint;
  v_obl     text[];
  v_symbols jsonb;
  v_status  public.agent_status;
BEGIN
  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.correlation_id = p_correlation_id
     FOR UPDATE;
  IF NOT FOUND OR v_run.state IS DISTINCT FROM 'RUNNING'::public.fao_run_state THEN
    RAISE EXCEPTION 'FAO-GOV-008 run_finalize: run % is not RUNNING', coalesce(p_correlation_id::text, '<null>')
      USING ERRCODE = '42501';
  END IF;

  -- The share lock orders this finalize against fao_admin_set_agent, which
  -- locks the row FOR UPDATE; a missing row reads as not ACTIVE (fail closed).
  SELECT ar.status INTO v_status
    FROM public.agent_registry ar
   WHERE ar.agent_id = v_run.agent_id
     FOR SHARE;

  r := fao_private.run_rollup(p_correlation_id);

  -- Agent not ACTIVE: never committed and no request, the rollup evidence
  -- kept (fix round 3).
  IF v_status IS DISTINCT FROM 'ACTIVE'::public.agent_status THEN
    PERFORM fao_private.append_event(
      p_correlation_id,
      'COMMIT_BLOCKED',
      jsonb_build_object(
        'hitl_id',      NULL,
        'problems',     r->'problems',
        'code',         'AGENT_NOT_ACTIVE',
        'agent_status', v_status::text),
      'BLOCKED'::public.policy_outcome,
      NULL,
      format('FAO-GOV-002 agent %s status %s at commit; run not committed', v_run.agent_id, coalesce(v_status::text, 'MISSING'))
        || CASE WHEN (r->>'chain_ok')::boolean IS NOT TRUE THEN '; FAO-GOV-001 audit chain incomplete' ELSE '' END,
      NULL,
      'NOT_REQUIRED'::public.hitl_status,
      NULL,
      'FAILURE'::public.execution_status,
      NULL);

    UPDATE public.run_invocations
       SET state = 'FAILED', finished_at = now(), last_error = 'agent not ACTIVE at commit'
     WHERE correlation_id = p_correlation_id;

    RETURN fao_private.refuse('rpc:fao_run_finalize', 'run_invocations', p_correlation_id::text,
                              jsonb_build_object('agent_id', v_run.agent_id), 'AGENT_NOT_ACTIVE')
      || jsonb_build_object(
           'hitl_required',            false,
           'hitl_id',                  NULL,
           'approval_url',             NULL,
           'timeout_at',               NULL,
           'hitl_requested_ledger_id', NULL,
           'rollup_outcome',           NULL,
           'rollup_sub_tier',          NULL,
           'review_sub_tier',          NULL,
           'escalated_assets',         NULL,
           'counts',                   NULL,
           'committed_ledger_id',      NULL,
           'state',                    'FAILED');
  END IF;

  -- Round 5 (K2, FAO-GOV-004): the invoker must still be an active owner
  -- holding the invoker grant for the agent at commit, else the same
  -- pattern as the agent gate (IC-24): COMMIT_BLOCKED with inputs.code and
  -- inputs.reason INVOKER_NOT_ACTIVE, run FAILED, the refusal envelope
  -- INVOKER_NOT_ACTIVE (409, journaled), nothing raised. The owner row and
  -- the invoker's grants are read FOR SHARE, so a concurrent deactivation or
  -- revocation waits for this finalize or is seen by it.
  PERFORM 1 FROM public.process_owners po WHERE po.id = v_run.invoker_id FOR SHARE;
  PERFORM 1 FROM public.fao_user_roles ur WHERE ur.user_id = v_run.invoker_id FOR SHARE;
  IF NOT fao_private.has_role(v_run.invoker_id, 'invoker'::public.fao_app_role, v_run.agent_id) THEN
    PERFORM fao_private.append_event(
      p_correlation_id,
      'COMMIT_BLOCKED',
      jsonb_build_object(
        'hitl_id',  NULL,
        'problems', r->'problems',
        'code',     'INVOKER_NOT_ACTIVE',
        'reason',   'INVOKER_NOT_ACTIVE'),
      'BLOCKED'::public.policy_outcome,
      NULL,
      format('FAO-GOV-004 invoker no longer authorised for agent %s at commit; run not committed', v_run.agent_id)
        || CASE WHEN (r->>'chain_ok')::boolean IS NOT TRUE THEN '; FAO-GOV-001 audit chain incomplete' ELSE '' END,
      NULL,
      'NOT_REQUIRED'::public.hitl_status,
      NULL,
      'FAILURE'::public.execution_status,
      NULL);

    UPDATE public.run_invocations
       SET state = 'FAILED', finished_at = now(), last_error = 'invoker no longer authorised at commit'
     WHERE correlation_id = p_correlation_id;

    RETURN fao_private.refuse('rpc:fao_run_finalize', 'run_invocations', p_correlation_id::text,
                              jsonb_build_object('agent_id', v_run.agent_id), 'INVOKER_NOT_ACTIVE')
      || jsonb_build_object(
           'hitl_required',            false,
           'hitl_id',                  NULL,
           'approval_url',             NULL,
           'timeout_at',               NULL,
           'hitl_requested_ledger_id', NULL,
           'rollup_outcome',           NULL,
           'rollup_sub_tier',          NULL,
           'review_sub_tier',          NULL,
           'escalated_assets',         NULL,
           'counts',                   NULL,
           'committed_ledger_id',      NULL,
           'state',                    'FAILED');
  END IF;

  -- Audit chain incomplete: never committed.
  IF (r->>'chain_ok')::boolean IS NOT TRUE THEN
    v_ledger := fao_private.append_event(
      p_correlation_id,
      'COMMIT_BLOCKED',
      jsonb_build_object('hitl_id', NULL, 'problems', r->'problems'),
      'BLOCKED'::public.policy_outcome,
      NULL,
      'FAO-GOV-001 audit chain incomplete; run not committed',
      NULL,
      'NOT_REQUIRED'::public.hitl_status,
      NULL,
      'FAILURE'::public.execution_status,
      NULL);

    UPDATE public.run_invocations
       SET state = 'FAILED', finished_at = now(), last_error = 'audit chain incomplete'
     WHERE correlation_id = p_correlation_id;

    RETURN fao_private.ok_result(jsonb_build_object(
      'hitl_required',            false,
      'hitl_id',                  NULL,
      'approval_url',             NULL,
      'timeout_at',               NULL,
      'hitl_requested_ledger_id', NULL,
      'rollup_outcome',           NULL,
      'rollup_sub_tier',          NULL,
      'review_sub_tier',          NULL,
      'escalated_assets',         NULL,
      'counts',                   NULL,
      'committed_ledger_id',      NULL,
      'state',                    'FAILED'), 'AUDIT_CHAIN_MISMATCH');
  END IF;

  -- Review needed: the request and HITL_REQUESTED, then AWAITING_HITL.
  IF (r->>'hitl_required')::boolean THEN
    v_req := fao_private.create_request(p_correlation_id, r);

    UPDATE public.run_invocations
       SET state = 'AWAITING_HITL'
     WHERE correlation_id = p_correlation_id;

    RETURN fao_private.ok_result(jsonb_build_object(
      'hitl_required',            true,
      'hitl_id',                  v_req->'hitl_id',
      'approval_url',             v_req->'approval_url',
      'timeout_at',               v_req->'timeout_at',
      'hitl_requested_ledger_id', v_req->'hitl_requested_ledger_id',
      'rollup_outcome',           r->'rollup_outcome',
      'rollup_sub_tier',          r->'rollup_sub_tier',
      'review_sub_tier',          r->'review_sub_tier',
      'escalated_assets',         r->'escalated_assets',
      'counts',                   r->'counts',
      'committed_ledger_id',      NULL,
      'state',                    'AWAITING_HITL'));
  END IF;

  -- No review needed: COMMITTED.
  SELECT coalesce(array_agg(o.v ORDER BY o.ord), ARRAY[]::text[])
    INTO v_obl
    FROM jsonb_array_elements_text(coalesce(r->'obligations', '[]'::jsonb)) WITH ORDINALITY AS o(v, ord);
  SELECT coalesce(jsonb_agg(e.value->'asset' ORDER BY e.ord), '[]'::jsonb)
    INTO v_symbols
    FROM jsonb_array_elements(coalesce(r->'escalated_assets', '[]'::jsonb)) WITH ORDINALITY AS e(value, ord);

  v_ledger := fao_private.append_event(
    p_correlation_id,
    'COMMITTED',
    jsonb_build_object(
      'per_asset_summary', r->'per_asset_summary',
      'counts',            r->'counts',
      'escalated_assets',  v_symbols,
      'hitl_id',           NULL,
      'decision',          NULL),
    (r->>'rollup_outcome')::public.policy_outcome,
    (r->>'rollup_sub_tier')::public.policy_sub_tier,
    fao_private.compose_rationale(r, 'COMMITTED'),
    v_obl,
    'NOT_REQUIRED'::public.hitl_status,
    NULL,
    'SUCCESS'::public.execution_status,
    NULL);

  UPDATE public.run_invocations
     SET state = 'COMMITTED', finished_at = now()
   WHERE correlation_id = p_correlation_id;

  RETURN fao_private.ok_result(jsonb_build_object(
    'hitl_required',            false,
    'hitl_id',                  NULL,
    'approval_url',             NULL,
    'timeout_at',               NULL,
    'hitl_requested_ledger_id', NULL,
    'rollup_outcome',           r->'rollup_outcome',
    'rollup_sub_tier',          r->'rollup_sub_tier',
    'review_sub_tier',          r->'review_sub_tier',
    'escalated_assets',         r->'escalated_assets',
    'counts',                   r->'counts',
    'committed_ledger_id',      v_ledger,
    'state',                    'COMMITTED'));
END;
$$;

COMMENT ON FUNCTION public.fao_run_finalize(uuid) IS
  'FAO-REC-001, FAO-GOV-004, FAO-GOV-001, FAO-GOV-002: finishes a RUNNING run (else raises) in one transaction from the one rollup: COMMIT_BLOCKED and FAILED (AGENT_NOT_ACTIVE envelope, inputs.code AGENT_NOT_ACTIVE) when the agent is not ACTIVE; COMMIT_BLOCKED and FAILED (INVOKER_NOT_ACTIVE envelope, inputs.code and inputs.reason INVOKER_NOT_ACTIVE) when the invoker is no longer an active owner holding the invoker grant (round 5, K2); COMMITTED; or the HITL request, HITL_REQUESTED and AWAITING_HITL; or COMMIT_BLOCKED and FAILED (AUDIT_CHAIN_MISMATCH) when the audit chain is incomplete.';

-- ----------------------------------------------------------------------------
-- fao_run_fail (FAO-GOV-008)
-- ----------------------------------------------------------------------------
-- Called by the error workflow with the n8n execution id, the failed node,
-- the message and the source the error handler mapped from the failed
-- workflow's id (round 5, K1): 'flagship', 'flagship_pre_claim' (a flagship
-- failure upstream of Claim Run), 'gateway' or 'sweeper'. Any other source,
-- or NULL, raises 22023 and writes nothing. Every other call writes exactly
-- one durable record in this transaction: the FAILED ledger row on the run
-- it attaches to (outcome ATTACHED), or one row in public.workflow_failures
-- with the outcome:
--   PRE_CLAIM          every 'flagship_pre_claim' call (no run lookup: the
--                      execution never claimed a run, so an older run that
--                      holds a reused id is never touched)
--   NOT_FLAGSHIP       every 'gateway' or 'sweeper' call (they hold no run)
--   UNKNOWN_EXECUTION  'flagship' and no run holds the id (ok:false, not
--                      journaled)
--   ALREADY_TERMINAL   'flagship' and the NEWEST run holding the id (by claim
--                      time) is finished; its correlation id is stored. An
--                      older unfinished run with the same id is never used
--                      (n8n ids repeat across instances, fix round 2 R09).
-- ATTACHED ('flagship', the newest holder is unfinished) appends FAILED:
--   RUNNING        stage before_request; the run moves to FAILED
--   AWAITING_HITL  stage after_request; the PENDING request stands and the
--                  run state is unchanged (the sweep handles the request)
-- failed_node and message are stored with control characters replaced, cut
-- to 200 and 500 characters, in the ledger row and in workflow_failures
-- alike. Envelope keys in every form: ok, code, http_status, message, ref,
-- correlation_id, ledger_id, state, outcome.
CREATE FUNCTION public.fao_run_fail(p_n8n_execution_id text, p_failed_node text, p_message text, p_source text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_run    public.run_invocations%ROWTYPE;
  v_exec   text;
  v_node   text;
  v_error  text;
  v_stage  text;
  v_ledger bigint;
  v_out    text;
BEGIN
  IF p_source IS NULL OR p_source NOT IN ('flagship', 'flagship_pre_claim', 'gateway', 'sweeper') THEN
    RAISE EXCEPTION 'FAO-GOV-008 run_fail: p_source must be flagship, flagship_pre_claim, gateway or sweeper'
      USING ERRCODE = '22023';
  END IF;

  v_exec  := left(regexp_replace(p_n8n_execution_id, '[[:cntrl:]]', ' ', 'g'), 200);
  v_node  := coalesce(nullif(left(regexp_replace(coalesce(p_failed_node, ''), '[[:cntrl:]]', ' ', 'g'), 200), ''), 'unknown');
  v_error := left(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g'), 500);

  -- Failures that hold no run: recorded, never attached.
  IF p_source <> 'flagship' THEN
    v_out := CASE WHEN p_source = 'flagship_pre_claim' THEN 'PRE_CLAIM' ELSE 'NOT_FLAGSHIP' END;
    INSERT INTO public.workflow_failures (source, n8n_execution_id, failed_node, message, outcome, correlation_id)
    VALUES (p_source, v_exec, v_node, v_error, v_out, NULL);
    RETURN fao_private.ok_result(jsonb_build_object(
      'correlation_id', NULL,
      'ledger_id',      NULL,
      'state',          NULL,
      'outcome',        v_out));
  END IF;

  -- The newest run holding the id, by claim time, locked.
  SELECT * INTO v_run
    FROM public.run_invocations ri
   WHERE ri.n8n_execution_id = p_n8n_execution_id
   ORDER BY ri.claimed_at DESC NULLS LAST, ri.correlation_id
   LIMIT 1
     FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.workflow_failures (source, n8n_execution_id, failed_node, message, outcome, correlation_id)
    VALUES (p_source, v_exec, v_node, v_error, 'UNKNOWN_EXECUTION', NULL);
    RETURN fao_private.refuse('rpc:fao_run_fail', 'run_invocations', left(p_n8n_execution_id, 64),
                              jsonb_build_object('n8n_execution_id', left(p_n8n_execution_id, 200)),
                              'UNKNOWN_EXECUTION', p_journal => false)
      || jsonb_build_object(
           'correlation_id', NULL,
           'ledger_id',      NULL,
           'state',          NULL,
           'outcome',        'UNKNOWN_EXECUTION');
  END IF;

  IF v_run.state NOT IN ('RUNNING'::public.fao_run_state, 'AWAITING_HITL'::public.fao_run_state) THEN
    INSERT INTO public.workflow_failures (source, n8n_execution_id, failed_node, message, outcome, correlation_id)
    VALUES (p_source, v_exec, v_node, v_error, 'ALREADY_TERMINAL', v_run.correlation_id);
    RETURN fao_private.ok_result(jsonb_build_object(
      'correlation_id', v_run.correlation_id,
      'ledger_id',      NULL,
      'state',          v_run.state::text,
      'outcome',        'ALREADY_TERMINAL'), 'ALREADY_TERMINAL');
  END IF;

  v_stage := CASE WHEN v_run.state = 'AWAITING_HITL'::public.fao_run_state THEN 'after_request' ELSE 'before_request' END;

  v_ledger := fao_private.append_event(
    v_run.correlation_id,
    'FAILED',
    jsonb_build_object(
      'failed_node',      v_node,
      'n8n_execution_id', v_run.n8n_execution_id,
      'source',           'error_workflow',
      'stage',            v_stage),
    'BLOCKED'::public.policy_outcome,
    NULL,
    format('FAO-GOV-008 run failed at %s (%s)', v_node, 'error_workflow'),
    NULL,
    'NOT_REQUIRED'::public.hitl_status,
    NULL,
    'FAILURE'::public.execution_status,
    v_error);

  IF v_run.state = 'RUNNING'::public.fao_run_state THEN
    UPDATE public.run_invocations
       SET state = 'FAILED', finished_at = now(), last_error = v_error
     WHERE correlation_id = v_run.correlation_id;
    v_run.state := 'FAILED';
  END IF;

  RETURN fao_private.ok_result(jsonb_build_object(
    'correlation_id', v_run.correlation_id,
    'ledger_id',      v_ledger,
    'state',          v_run.state::text,
    'outcome',        'ATTACHED'));
END;
$$;

COMMENT ON FUNCTION public.fao_run_fail(text, text, text, text) IS
  'FAO-GOV-008: records a workflow failure (round 5, K1). p_source is flagship, flagship_pre_claim, gateway or sweeper (else 22023, nothing written). flagship attaches a FAILED event (stage before_request or after_request) only when the newest run holding the n8n execution id is unfinished (a RUNNING run moves to FAILED, an AWAITING_HITL run keeps its PENDING request for the sweep); every other call writes one public.workflow_failures row with outcome PRE_CLAIM, NOT_FLAGSHIP, UNKNOWN_EXECUTION or ALREADY_TERMINAL. The envelope adds outcome.';

-- ----------------------------------------------------------------------------
-- Revoke every function in this file from every client role. 0017 grants:
-- fao_whoami(json) to authenticated; fao_run_start(json) to anon and
-- authenticated; the four workflow RPCs to fao_workflow.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fao_whoami(json)                    FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_run_start(json)                 FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_run_claim(text, text, text)     FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_ledger_append_batch(jsonb)      FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_run_finalize(uuid)              FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION public.fao_run_fail(text, text, text, text) FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
REVOKE ALL ON FUNCTION fao_private.run_start_count(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role, fao_workflow;
