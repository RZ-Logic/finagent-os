-- ============================================================================
-- FinAgent OS pgTAP 148: patch round 6, sweep expiry record, run
-- summary view, stablecoin band and seed SLA
-- Controls:
--   FAO-GOV-004, FAO-GOV-001 (P3): an expired request never yields a row
--     that reads as a commit of the batch. The sweep writes HITL_EXPIRED as
--     the expiry record (inputs run_state EXPIRED, committed false; status
--     FAILURE, hitl_status EXPIRED; rationale says the batch was not
--     committed) and no COMMITTED row, also when the run's invoker has been
--     deactivated (red team r5 item 3). An incomplete audit chain still
--     gets COMMIT_BLOCKED.
--   FAO-GOV-015, FAO-GOV-008 (P3): fao_run_summary never counts an expired
--     request as committed, including a COMMITTED row with hitl_status
--     EXPIRED written before the patch (stood in for by
--     fao_private.append_event as the owner; nothing is disabled).
--   FAO-REC-002 (P9, IC-38): seeded USDC and USDT ratio_band_upper is
--     1.0500 (owner decision 2026-11-07), floor and lower band 1.0000; the
--     cutover step (fao_admin_set_threshold with a change reason) moves a
--     table holding 1.0050 to 1.0500.
--   FAO-GOV-008 (P4, seed side): seeded sla_max_execution_seconds is at
--     least 900 for every agent that sets it.
-- Flagship fao_reserve_recon_v1: owner Sarah, Sarah's escalation_to Marcus,
-- invokers Aisha and Sarah. Requests last 24 hours; clock 0, then 90000.
-- ============================================================================
BEGIN;
SELECT plan(24);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS bigint LANGUAGE sql AS $$ SELECT (j#>>'{}')::bigint FROM v WHERE k = p_k $$;
CREATE FUNCTION pg_temp.rc(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT tests.request_corr(pg_temp.id(p_k)) $$;
CREATE FUNCTION pg_temp.active(p_email text, p_active boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM tests.as_owner();
  PERFORM set_config('fao.change_reason', 'pgtap 148 owner active ' || p_active::text, true);
  UPDATE public.process_owners SET active = p_active WHERE email = p_email;
END $$;
CREATE FUNCTION pg_temp.rec(p_id bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT tests.jsonb_as('fao_workflow', format($q$SELECT public.fao_notification_record(%s::bigint, 'REQUESTED', 0, 'SENT', 'slack', '1730900000.0148', NULL)$q$, p_id)) $$;
CREATE FUNCTION pg_temp.expired_row(p_k text) RETURNS public.shadow_ledger LANGUAGE sql AS $$
  SELECT * FROM public.shadow_ledger WHERE correlation_id = pg_temp.rc(p_k) AND inputs->>'event_type' = 'HITL_EXPIRED' ORDER BY ledger_id DESC LIMIT 1 $$;
-- The run summary view's commit columns: committed_count/outcome/status.
CREATE FUNCTION pg_temp.view_commit(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT s.run_state || '/' || s.hitl_decision || '/' || s.committed_count || '/'
         || coalesce(s.latest_committed_outcome, '<null>') || '/' || coalesce(s.latest_committed_status, '<null>')
    FROM public.fao_run_summary s WHERE s.correlation_id = pg_temp.rc(p_k) $$;
CREATE FUNCTION pg_temp.thr(p_sym text) RETURNS text LANGUAGE sql AS $$
  SELECT ratio_floor::text || '/' || ratio_band_lower::text || '/' || ratio_band_upper::text
    FROM public.materiality_thresholds WHERE asset_symbol = p_sym AND scope = 'Spot' $$;

SELECT tests.set_clock(0);

-- ============================================================================
-- P9: stablecoin band (seed 0006)
-- ============================================================================
SELECT is(pg_temp.thr('USDC') || ' ' || pg_temp.thr('USDT'), '1.0000/1.0000/1.0500 1.0000/1.0000/1.0500',
  'P9: USDC and USDT floor 1.0000, band 1.0000 to 1.0500');
SELECT is((SELECT count(*) FROM public.materiality_thresholds
            WHERE asset_symbol IN ('USDC', 'USDT') AND scope = 'Spot' AND notes LIKE '%held near 105%'),
  2::bigint, 'P9: the stablecoin notes say the band follows the owner decision (reserves held near 105%)');
SELECT is((SELECT string_agg(asset_symbol || '=' || pg_temp.thr(asset_symbol), ' ' ORDER BY asset_symbol)
             FROM public.materiality_thresholds WHERE scope = 'Spot' AND asset_symbol NOT IN ('USDC', 'USDT')),
  'ADA=1.0000/1.0000/1.1000 BTC=1.0000/1.0500/1.2500 ETH=1.0000/1.0000/1.1000 SOL=1.0000/1.0000/1.1500 XRP=1.0000/1.0000/1.1000',
  'P9: the other assets keep their seeded bands');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.materiality_thresholds WHERE ratio_band_upper = 1.0050),
  'P9: no seeded threshold holds the old 1.0050 band');

-- The cutover step on a table that still holds the v1 value: the owner's
-- audited direct edit sets 1.0050 back (as the live seed has it), then the
-- admin RPC applies 1.0500 with a change reason, as the runbook does.
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 148 v1 band stand-in', true);
  UPDATE public.materiality_thresholds SET ratio_band_upper = 1.0050 WHERE asset_symbol = 'USDC' AND scope = 'Spot';
END $$;
INSERT INTO v VALUES ('cut', tests.jsonb_as('marcus.patel@finagent-os.demo', $q$SELECT public.fao_admin_set_threshold(json_build_object(
  'p_asset_symbol', 'USDC', 'p_scope', 'Spot', 'p_asset_class', 'Stablecoin', 'p_materiality_usd', '10000',
  'p_ratio_floor', '1.0000', 'p_ratio_band_lower', '1.0000', 'p_ratio_band_upper', '1.0500',
  'p_notes', 'Stablecoin. Upper band 1.05 per the owner decision (2026-11-07) that stablecoin reserves are held near 105%.',
  'p_reason', 'IC-38 cutover: stablecoin band 1.0050 to 1.0500 (owner decision 2026-11-07)'))$q$));
SELECT is(pg_temp.g('cut')->>'ok' || '/' || pg_temp.thr('USDC'), 'true/1.0000/1.0000/1.0500',
  'P9: fao_admin_set_threshold moves a 1.0050 band to 1.0500');
SELECT is((SELECT count(*) FROM public.fao_admin_audit WHERE table_name = 'public.materiality_thresholds' AND reason LIKE '%IC-38 cutover%'),
  1::bigint, 'P9: the cutover change is audited with its reason');

-- ============================================================================
-- P4 (seed side): seeded stale-run limits
-- ============================================================================
SELECT is((SELECT count(*) FROM public.agent_registry WHERE sla_max_execution_seconds < 900), 0::bigint,
  'P4: no seeded agent sets sla_max_execution_seconds below 900');
SELECT is((SELECT sla_max_execution_seconds FROM public.agent_registry WHERE agent_id = 'fao_reserve_recon_v1'), 900,
  'P4: the flagship stale-run limit is 900 seconds');

-- ============================================================================
-- P2: flagship control ids (seed 0003)
-- ============================================================================
SELECT ok((SELECT sox_control_ids @> ARRAY['FAO-GOV-006', 'FAO-GOV-007'] FROM public.agent_registry WHERE agent_id = 'fao_reserve_recon_v1'),
  'P2: the flagship lists FAO-GOV-006 and FAO-GOV-007 (146 asserts the full set)');

-- ============================================================================
-- P3: sweep expiry record and the run summary view
-- ============================================================================
-- xA: plain expiry (invoker Sarah, active). xB: the invoker (Aisha) is
-- deactivated before the deadline. xC: owner-side tampered chain (a stray
-- ASSET_RECONCILED row, as 146 kD), then expiry.
INSERT INTO v VALUES ('xA', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
INSERT INTO v VALUES ('xB', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('xC', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
SELECT pg_temp.rec(pg_temp.id('xA'));
SELECT pg_temp.rec(pg_temp.id('xB'));
SELECT pg_temp.rec(pg_temp.id('xC'));
INSERT INTO public.shadow_ledger (correlation_id, execution_id, agent_id, risk_tier, inputs, policy_outcome, policy_rationale, status)
SELECT r.correlation_id, r.execution_id, r.agent_id, r.risk_tier, jsonb_build_object('event_type', 'ASSET_RECONCILED', 'asset', 'USDC', 'ratio', 1.0),
       'ALLOW', 'pgtap 148 stray row (owner-side tampered chain, as 146)', 'SUCCESS'
  FROM public.run_invocations r WHERE r.correlation_id = pg_temp.rc('xC');
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', false);

SELECT tests.set_clock(90000);
INSERT INTO v VALUES ('s1', tests.sweep());

SELECT is((SELECT count(*) FROM jsonb_array_elements(pg_temp.g('s1')->'expired_requests') e
            WHERE (e->>'hitl_id')::bigint IN (pg_temp.id('xA'), pg_temp.id('xB'), pg_temp.id('xC'))),
  3::bigint, 'P3 setup: the sweep expires all three requests');
SELECT is(tests.run_state(pg_temp.rc('xA')) || '/' || tests.run_state(pg_temp.rc('xB')) || '/' || tests.run_state(pg_temp.rc('xC')),
  'EXPIRED/EXPIRED/EXPIRED', 'P3: each run is EXPIRED');
SELECT is(tests.ledger_count(pg_temp.rc('xA'), 'COMMITTED') + tests.ledger_count(pg_temp.rc('xB'), 'COMMITTED') + tests.ledger_count(pg_temp.rc('xC'), 'COMMITTED'),
  0::bigint, 'P3: no expired request yields a COMMITTED row (deactivated invoker and broken chain included)');
SELECT is((SELECT (r.inputs->>'run_state') || '/' || (r.inputs->>'committed') || '/' || r.status::text || '/' || r.hitl_status::text FROM pg_temp.expired_row('xA') r),
  'EXPIRED/false/FAILURE/EXPIRED', 'P3: HITL_EXPIRED is the expiry record: run_state EXPIRED, committed false, FAILURE, EXPIRED');
SELECT is((SELECT r.policy_rationale FROM pg_temp.expired_row('xA') r),
  format('FAO-GOV-004 hitl_id %s expired without a decision (sweep); run closed EXPIRED, batch not committed', pg_temp.id('xA')),
  'P3: the expiry record''s reason says expiry and that the batch was not committed');
SELECT is((SELECT count(*) FROM public.shadow_ledger
            WHERE correlation_id = pg_temp.rc('xA') AND inputs->>'event_type' = 'HITL_EXPIRED'), 1::bigint,
  'P3: one HITL_EXPIRED row per expired request');
SELECT is((SELECT (r.inputs->>'committed') || '/' || r.status::text FROM pg_temp.expired_row('xB') r), 'false/FAILURE',
  'P3: the deactivated invoker''s expired run also closes with committed false and nothing committed');
SELECT is(tests.ledger_count(pg_temp.rc('xC'), 'COMMIT_BLOCKED')::text || '/' ||
          (SELECT hitl_status::text || '/' || status::text FROM public.shadow_ledger
            WHERE correlation_id = pg_temp.rc('xC') AND inputs->>'event_type' = 'COMMIT_BLOCKED'),
  '1/EXPIRED/FAILURE', 'P3: an incomplete chain on expiry still records one COMMIT_BLOCKED');

SELECT is(pg_temp.view_commit('xA'), 'EXPIRED/EXPIRED/0/<null>/<null>', 'P3: the view counts no commit for an expired request');
SELECT is(pg_temp.view_commit('xB'), 'EXPIRED/EXPIRED/0/<null>/<null>', 'P3: the view counts no commit for the deactivated invoker''s expired request');
SELECT is(pg_temp.view_commit('xC'), 'EXPIRED/EXPIRED/0/<null>/<null>', 'P3: the view counts no commit for an expired request with a broken chain');
SELECT is((SELECT commit_blocked FROM public.fao_run_summary WHERE correlation_id = pg_temp.rc('xC')), true,
  'P3: the view still reports the chain block');

-- A COMMITTED row with hitl_status EXPIRED, the form the sweep wrote before
-- this patch, written by the database's own insert point as the owner;
-- nothing is disabled. The view must not count it.
INSERT INTO v VALUES ('legacy', to_jsonb(fao_private.append_event(
  pg_temp.rc('xA'), 'COMMITTED', jsonb_build_object('hitl_id', pg_temp.id('xA'), 'decision', 'EXPIRED', 'note', 'pgtap 148 pre-patch form'),
  'REQUIRE_HUMAN'::public.policy_outcome, 'STANDARD'::public.policy_sub_tier, 'pgtap 148 pre-patch expiry COMMITTED row', NULL,
  'EXPIRED'::public.hitl_status, NULL, 'FAILURE'::public.execution_status, NULL)));
SELECT ok(pg_temp.id('legacy') IS NOT NULL, 'P3 setup: a pre-patch expiry COMMITTED row exists');
SELECT is(pg_temp.view_commit('xA'), 'EXPIRED/EXPIRED/0/<null>/<null>', 'P3: the view does not count a pre-patch expiry COMMITTED row as committed');

-- A real approval still counts (the filter is only hitl_status EXPIRED).
SELECT tests.set_clock(0);
INSERT INTO v VALUES ('xD', to_jsonb(tests.make_request('sarah.chen@finagent-os.demo')));
INSERT INTO v VALUES ('dD', tests.decide('marcus.patel@finagent-os.demo', pg_temp.id('xD'), 'APPROVED'));
SELECT is(pg_temp.view_commit('xD'), 'COMMITTED/APPROVED/1/REQUIRE_HUMAN/SUCCESS', 'P3: an approved request still reads as one commit');
SELECT pg_temp.active('aisha.okonkwo@finagent-os.demo', true);

SELECT * FROM finish();
ROLLBACK;
