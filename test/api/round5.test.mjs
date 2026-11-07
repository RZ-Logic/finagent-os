// ============================================================================
// FinAgent OS API tests: round 5 contract over HTTP (K2, K3, K5)
// Controls: FAO-GOV-004 (an approval never commits a run whose invoker lost
// the right to run it; the decision view says why), FAO-GOV-008 (an expired
// run's idempotency key answers EXPIRED, never a token).
//
// K2 changes Aisha's owner flag and invoker grant through the admin RPCs as
// Marcus, as an operator would, and puts both back in a finally; every check
// that follows reads the restored state.
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  rpc, signIn, one, q, uid, closeAll, makeRequest, startRun, newKey, owner, ledgerTypes, MESSAGES,
} from './lib.mjs';

after(closeAll);

const TAG = `api-round5-${randomUUID().slice(0, 8)}`;
const DECIDE_KEYS = ['code', 'committed', 'committed_ledger_id', 'decided_at', 'decision', 'hitl_id', 'http_status', 'message', 'ok', 'ref'];

const invokerGrants = async () => Number((await one(
  "SELECT count(*) AS n FROM public.fao_user_roles WHERE user_id = $1 AND role = 'invoker' AND agent_id IS NULL AND revoked_at IS NULL",
  [uid('aisha')],
)).n);
const aishaActive = async () => (await one('SELECT active FROM public.process_owners WHERE id = $1', [uid('aisha')])).active;

async function admin(fn, args, why) {
  const marcus = await signIn('marcus');
  const r = await rpc(fn, { ...args, p_reason: `${TAG} ${why}` }, { token: marcus });
  assert.equal(r.status, 200, `${fn} (${why}): ${r.status} ${r.body && r.body.code}`);
  assert.equal(r.body.ok, true, `${fn} (${why})`);
}
const setActive = (active, why) => admin('fao_admin_set_owner_active', { p_user_id: uid('aisha'), p_active: String(active) }, why);
const setInvoker = (grant, why) => admin('fao_admin_set_role', { p_user_id: uid('aisha'), p_role: 'invoker', p_agent_id: null, p_grant: String(grant) }, why);

const blockedRows = (corr) => q(
  "SELECT inputs, status::text AS status, policy_outcome::text AS outcome FROM public.shadow_ledger WHERE correlation_id = $1 AND inputs->>'event_type' = 'COMMIT_BLOCKED' ORDER BY ledger_id",
  [corr],
);

async function expectInvokerNotActive(d, hitlId, label) {
  assert.equal(d.status, 409, `${label}: ${d.status} ${JSON.stringify(d.body)}`);
  assert.deepEqual(Object.keys(d.body).sort(), DECIDE_KEYS, `${label}: exactly the decide envelope keys`);
  assert.equal(d.body.ok, false);
  assert.equal(d.body.code, 'INVOKER_NOT_ACTIVE');
  assert.equal(d.body.message, MESSAGES.INVOKER_NOT_ACTIVE);
  assert.equal(d.body.http_status, 409);
  assert.equal(d.body.committed, false);
  assert.equal(d.body.committed_ledger_id, null);
  assert.equal(d.body.decision, 'APPROVED');
  assert.equal(Number(d.body.hitl_id), hitlId);
  assert.ok(d.body.decided_at, `${label}: decided_at returned`);
}

async function expectBlocked(corr, hitlId, label) {
  const run = await one('SELECT state::text AS state FROM public.run_invocations WHERE correlation_id = $1', [corr]);
  assert.equal(run.state, 'FAILED', `${label}: run FAILED`);
  const types = await ledgerTypes(corr);
  assert.ok(!types.includes('COMMITTED'), `${label}: nothing COMMITTED (${types.join(', ')})`);
  assert.ok(types.indexOf('HITL_RESOLVED') >= 0 && types.indexOf('HITL_RESOLVED') < types.indexOf('COMMIT_BLOCKED'), `${label}: HITL_RESOLVED then COMMIT_BLOCKED`);
  const b = await blockedRows(corr);
  assert.equal(b.length, 1, `${label}: one COMMIT_BLOCKED`);
  assert.equal(b[0].inputs.code, 'INVOKER_NOT_ACTIVE');
  assert.equal(b[0].inputs.reason, 'INVOKER_NOT_ACTIVE');
  assert.equal(String(b[0].inputs.hitl_id), String(hitlId));
  assert.equal(b[0].status, 'FAILURE');
  const req = await one('SELECT decision::text AS decision, approver_id FROM public.hitl_queue WHERE hitl_id = $1', [hitlId]);
  assert.equal(req.decision, 'APPROVED', `${label}: the decision is recorded`);
  assert.equal(req.approver_id, uid('sarah'));
}

// K3: the decision view of a decided request, at the top level only.
async function expectView(hitlId, status, code, committed, reason, label) {
  const sarah = await signIn('sarah');
  const g = await rpc('fao_hitl_get', { p_hitl_id: String(hitlId) }, { token: sarah });
  assert.equal(g.status, status, `${label}: ${g.status} ${JSON.stringify(g.body)}`);
  assert.equal(g.body.code, code, label);
  assert.equal(g.body.committed, committed, `${label}: committed`);
  assert.ok(Object.hasOwn(g.body, 'commit_blocked_reason'), `${label}: commit_blocked_reason present`);
  assert.equal(g.body.commit_blocked_reason, reason, `${label}: commit_blocked_reason`);
  if (code !== 'OK') assert.deepEqual(Object.keys(g.body.request).sort(), ['decided_at', 'decision', 'hitl_id'], `${label}: request keys unchanged`);
  assert.ok(!Object.hasOwn(g.body.request, 'committed') && !Object.hasOwn(g.body.request, 'commit_blocked_reason'), `${label}: nothing new inside request`);
  return g.body;
}

test('K2: Sarah\'s approval after Aisha (the invoker) is deactivated is INVOKER_NOT_ACTIVE 409; COMMIT_BLOCKED, run FAILED, nothing committed', async () => {
  assert.equal(await aishaActive(), true, 'Aisha starts active');
  const { hitlId, corr } = await makeRequest('aisha');
  const sarah = await signIn('sarah');
  let d;
  await setActive(false, 'deactivate the invoker');
  try {
    d = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED', p_notes: `${TAG} approve` }, { token: sarah });
  } finally {
    await setActive(true, 'restore the invoker');
  }
  assert.equal(await aishaActive(), true, 'Aisha restored');
  await expectInvokerNotActive(d, hitlId, 'deactivated');
  await expectBlocked(corr, hitlId, 'deactivated');
  const view = await expectView(hitlId, 410, 'ALREADY_DECIDED', false, 'INVOKER_NOT_ACTIVE', 'deactivated');
  assert.equal(view.request.decision, 'APPROVED');
});

test('K2: Sarah\'s approval after Aisha\'s invoker grant is revoked is INVOKER_NOT_ACTIVE 409; COMMIT_BLOCKED, run FAILED', async () => {
  assert.equal(await invokerGrants(), 1, 'Aisha starts with one global invoker grant');
  const { hitlId, corr } = await makeRequest('aisha');
  const sarah = await signIn('sarah');
  let d;
  await setInvoker(false, 'revoke the invoker grant');
  try {
    d = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED', p_notes: `${TAG} approve` }, { token: sarah });
  } finally {
    await setInvoker(true, 'restore the invoker grant');
  }
  assert.equal(await invokerGrants(), 1, 'grant restored');
  await expectInvokerNotActive(d, hitlId, 'revoked');
  await expectBlocked(corr, hitlId, 'revoked');
  await expectView(hitlId, 410, 'ALREADY_DECIDED', false, 'INVOKER_NOT_ACTIVE', 'revoked');
});

test('K3: committed and commit_blocked_reason on OK, approved, rejected and expired requests; absent on refusals', async () => {
  const pending = await makeRequest('aisha');
  await expectView(pending.hitlId, 200, 'OK', false, null, 'pending');

  const approved = await makeRequest('aisha');
  const rejected = await makeRequest('aisha');
  const sarah = await signIn('sarah');
  const a = await rpc('fao_hitl_decide', { p_hitl_id: String(approved.hitlId), p_decision: 'APPROVED' }, { token: sarah });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.committed, true);
  await expectView(approved.hitlId, 410, 'ALREADY_DECIDED', true, null, 'approved and committed');
  const r = await rpc('fao_hitl_decide', { p_hitl_id: String(rejected.hitlId), p_decision: 'REJECTED' }, { token: sarah });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  // A rejection commits ROLLED_BACK, so the run is COMMITTED (BUILD-CORE 2.10).
  await expectView(rejected.hitlId, 410, 'ALREADY_DECIDED', true, null, 'rejected (ROLLED_BACK commit)');

  // Past the deadline: EXPIRED with false and null. The deadline is frozen,
  // so the owner-only test clock moves past it for one read (the same rules
  // as the e2e S08 clock: refuse if a clock is set, delete only our own row).
  const late = await makeRequest('aisha');
  const deadline = new Date((await one('SELECT timeout_at FROM public.hitl_queue WHERE hitl_id = $1', [late.hitlId])).timeout_at);
  const offset = Math.ceil((deadline.getTime() - Date.now()) / 1000) + 120;
  assert.ok(offset > 0 && offset <= 2592000, `clock offset ${offset}`);
  const clockReason = `${TAG} past one request deadline`;
  await ownerTx(async (c) => {
    const held = await c.query('SELECT reason FROM fao_private.test_clock FOR UPDATE');
    assert.equal(held.rows.length, 0, 'the shared test clock is free');
    await c.query("SELECT set_config('fao.change_reason', $1, true)", [clockReason]);
    await c.query('INSERT INTO fao_private.test_clock (id, offset_seconds, reason) VALUES (1, $1, $2)', [offset, clockReason]);
  });
  try {
    await expectView(late.hitlId, 410, 'EXPIRED', false, null, 'past the deadline');
  } finally {
    await ownerTx(async (c) => {
      await c.query("SELECT set_config('fao.change_reason', $1, true)", [`${TAG} clear the test clock`]);
      await c.query('DELETE FROM fao_private.test_clock WHERE id = 1 AND reason = $1', [clockReason]);
    });
  }

  // Refusals carry neither key.
  const outsider = await signIn('outsider');
  for (const [label, args, token, status] of [
    ['NOT_FOUND', { p_hitl_id: '999999999' }, sarah, 404],
    ['INVALID_INPUT', { p_hitl_id: 'abc' }, sarah, 400],
    ['NOT_AUTHORISED', { p_hitl_id: String(pending.hitlId) }, outsider, 403],
    ['NO_SESSION', { p_hitl_id: String(pending.hitlId) }, undefined, 401],
  ]) {
    const g = await rpc('fao_hitl_get', args, { token });
    assert.equal(g.status, status, `${label}: ${g.status}`);
    if (g.body && typeof g.body === 'object') {
      assert.ok(!Object.hasOwn(g.body, 'committed') && !Object.hasOwn(g.body, 'commit_blocked_reason'), `${label}: no K3 keys`);
    }
  }
  for (const h of [pending.hitlId, late.hitlId]) {
    const done = await rpc('fao_hitl_decide', { p_hitl_id: String(h), p_decision: 'REJECTED', p_notes: `${TAG} cleanup` }, { token: sarah });
    assert.equal(done.status, 200, `cleanup ${h}: ${done.status} ${done.body && done.body.code}`);
  }
});

async function ownerTx(fn) {
  const c = await owner().connect();
  try {
    await c.query('BEGIN');
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

test('K5: replaying the idempotency key of an EXPIRED run is EXPIRED 410 with the correlation id and no token', async () => {
  const idem = newKey();
  const s = await startRun('aisha', { idem, reason: `${TAG} expiring run` });
  assert.equal(s.status, 200, JSON.stringify(s.body));
  const corr = s.body.correlation_id;
  await ownerTx(async (c) => {
    await c.query("SELECT set_config('fao.change_reason', $1, true)", [`${TAG} expire one run token`]);
    await c.query("UPDATE fao_private.run_tokens SET expires_at = now() - interval '1 second' WHERE correlation_id = $1", [corr]);
  });
  // The first replay finds the token expired: no token, and the run expires.
  const first = await startRun('aisha', { idem, reason: `${TAG} expiring run` });
  assert.ok(first.body && !first.body.run_token, `first replay: no token (${first.status} ${first.body && first.body.code})`);
  assert.equal((await one('SELECT state::text AS s FROM public.run_invocations WHERE correlation_id = $1', [corr])).s, 'EXPIRED');

  // Every replay of the EXPIRED run: the K5 envelope.
  for (const n of [2, 3]) {
    const r = await startRun('aisha', { idem, reason: `${TAG} expiring run` });
    assert.equal(r.status, 410, `replay ${n}: ${r.status} ${JSON.stringify(r.body)}`);
    assert.equal(r.body.ok, false);
    assert.equal(r.body.code, 'EXPIRED');
    assert.equal(r.body.http_status, 410);
    assert.equal(r.body.message, MESSAGES.EXPIRED);
    assert.equal(r.body.correlation_id, corr, `replay ${n}: the correlation id`);
    assert.ok(!r.body.run_token, `replay ${n}: no token`);
  }
  const runs = Number((await one('SELECT count(*) AS n FROM public.run_invocations WHERE invoker_id = $1 AND idempotency_key = $2', [uid('aisha'), idem])).n);
  assert.equal(runs, 1, 'no new run for the replayed key');
});
