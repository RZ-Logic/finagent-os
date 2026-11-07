-- ============================================================================
-- FinAgent OS pgTAP 130: closing requests created before run records existed
-- Controls: FAO-GOV-004 (legacy PENDING requests cannot be decided after the
-- cutover; each is closed as EXPIRED with one HITL_EXPIRED event).
-- Mirrors migration 0013: the row guard does not exist at that point, so the
-- owner disables the user triggers inside this transaction only.
-- ============================================================================
BEGIN;
SELECT plan(8);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
INSERT INTO v VALUES ('current', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('legacy_corr', to_jsonb(gen_random_uuid()));
CREATE FUNCTION pg_temp.lc() RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = 'legacy_corr' $$;

ALTER TABLE public.hitl_queue DISABLE TRIGGER USER;

-- A legacy run: ledger rows and a PENDING request, no run record
INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, inputs, policy_outcome, policy_rationale, status)
VALUES (pg_temp.lc(), gen_random_uuid(), 'fao_reserve_recon_v1', 'RED', '{"event_type": "STARTED"}', 'ALLOW', 'legacy STARTED', 'SUCCESS');
INSERT INTO public.hitl_queue (correlation_id, agent_id, agent_invoker_id, risk_tier, sub_tier, policy_rationale, timeout_at)
VALUES (pg_temp.lc(), 'fao_reserve_recon_v1', tests.uid('aisha.okonkwo@finagent-os.demo'), 'RED', 'CRITICAL', 'legacy request', now() + interval '1 day');
INSERT INTO v VALUES ('legacy_id', to_jsonb((SELECT hitl_id FROM public.hitl_queue WHERE correlation_id = pg_temp.lc())));

INSERT INTO v VALUES ('closed', to_jsonb(fao_private.close_legacy_requests()));

ALTER TABLE public.hitl_queue ENABLE TRIGGER USER;

SELECT is((pg_temp.g('closed')::text)::int, 1, 'close_legacy_requests closes the one legacy PENDING request');
SELECT ok((SELECT decision = 'EXPIRED' AND decided_at IS NOT NULL AND approver_id IS NULL FROM public.hitl_queue WHERE correlation_id = pg_temp.lc()),
  'the legacy request is EXPIRED with no approver');
SELECT is((SELECT decision_notes FROM public.hitl_queue WHERE correlation_id = pg_temp.lc()), 'closed at phase 2-5 cutover', 'the legacy request carries the cutover note');
SELECT is((SELECT count(*) FROM public.shadow_ledger WHERE correlation_id = pg_temp.lc() AND inputs->>'event_type' = 'HITL_EXPIRED' AND inputs->>'source' = 'cutover'), 1::bigint,
  'one HITL_EXPIRED event with source cutover');
SELECT is((SELECT policy_outcome::text || '/' || status::text || '/' || hitl_status::text || '/' || coalesce(policy_sub_tier::text, '-') FROM public.shadow_ledger
           WHERE correlation_id = pg_temp.lc() AND inputs->>'event_type' = 'HITL_EXPIRED'),
  'REQUIRE_HUMAN/FAILURE/EXPIRED/CRITICAL', 'HITL_EXPIRED outcome, status, hitl_status and request sub-tier');
SELECT is((SELECT policy_rationale FROM public.shadow_ledger WHERE correlation_id = pg_temp.lc() AND inputs->>'event_type' = 'HITL_EXPIRED'),
  format('FAO-GOV-004 hitl_id %s expired without a decision (cutover)', pg_temp.g('legacy_id')::text), 'HITL_EXPIRED rationale wording');
SELECT is((SELECT decision::text FROM public.hitl_queue WHERE hitl_id = (pg_temp.g('current')::text)::bigint), 'PENDING', 'a request with a run record is untouched');
SELECT is(tests.ledger_count(tests.request_corr((pg_temp.g('current')::text)::bigint), 'HITL_EXPIRED'), 0::bigint, 'no HITL_EXPIRED for the request with a run record');

SELECT * FROM finish();
ROLLBACK;
