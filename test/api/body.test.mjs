// ============================================================================
// FinAgent OS API tests: the one JSON body of every client RPC (IC-18)
// Controls: FAO-GOV-008 (fixed validation of the whole request body before
// any authorization, through fao_private.client_args), FAO-GOV-001 (every
// body refusal journaled with attempted.invalid_body; no database text),
// FAO-GOV-004 (a GET, form-encoded or plain-text call cannot reach a client
// RPC, so it can neither change state nor evade the journal: R01, R11).
//
// Every client RPC takes one unnamed json parameter with no default. Bodies
// that reach it and break a body rule are 400 INVALID_INPUT with one journal
// row; requests PostgREST cannot route to it get PostgREST's 404 with no
// journal row; an empty body gets PostgREST's 400 with no journal row
// (IC-18 residual R1, recorded in KNOWN-LIMITS, so its text is not checked).
// ============================================================================

import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  http, signIn, uid, one, makeRequest, maxRefusalId, journalSince, closeAll, newKey, FLAGSHIP, MESSAGES, FORBIDDEN_TEXT,
} from './lib.mjs';

after(closeAll);

const TAG = `api-body-${randomUUID().slice(0, 8)}`;
const UNKNOWN = 'p_zz_unknown';

// Per client RPC: the caller who would succeed with the base body, the base
// body (valid, so a call that reached the function would act), and the
// required keys (section 3 of the IC-18 design). Filled in before().
let RPCS = [];
let hitlId = null;

before(async () => {
  ({ hitlId } = await makeRequest('aisha'));
  const seed = await one("SELECT asset_class::text AS c, materiality_usd::text AS m, ratio_floor::text AS f, ratio_band_lower::text AS l, ratio_band_upper::text AS u, notes AS n FROM public.materiality_thresholds WHERE asset_symbol = 'BTC' AND scope = 'Spot'");
  const agent = await one("SELECT status::text AS s, ai_advisory_enabled::text AS a, max_runs_per_hour::text AS m FROM public.agent_registry WHERE agent_id = $1", [FLAGSHIP]);
  const ledger = await one('SELECT max(ledger_id)::text AS id FROM public.shadow_ledger');
  RPCS = [
    ['fao_whoami', 'marcus', {}, []],
    ['fao_run_start', 'aisha', { p_agent_id: FLAGSHIP, p_reason: `${TAG} start`, p_idempotency_key: newKey(), p_invoked_via: 'test' }, ['p_agent_id', 'p_reason', 'p_idempotency_key']],
    ['fao_hitl_get', 'sarah', { p_hitl_id: String(hitlId) }, ['p_hitl_id']],
    ['fao_hitl_decide', 'sarah', { p_hitl_id: String(hitlId), p_decision: 'APPROVED', p_notes: `${TAG} decide` }, ['p_hitl_id', 'p_decision']],
    ['fao_ledger_correct', 'marcus', { p_ledger_id: ledger.id, p_reason: `${TAG} correct` }, ['p_ledger_id', 'p_reason']],
    ['fao_admin_set_threshold', 'marcus', {
      p_asset_symbol: 'BTC', p_scope: 'Spot', p_asset_class: seed.c, p_materiality_usd: seed.m, p_ratio_floor: seed.f,
      p_ratio_band_lower: seed.l, p_ratio_band_upper: seed.u, p_notes: seed.n, p_reason: `${TAG} threshold`,
    }, ['p_asset_symbol', 'p_scope', 'p_asset_class', 'p_materiality_usd', 'p_ratio_floor', 'p_ratio_band_lower', 'p_ratio_band_upper', 'p_notes', 'p_reason']],
    ['fao_admin_set_agent', 'marcus', { p_agent_id: FLAGSHIP, p_status: agent.s, p_ai_advisory_enabled: agent.a, p_max_runs_per_hour: agent.m, p_reason: `${TAG} agent` },
      ['p_agent_id', 'p_status', 'p_ai_advisory_enabled', 'p_max_runs_per_hour', 'p_reason']],
    ['fao_admin_set_role', 'marcus', { p_user_id: uid('aisha'), p_role: 'reader', p_agent_id: FLAGSHIP, p_grant: 'true', p_reason: `${TAG} role` },
      ['p_user_id', 'p_role', 'p_agent_id', 'p_grant', 'p_reason']],
    ['fao_admin_set_owner_active', 'marcus', { p_user_id: uid('ratelimit'), p_active: 'true', p_reason: `${TAG} owner` }, ['p_user_id', 'p_active', 'p_reason']],
  ];
});

// Everything a client RPC can change, plus the journal.
const snapshot = () => one(`SELECT
    (SELECT coalesce(max(ledger_id), 0) FROM public.shadow_ledger)::text      AS ledger,
    (SELECT coalesce(max(audit_id), 0) FROM public.fao_admin_audit)::text     AS audit,
    (SELECT coalesce(max(refusal_id), 0) FROM public.fao_refusal_journal)::text AS journal,
    (SELECT count(*) FROM public.run_invocations)::text                       AS runs,
    (SELECT count(*) FROM public.hitl_queue WHERE decision::text <> 'PENDING')::text AS decided,
    (SELECT count(*) FROM public.fao_notifications)::text                     AS notices`);

// A raw JSON body: the base object with one more "key": value pair appended.
const appendPair = (base, pair) => {
  const s = JSON.stringify(base);
  return s === '{}' ? `{${pair}}` : `${s.slice(0, -1)},${pair}}`;
};

const post = (fn, token, body, contentType = 'application/json') => http('POST', `/rest/v1/rpc/${fn}`, { token, body, headers: { 'Content-Type': contentType } });
const query = (base) => new URLSearchParams(Object.entries(base).filter(([, v]) => v !== null)).toString();

// The body cases that reach the function, with the reason client_args gives.
function bodyCases(base, required) {
  const cases = [];
  if (required.length > 0) {
    const missing = { ...base };
    delete missing[required[0]];
    cases.push([`missing ${required[0]}`, JSON.stringify(missing), 'missing_key']);
  }
  cases.push(['unknown key', appendPair(base, `"${UNKNOWN}":"x"`), 'unknown_key']);
  const [k] = Object.keys(base);
  cases.push(['duplicate key', k ? appendPair(base, `"${k}":${JSON.stringify(base[k])}`) : '{"p_x":"1","p_x":"1"}', 'duplicate_key']);
  cases.push(['array body', JSON.stringify([base]), 'not_object']);
  // A literal JSON \u0000 escape inside a key (the six characters).
  cases.push(['\\u0000 in a key', appendPair(base, '"p_\\u0000":"x"'), 'undecodable']);
  return cases;
}

test('every client RPC: missing, unknown and duplicate keys, an array body and a \\u0000 key are 400 INVALID_INPUT, journaled once with attempted.invalid_body', async () => {
  let n = 0;
  for (const [fn, who, base, required] of RPCS) {
    const token = await signIn(who);
    for (const [label, raw, reason] of bodyCases(base, required)) {
      const tag = `${fn} ${label}`;
      const before = await maxRefusalId();
      const r = await post(fn, token, raw);
      assert.equal(r.status, 400, `${tag}: status ${r.status} ${r.text.slice(0, 160)}`);
      assert.equal(r.body.code, 'INVALID_INPUT', tag);
      assert.equal(r.body.message, MESSAGES.INVALID_INPUT, tag);
      assert.equal(r.body.ok, false, tag);
      assert.ok(!FORBIDDEN_TEXT.test(r.text), `${tag}: response carries database text`);
      const rows = await journalSince(before);
      assert.equal(rows.length, 1, `${tag}: exactly one journal row`);
      assert.equal(rows[0].entry_point, `rpc:${fn}`, tag);
      assert.equal(rows[0].code, 'INVALID_INPUT', tag);
      assert.equal(rows[0].actor_uid, uid(who), `${tag}: journal names the caller`);
      assert.equal(Number(rows[0].refusal_id), Number(r.body.ref), tag);
      assert.equal(rows[0].attempted.invalid_body, reason, `${tag}: invalid_body ${reason}`);
      assert.ok(!JSON.stringify(rows[0].attempted).includes(UNKNOWN), `${tag}: the raw body is not stored`);
      n += 1;
    }
  }
  assert.equal(n, RPCS.length * 5 - 1, 'five cases per RPC (fao_whoami has no required key)');
});

test('every client RPC: GET, HEAD, form-encoded (with and without %00) and text/plain get PostgREST 404, no journal row and no state change', async () => {
  const before0 = await snapshot();
  for (const [fn, who, base] of RPCS) {
    const token = await signIn(who);
    const qs = query(base);
    const textKey = Object.keys(base).find((k) => /reason|notes/.test(k)) || Object.keys(base)[0];
    const cut = textKey ? query({ ...base, [textKey]: `${base[textKey]}\u0000tail` }) : 'p_x=a%00b';
    const calls = [
      ['GET', () => http('GET', `/rest/v1/rpc/${fn}${qs ? `?${qs}` : ''}`, { token })],
      ['GET no parameters', () => http('GET', `/rest/v1/rpc/${fn}`, { token })],
      ['HEAD', () => http('HEAD', `/rest/v1/rpc/${fn}${qs ? `?${qs}` : ''}`, { token })],
      ['form', () => post(fn, token, qs, 'application/x-www-form-urlencoded')],
      ['form with %00', () => post(fn, token, cut, 'application/x-www-form-urlencoded')],
      ['text/plain', () => post(fn, token, JSON.stringify(base), 'text/plain')],
    ];
    assert.ok(cut.includes('%00'), `${fn}: the form body carries %00`);
    for (const [label, call] of calls) {
      const tag = `${fn} ${label}`;
      const before = await maxRefusalId();
      const r = await call();
      assert.equal(r.status, 404, `${tag}: status ${r.status} ${r.text.slice(0, 160)}`);
      assert.ok(!(r.body && ('ok' in r.body || 'ref' in r.body)), `${tag}: not a FinAgent envelope, so the function was not entered`);
      if (label !== 'HEAD') assert.equal(r.body && r.body.code, 'PGRST202', `${tag}: PostgREST found no routable function`);
      assert.equal((await journalSince(before)).length, 0, `${tag}: no journal row`);
    }
  }
  assert.deepEqual(await snapshot(), before0, 'no ledger, audit, journal, run, decision or notification change');
  assert.equal((await one('SELECT decision::text AS d FROM public.hitl_queue WHERE hitl_id = $1', [hitlId])).d, 'PENDING', 'the request is still PENDING');
});

test('every client RPC: an empty body gets PostgREST 400, no journal row and no state change (IC-18 residual R1)', async () => {
  const before0 = await snapshot();
  for (const [fn, who] of RPCS) {
    const token = await signIn(who);
    const r = await post(fn, token, '');
    assert.equal(r.status, 400, `${fn}: status ${r.status} ${r.text.slice(0, 160)}`);
    assert.ok(!(r.body && ('ok' in r.body || 'ref' in r.body)), `${fn}: not a FinAgent envelope`);
  }
  assert.deepEqual(await snapshot(), before0, 'no journal row and no state change');
});

test('control: each base body is valid, so the 404 cases above are not refusals for bad input', async () => {
  // Only the read-only RPCs are called with the base body here; the others
  // are covered by their own API files with the same bodies.
  for (const [fn, who, base] of RPCS.filter(([f]) => f === 'fao_whoami' || f === 'fao_hitl_get')) {
    const r = await post(fn, await signIn(who), JSON.stringify(base));
    assert.equal(r.status, 200, `${fn}: status ${r.status} ${r.body && r.body.code}`);
    assert.equal(r.body.ok, true, fn);
  }
});
