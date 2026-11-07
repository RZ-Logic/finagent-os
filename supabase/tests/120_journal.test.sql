-- ============================================================================
-- FinAgent OS pgTAP 120: refusal journal flood cap
-- Controls: FAO-GOV-001 (refusals journaled in the same transaction, a
-- per-actor cap with one suppression marker, refusals still enforced past
-- the cap, no run token in any attempt).
-- ============================================================================
BEGIN;
SELECT plan(13);

CREATE TEMP TABLE v (k text PRIMARY KEY, j jsonb);
CREATE FUNCTION pg_temp.g(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT j FROM v WHERE k = p_k $$;
INSERT INTO v VALUES ('start_id', to_jsonb(coalesce((SELECT max(refusal_id) FROM public.fao_refusal_journal), 0)));
INSERT INTO v VALUES ('actor', to_jsonb(gen_random_uuid()));
CREATE FUNCTION pg_temp.actor() RETURNS uuid LANGUAGE sql AS $$ SELECT (j#>>'{}')::uuid FROM v WHERE k = 'actor' $$;
CREATE FUNCTION pg_temp.since() RETURNS bigint LANGUAGE sql AS $$ SELECT (j::text)::bigint FROM v WHERE k = 'start_id' $$;

-- The cap is set to 3 above whatever the anonymous bucket already holds in
-- the last minute (committed rows from other layers), so the counts below
-- do not depend on earlier activity.
INSERT INTO v VALUES ('anon_existing', to_jsonb((SELECT count(*) FROM public.fao_refusal_journal
  WHERE actor_uid IS NULL AND db_role = 'anon' AND code <> 'JOURNAL_SUPPRESSED' AND at > clock_timestamp() - interval '1 minute')));
CREATE FUNCTION pg_temp.cap() RETURNS int LANGUAGE sql AS $$ SELECT 3 + (j::text)::int FROM v WHERE k = 'anon_existing' $$;
DO $$ BEGIN
  PERFORM set_config('fao.change_reason', 'pgtap 120 lower the journal cap', true);
  UPDATE public.fao_settings SET value = pg_temp.cap()::text WHERE key = 'journal_cap_per_minute';
END $$;

-- A synthetic signed-in actor with no role: cap + 3 refusals
CREATE TEMP TABLE attempts (n int, r jsonb);
INSERT INTO attempts SELECT n, tests.decide_raw('uid:' || pg_temp.actor()::text, '1', 'APPROVED') FROM generate_series(1, pg_temp.cap() + 3) n;

SELECT is((SELECT count(*) FROM attempts WHERE r->>'code' = 'NOT_AUTHORISED'), (pg_temp.cap() + 3)::bigint, 'every attempt is still refused past the cap');
SELECT is((SELECT count(*) FROM attempts WHERE n <= pg_temp.cap() AND r->>'ref' IS NOT NULL), pg_temp.cap()::bigint, 'attempts up to the cap are journaled');
SELECT is((SELECT count(*) FROM attempts WHERE n > pg_temp.cap() AND r->>'ref' IS NULL), 3::bigint, 'attempts past the cap return no journal reference');
SELECT is((SELECT count(*) FROM public.fao_refusal_journal WHERE actor_uid = pg_temp.actor() AND code = 'NOT_AUTHORISED'), pg_temp.cap()::bigint, 'exactly the cap is journaled for the actor');
SELECT is((SELECT count(*) FROM public.fao_refusal_journal WHERE actor_uid = pg_temp.actor() AND code = 'JOURNAL_SUPPRESSED'), 1::bigint, 'exactly one JOURNAL_SUPPRESSED row for the actor');
SELECT is((SELECT message FROM public.fao_refusal_journal WHERE actor_uid = pg_temp.actor() AND code = 'JOURNAL_SUPPRESSED'),
  'Further refusals for this caller are not journaled for the rest of this minute.', 'JOURNAL_SUPPRESSED carries its fixed message');

-- Anonymous refusals share one bucket across functions: 3 more fit under the cap
CREATE TEMP TABLE anon_attempts (n int, r jsonb);
INSERT INTO anon_attempts SELECT n, tests.start_raw('anon', 'fao_reserve_recon_v1', 'r', tests.new_key()) FROM generate_series(1, 2) n;
INSERT INTO anon_attempts SELECT n, tests.decide_raw('anon', '1', 'APPROVED') FROM generate_series(3, 5) n;
SELECT is((SELECT count(*) FROM anon_attempts WHERE r->>'code' = 'NO_SESSION'), 5::bigint, 'every anonymous attempt is refused');
SELECT is((SELECT count(*) FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND actor_uid IS NULL AND db_role = 'anon' AND code = 'NO_SESSION'), 3::bigint,
  'anonymous refusals across functions share one capped bucket');
SELECT is((SELECT count(*) FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND actor_uid IS NULL AND db_role = 'anon' AND code = 'JOURNAL_SUPPRESSED'), 1::bigint,
  'one JOURNAL_SUPPRESSED row for the anonymous bucket');

-- A different actor has its own bucket
INSERT INTO v VALUES ('other', tests.decide_raw('uid:' || gen_random_uuid()::text, '1', 'APPROVED'));
SELECT ok(pg_temp.g('other')->>'ref' IS NOT NULL, 'another actor is still journaled');

-- attempted never holds a run token
INSERT INTO v VALUES ('start', tests.start_run('aisha.okonkwo@finagent-os.demo'));
INSERT INTO v VALUES ('claim1', tests.claim(pg_temp.g('start')->>'run_token', 'pgtap-120-a'));
INSERT INTO v VALUES ('claim2', tests.claim_raw(pg_temp.g('start')->>'run_token', 'pgtap-120-b'));
SELECT is(pg_temp.g('claim2')->>'code', 'ALREADY_CLAIMED', 'setup: a replayed token is refused');
SELECT is_empty($$SELECT 1 FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since()
                  AND (attempted::text LIKE '%' || (pg_temp.g('start')->>'run_token') || '%' OR coalesce(target_key, '') LIKE '%' || (pg_temp.g('start')->>'run_token') || '%')$$,
  'no journal row holds the run token');
SELECT ok(EXISTS (SELECT 1 FROM public.fao_refusal_journal WHERE refusal_id > pg_temp.since() AND entry_point = 'rpc:fao_run_claim' AND attempted->>'n8n_execution_id' = 'pgtap-120-b'),
  'the claim refusal journals the execution id instead');

SELECT * FROM finish();
ROLLBACK;
