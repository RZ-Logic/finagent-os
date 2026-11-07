-- ============================================================================
-- FinAgent OS pgTAP 080: fao_hitl_decide is all or nothing
-- Controls: FAO-GOV-004 and FAO-GOV-001 (decision, HITL_RESOLVED, rollup and
-- COMMITTED are written in one transaction; a failure leaves no partial row).
-- ============================================================================
BEGIN;
SELECT plan(12);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
INSERT INTO v VALUES ('req', to_jsonb(tests.make_request('aisha.okonkwo@finagent-os.demo')));
INSERT INTO v VALUES ('corr', to_jsonb(tests.request_corr((SELECT (j::text)::bigint FROM v WHERE k = 'req'))));
CREATE FUNCTION pg_temp.corr() RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = 'corr' $$;
CREATE FUNCTION pg_temp.decision() RETURNS text LANGUAGE sql AS $$
  SELECT decision::text FROM public.hitl_queue WHERE hitl_id = (SELECT (j::text)::bigint FROM v WHERE k = 'req') $$;

CREATE FUNCTION tests.pgtap_raise_on_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.inputs->>'event_type' = TG_ARGV[0] THEN
    RAISE EXCEPTION 'pgtap forced failure on %', TG_ARGV[0];
  END IF;
  RETURN NEW;
END $$;

-- Failure on HITL_RESOLVED
CREATE TRIGGER pgtap_fail_resolved BEFORE INSERT ON public.shadow_ledger FOR EACH ROW EXECUTE FUNCTION tests.pgtap_raise_on_event('HITL_RESOLVED');
INSERT INTO v VALUES ('d1', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED'));
DROP TRIGGER pgtap_fail_resolved ON public.shadow_ledger;
SELECT ok(pg_temp.g('d1') ? 'error', 'a failure writing HITL_RESOLVED makes fao_hitl_decide raise');
SELECT is(pg_temp.decision(), 'PENDING', 'after the HITL_RESOLVED failure the request is still PENDING');
SELECT ok(tests.ledger_count(pg_temp.corr(), 'HITL_RESOLVED') = 0 AND tests.ledger_count(pg_temp.corr(), 'COMMITTED') = 0,
  'after the HITL_RESOLVED failure no partial ledger row exists');
SELECT is(tests.run_state(pg_temp.corr()), 'AWAITING_HITL', 'after the HITL_RESOLVED failure the run still awaits a decision');

-- Failure on COMMITTED
CREATE TRIGGER pgtap_fail_committed BEFORE INSERT ON public.shadow_ledger FOR EACH ROW EXECUTE FUNCTION tests.pgtap_raise_on_event('COMMITTED');
INSERT INTO v VALUES ('d2', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED'));
DROP TRIGGER pgtap_fail_committed ON public.shadow_ledger;
SELECT ok(pg_temp.g('d2') ? 'error', 'a failure writing COMMITTED makes fao_hitl_decide raise');
SELECT is(pg_temp.decision(), 'PENDING', 'after the COMMITTED failure the request is still PENDING');
SELECT ok(tests.ledger_count(pg_temp.corr(), 'HITL_RESOLVED') = 0 AND tests.ledger_count(pg_temp.corr(), 'COMMITTED') = 0,
  'after the COMMITTED failure no partial ledger row exists');
SELECT is(tests.run_state(pg_temp.corr()), 'AWAITING_HITL', 'after the COMMITTED failure the run still awaits a decision');

-- With the triggers gone the same call succeeds once
INSERT INTO v VALUES ('d3', tests.decide_raw('sarah.chen@finagent-os.demo', (SELECT j::text FROM v WHERE k = 'req'), 'APPROVED'));
SELECT is(pg_temp.g('d3')->>'committed', 'true', 'the decision then succeeds and commits');
SELECT is(tests.ledger_count(pg_temp.corr(), 'HITL_RESOLVED'), 1::bigint, 'exactly one HITL_RESOLVED');
SELECT is(tests.ledger_count(pg_temp.corr(), 'COMMITTED'), 1::bigint, 'exactly one COMMITTED');
SELECT is(tests.run_state(pg_temp.corr()), 'COMMITTED', 'the run is COMMITTED');

SELECT * FROM finish();
ROLLBACK;
