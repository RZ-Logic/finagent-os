-- ============================================================================
-- FinAgent OS pgTAP 150: IC-18, every client RPC takes one json body
-- Controls: FAO-GOV-008 (client RPC bodies are decoded and checked inside the
-- database by fao_private.client_args; nothing reaches a field rule that the
-- body rules refuse), FAO-GOV-001 (a refused body is journaled with
-- attempted.invalid_body and never with the raw body), FAO-GOV-004 (a
-- \u0000 escape cannot carry a decision, and an anonymous caller is still
-- NO_SESSION). Closes KNOWN-LIMITS U8 together with test/api/body.test.mjs.
-- A json literal keeps a \u0000 escape as written (the json type does not
-- decode it), so each body below reaches the function as PostgREST passes it.
-- ============================================================================
BEGIN;
SELECT plan(51);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.ca(p_body json, p_required text[], p_optional jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
  LANGUAGE sql AS $$ SELECT fao_private.client_args(p_body, p_required, p_optional) $$;
-- request.headers set as PostgREST sets it, for one call of client_args
CREATE FUNCTION pg_temp.ca_hdr(p_headers text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM set_config('request.headers', p_headers, true);
  r := fao_private.client_args('{"a": "1"}'::json, ARRAY['a']);
  PERFORM set_config('request.headers', '', true);
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.reason(p_res jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT (p_res->>'ok') || '/' || coalesce(p_res->'note'->>'invalid_body', '<none>') $$;
-- code/http_status/invalid_body of a stored RPC result and its journal row
CREATE FUNCTION pg_temp.r(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT (pg_temp.g(p_k)->>'code') || '/' || (pg_temp.g(p_k)->>'http_status') || '/'
         || coalesce(tests.journal_row((pg_temp.g(p_k)->>'ref')::bigint)->'attempted'->>'invalid_body', '<none>') $$;
CREATE FUNCTION pg_temp.state() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'runs', (SELECT count(*) FROM public.run_invocations),
    'ledger', (SELECT count(*) FROM public.shadow_ledger),
    'audit', (SELECT count(*) FROM public.fao_admin_audit),
    'roles', (SELECT count(*) FROM public.fao_user_roles WHERE revoked_at IS NULL),
    'decided', (SELECT count(*) FROM public.hitl_queue WHERE decision <> 'PENDING'),
    'agent', (SELECT to_jsonb(a) FROM public.agent_registry a WHERE agent_id = 'fao_reserve_recon_v1'),
    'btc', (SELECT to_jsonb(t) FROM public.materiality_thresholds t WHERE asset_symbol = 'BTC' AND scope = 'Spot'),
    'aisha_active', (SELECT active FROM public.process_owners WHERE id = tests.uid('aisha.okonkwo@finagent-os.demo'))) $$;

-- 1 to 3. The validator itself: pinned, never granted to a client role
SELECT is((SELECT p.provolatile::text || '/' || p.prosecdef::text FROM pg_proc p
           WHERE p.oid = to_regprocedure('fao_private.client_args(json, text[], jsonb)')),
  's/true', 'client_args(json, text[], jsonb) exists, STABLE and SECURITY DEFINER');
SELECT is_empty(
  $$SELECT r FROM unnest(ARRAY['anon', 'authenticated', 'service_role', 'fao_workflow']) r
    WHERE has_function_privilege(r, 'fao_private.client_args(json, text[], jsonb)', 'EXECUTE')$$,
  'no client role may execute client_args');
SELECT throws_ok($$SELECT tests.do_as('sarah.chen@finagent-os.demo', 'SELECT fao_private.client_args(''{}''::json, ARRAY[]::text[])')$$,
  '42501', NULL, 'a signed-in caller cannot call client_args directly');

-- 4 to 22. Each reason of BUILD-CORE 2.9, in order, called as the owner
INSERT INTO v VALUES ('ca_form', pg_temp.ca_hdr('{"content-type": "application/x-www-form-urlencoded"}'));
INSERT INTO v VALUES ('ca_text', pg_temp.ca_hdr('{"content-type": "text/plain"}'));
INSERT INTO v VALUES ('ca_unreadable', pg_temp.ca_hdr('not json'));
INSERT INTO v VALUES ('ca_json_ct', pg_temp.ca_hdr('{"content-type": "Application/JSON; charset=utf-8"}'));
SELECT is(pg_temp.reason(pg_temp.g('ca_form')), 'false/media_type', 'client_args: a form Content-Type is media_type');
SELECT is(pg_temp.reason(pg_temp.g('ca_text')), 'false/media_type', 'client_args: text/plain is media_type');
SELECT is(pg_temp.reason(pg_temp.g('ca_unreadable')), 'false/media_type', 'client_args: unreadable request headers fail closed as media_type');
SELECT is(pg_temp.reason(pg_temp.g('ca_json_ct')), 'true/<none>', 'client_args: application/json in any case, with a charset, passes');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": "x\u0000y"}', ARRAY['a'])), 'false/undecodable', 'client_args: a \u0000 escape in a value is undecodable');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": "1", "b\u0000": "2"}', ARRAY['a'])), 'false/undecodable', 'client_args: a \u0000 escape in a key is undecodable');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": {"n": "\u0000"}}', ARRAY['a'])), 'false/undecodable', 'client_args: a \u0000 escape nested in an object is undecodable');
SELECT is(pg_temp.reason(pg_temp.ca(NULL, ARRAY['a'])), 'false/not_object', 'client_args: SQL NULL is not_object');
SELECT is(pg_temp.reason(pg_temp.ca('[{"a": "1"}]', ARRAY['a'])), 'false/not_object', 'client_args: an array body is not_object');
SELECT is(pg_temp.reason(pg_temp.ca('"a"', ARRAY['a'])), 'false/not_object', 'client_args: a string body is not_object');
SELECT is(pg_temp.reason(pg_temp.ca('7', ARRAY['a'])), 'false/not_object', 'client_args: a number body is not_object');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": "1", "a": "2"}', ARRAY['a'])), 'false/duplicate_key', 'client_args: a repeated key is duplicate_key');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": "1", "A": "2"}', ARRAY['a'])), 'false/unknown_key', 'client_args: an unknown key (case-sensitive) is unknown_key');
SELECT is(pg_temp.reason(pg_temp.ca('{"b": "1"}', ARRAY['a'], '{"b": null}')), 'false/missing_key', 'client_args: a missing required key is missing_key');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": 1}', ARRAY['a'])), 'false/not_string', 'client_args: a JSON number value is not_string');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": false}', ARRAY['a'])), 'false/not_string', 'client_args: a JSON boolean value is not_string');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": {"x": "1"}}', ARRAY['a'])), 'false/not_string', 'client_args: a JSON object value is not_string');
SELECT is(pg_temp.reason(pg_temp.ca('{"a": ["1"]}', ARRAY['a'])), 'false/not_string', 'client_args: a JSON array value is not_string');
SELECT is(pg_temp.ca('{"a": "1"}', ARRAY['a'], '{"b": null, "c": "mcp"}'),
  '{"ok": true, "args": {"a": "1", "b": null, "c": "mcp"}, "note": {}}'::jsonb,
  'client_args: success fills every optional key with its default');

-- 23 to 25. Success details and what a refusal returns
SELECT is(pg_temp.ca('{"a": null, "c": "test"}', ARRAY['a'], '{"c": "mcp"}')->'args',
  '{"a": null, "c": "test"}'::jsonb, 'client_args: a JSON null is kept and a supplied optional key wins over its default');
SELECT is(pg_temp.ca('{"a": "1", "z": "2"}', ARRAY['a'])->'args',
  '{"a": "1", "z": "2"}'::jsonb, 'client_args: a refused object body is returned decoded, without defaults');
SELECT is(pg_temp.ca('{"a": "\u0000"}', ARRAY['a'])->'args', '{}'::jsonb, 'client_args: an undecodable body returns empty args');

-- Data for the RPCs
INSERT INTO v VALUES ('req', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('ledger_id', to_jsonb((SELECT max(ledger_id) FROM public.shadow_ledger)));
INSERT INTO v VALUES ('state_before', pg_temp.state());
INSERT INTO v VALUES ('journal_before', to_jsonb(tests.journal_total()));

-- 26 to 34. A body with a \u0000 escape is INVALID_INPUT for every client RPC
INSERT INTO v VALUES ('n_whoami', tests.rpc_body('sarah.chen@finagent-os.demo', 'fao_whoami', '{"x\u0000": "1"}'));
INSERT INTO v VALUES ('n_start', tests.rpc_body('aisha.okonkwo@finagent-os.demo', 'fao_run_start',
  format('{"p_agent_id": "fao_reserve_recon_v1", "p_reason": "r\u0000", "p_idempotency_key": "%s"}', tests.new_key())::json));
INSERT INTO v VALUES ('n_get', tests.rpc_body('sarah.chen@finagent-os.demo', 'fao_hitl_get',
  format('{"p_hitl_id": "%s\u0000"}', pg_temp.g('req')::text)::json));
INSERT INTO v VALUES ('n_decide', tests.rpc_body('sarah.chen@finagent-os.demo', 'fao_hitl_decide',
  format('{"p_hitl_id": "%s", "p_decision": "APPROVED", "p_notes": "ok\u0000"}', pg_temp.g('req')::text)::json));
INSERT INTO v VALUES ('n_correct', tests.rpc_body('marcus.patel@finagent-os.demo', 'fao_ledger_correct',
  format('{"p_ledger_id": "%s", "p_reason": "pgtap 150\u0000"}', pg_temp.g('ledger_id')::text)::json));
INSERT INTO v VALUES ('n_threshold', tests.rpc_body('marcus.patel@finagent-os.demo', 'fao_admin_set_threshold',
  '{"p_asset_symbol": "BTC", "p_scope": "Spot", "p_asset_class": "Major", "p_materiality_usd": "700000", "p_ratio_floor": "1",
    "p_ratio_band_lower": "1.05", "p_ratio_band_upper": "1.3", "p_notes": null, "p_reason": "pgtap 150\u0000"}'));
INSERT INTO v VALUES ('n_agent', tests.rpc_body('marcus.patel@finagent-os.demo', 'fao_admin_set_agent',
  '{"p_agent_id": "fao_reserve_recon_v1", "p_status": null, "p_ai_advisory_enabled": null, "p_max_runs_per_hour": "8", "p_reason": "pgtap 150\u0000"}'));
INSERT INTO v VALUES ('n_role', tests.rpc_body('marcus.patel@finagent-os.demo', 'fao_admin_set_role',
  format('{"p_user_id": "%s", "p_role": "reader", "p_agent_id": null, "p_grant": "true", "p_reason": "pgtap 150\u0000"}',
         tests.uid('aisha.okonkwo@finagent-os.demo'))::json));
INSERT INTO v VALUES ('n_owner', tests.rpc_body('marcus.patel@finagent-os.demo', 'fao_admin_set_owner_active',
  format('{"p_user_id": "%s", "p_active": "false", "p_reason": "pgtap 150\u0000"}', tests.uid('aisha.okonkwo@finagent-os.demo'))::json));
INSERT INTO v VALUES ('journal_after', to_jsonb(tests.journal_total()));
INSERT INTO v VALUES ('state_after', pg_temp.state());

SELECT is(pg_temp.r('n_whoami'), 'INVALID_INPUT/400/undecodable', 'fao_whoami: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_start'), 'INVALID_INPUT/400/undecodable', 'fao_run_start: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_get'), 'INVALID_INPUT/400/undecodable', 'fao_hitl_get: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_decide'), 'INVALID_INPUT/400/undecodable', 'fao_hitl_decide: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_correct'), 'INVALID_INPUT/400/undecodable', 'fao_ledger_correct: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_threshold'), 'INVALID_INPUT/400/undecodable', 'fao_admin_set_threshold: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_agent'), 'INVALID_INPUT/400/undecodable', 'fao_admin_set_agent: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_role'), 'INVALID_INPUT/400/undecodable', 'fao_admin_set_role: a \u0000 escape is INVALID_INPUT, journaled as undecodable');
SELECT is(pg_temp.r('n_owner'), 'INVALID_INPUT/400/undecodable', 'fao_admin_set_owner_active: a \u0000 escape is INVALID_INPUT, journaled as undecodable');

-- 35 to 40. One journal row each, against the right entry point, without the
-- raw body, and nothing changed
SELECT is((pg_temp.g('journal_after')::text)::bigint - (pg_temp.g('journal_before')::text)::bigint, 9::bigint,
  'nine refused bodies add exactly nine journal rows');
SELECT is((SELECT count(DISTINCT j->>'ref') FROM v WHERE k LIKE 'n\_%' AND j->>'ref' IS NOT NULL), 9::bigint,
  'each refused body returns its own journal reference');
SELECT results_eq(
  $$SELECT tests.journal_row((j->>'ref')::bigint)->>'entry_point' FROM v WHERE k LIKE 'n\_%' ORDER BY 1$$,
  $$VALUES ('rpc:fao_admin_set_agent'), ('rpc:fao_admin_set_owner_active'), ('rpc:fao_admin_set_role'), ('rpc:fao_admin_set_threshold'),
           ('rpc:fao_hitl_decide'), ('rpc:fao_hitl_get'), ('rpc:fao_ledger_correct'), ('rpc:fao_run_start'), ('rpc:fao_whoami')$$,
  'each refusal is journaled against its own RPC');
SELECT is_empty(
  $$SELECT k FROM v WHERE k LIKE 'n\_%'
      AND (tests.journal_row((j->>'ref')::bigint)->>'attempted' LIKE '%u0000%'
           OR tests.journal_row((j->>'ref')::bigint)->>'attempted' LIKE '%pgtap 150%')$$,
  'no journal row holds the raw body or any value from it');
SELECT is((tests.journal_row((pg_temp.g('n_decide')->>'ref')::bigint)->>'actor_uid')::uuid, tests.uid('sarah.chen@finagent-os.demo'),
  'the refused decide is journaled against the caller from the session');
SELECT is(pg_temp.g('state_after'), pg_temp.g('state_before'), 'the refused bodies changed no run, ledger, audit, role, request, agent, threshold or owner');

-- 41 to 46. Anonymous callers with such a body are still NO_SESSION, journaled
INSERT INTO v VALUES ('anon_before', to_jsonb(tests.journal_total()));
INSERT INTO v VALUES ('a_start', tests.rpc_body('anon', 'fao_run_start',
  format('{"p_agent_id": "fao_reserve_recon_v1", "p_reason": "r\u0000", "p_idempotency_key": "%s"}', tests.new_key())::json));
INSERT INTO v VALUES ('a_decide', tests.rpc_body('anon', 'fao_hitl_decide',
  format('{"p_hitl_id": "%s", "p_decision": "APPROVED", "p_notes": "ok\u0000"}', pg_temp.g('req')::text)::json));
INSERT INTO v VALUES ('anon_after', to_jsonb(tests.journal_total()));
SELECT is(pg_temp.g('a_start')->>'code' || '/' || (pg_temp.g('a_start')->>'http_status'), 'NO_SESSION/401', 'anon fao_run_start with a \u0000 escape is NO_SESSION');
SELECT is(pg_temp.g('a_decide')->>'code' || '/' || (pg_temp.g('a_decide')->>'http_status'), 'NO_SESSION/401', 'anon fao_hitl_decide with a \u0000 escape is NO_SESSION');
SELECT is((pg_temp.g('anon_after')::text)::bigint - (pg_temp.g('anon_before')::text)::bigint, 2::bigint, 'the two anonymous refusals add two journal rows');
SELECT ok((tests.journal_row((pg_temp.g('a_start')->>'ref')::bigint)->>'actor_uid') IS NULL
          AND tests.journal_row((pg_temp.g('a_start')->>'ref')::bigint)->>'db_role' = 'anon'
          AND tests.journal_row((pg_temp.g('a_start')->>'ref')::bigint)->>'entry_point' = 'rpc:fao_run_start',
  'the anonymous start is journaled with no actor and db role anon');
SELECT ok((tests.journal_row((pg_temp.g('a_decide')->>'ref')::bigint)->>'actor_uid') IS NULL
          AND tests.journal_row((pg_temp.g('a_decide')->>'ref')::bigint)->>'db_role' = 'anon'
          AND tests.journal_row((pg_temp.g('a_decide')->>'ref')::bigint)->>'entry_point' = 'rpc:fao_hitl_decide',
  'the anonymous decide is journaled with no actor and db role anon');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = (pg_temp.g('req')::text)::bigint), 'PENDING',
  'the request is still PENDING');

-- 47 to 51. fao_whoami takes the body {} only; INVALID_INPUT comes after the
-- session check and before the role check
INSERT INTO v VALUES ('w_ok', tests.rpc_body('sarah.chen@finagent-os.demo', 'fao_whoami', '{}'));
INSERT INTO v VALUES ('w_key', tests.rpc_body('sarah.chen@finagent-os.demo', 'fao_whoami', '{"x": "1"}'));
INSERT INTO v VALUES ('w_outsider', tests.rpc_body('outsider@local.test', 'fao_whoami', '{"x": "1"}'));
INSERT INTO v VALUES ('w_outsider_ok', tests.rpc_body('outsider@local.test', 'fao_whoami', '{}'));
INSERT INTO v VALUES ('w_array', tests.rpc_body('sarah.chen@finagent-os.demo', 'fao_whoami', '[]'));
SELECT is(pg_temp.g('w_ok')->>'ok', 'true', 'fao_whoami with {} answers a member');
SELECT is(pg_temp.r('w_key'), 'INVALID_INPUT/400/unknown_key', 'fao_whoami with any key is INVALID_INPUT (unknown_key)');
SELECT is(pg_temp.r('w_outsider'), 'INVALID_INPUT/400/unknown_key', 'fao_whoami checks the body before the role (Outsider with a key is INVALID_INPUT)');
SELECT is(pg_temp.g('w_outsider_ok')->>'code', 'NOT_AUTHORISED', 'fao_whoami with {} still refuses a caller with no role');
SELECT is(pg_temp.r('w_array'), 'INVALID_INPUT/400/not_object', 'fao_whoami with an array body is INVALID_INPUT (not_object)');

SELECT * FROM finish();
ROLLBACK;
