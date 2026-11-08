// ============================================================================
// FinAgent OS API tests: round 5 contract over HTTP (K2, K3, K5)
// Controls: FAO-GOV-004 (an approval never commits a run whose invoker lost
// the right to run it; the decision view says why), FAO-GOV-008 (an expired
// run's idempotency key answers EXPIRED, never a token), FAO-GOV-003 (patch
// round 6 P5: replays of an EXPIRED key count toward RATE_LIMITED).
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

// Patch round 6 P5 (red team r5 item 6; FAO-GOV-003): replays of an EXPIRED
// idempotency key count toward the same RATE_LIMITED rule as run starts
// (max_runs_per_hour per invoker and agent over the last hour). Before P5
// each replay journaled one EXPIRED refusal and never reached the limit.
// Aisha (global invoker grant) on the local-only rate-limit agent, so the
// rate-limit user's own window in start.test.mjs is untouched. The limit is
// set to 3 above the runs already in the window and put back in a finally.
test('P5: repeated replays of an EXPIRED key reach RATE_LIMITED 429, and a new start is then refused the same way', async () => {
  const agent = 'fao_ratelimit_test_v1';
  const aisha = uid('aisha');
  const windowRuns = async () => Number((await one(
    "SELECT count(*) AS n FROM public.run_invocations WHERE invoker_id = $1 AND agent_id = $2 AND requested_at > now() - interval '1 hour'",
    [aisha, agent],
  )).n);
  const priorReplays = Number((await one(
    `SELECT count(*) AS n FROM public.fao_refusal_journal
      WHERE actor_uid = $1 AND entry_point = 'rpc:fao_run_start' AND code = 'EXPIRED'
        AND attempted->>'agent_id' = $2 AND at > now() - interval '1 hour'`,
    [aisha, agent],
  )).n);
  const existing = await windowRuns();
  const seeded = (await one('SELECT max_runs_per_hour AS m FROM public.agent_registry WHERE agent_id = $1', [agent])).m;
  const limit = existing + 3;
  assert.ok(limit <= 60, `room to set the limit (${existing} runs already in the window)`);
  const marcus = await signIn('marcus');
  const setLimit = async (m, why) => {
    const r = await rpc('fao_admin_set_agent', { p_agent_id: agent, p_status: null, p_ai_advisory_enabled: null, p_max_runs_per_hour: String(m), p_reason: `${TAG} ${why}` }, { token: marcus });
    assert.equal(r.status, 200, `fao_admin_set_agent ${m} (${why}): ${r.status} ${r.body && r.body.code}`);
  };
  await setLimit(limit, 'P5 limit 3 above the runs in the window');
  try {
    const idem = newKey();
    const reason = `${TAG} P5 expired replays`;
    const s = await startRun('aisha', { agent, idem, reason });
    assert.equal(s.status, 200, `start: ${s.status} ${JSON.stringify(s.body)}`);
    const corr = s.body.correlation_id;
    await ownerTx(async (c) => {
      await c.query("SELECT set_config('fao.change_reason', $1, true)", [`${TAG} P5 expire one run token`]);
      await c.query("UPDATE fao_private.run_tokens SET expires_at = now() - interval '1 second' WHERE correlation_id = $1", [corr]);
    });

    // The window now holds existing + 1 runs against a limit of existing + 3,
    // so at most 3 replays (the first one expires the run) can answer EXPIRED
    // before the replays themselves fill the window.
    const codes = [];
    for (let n = 1; n <= 8; n += 1) {
      const r = await startRun('aisha', { agent, idem, reason });
      assert.ok(r.body && !r.body.run_token, `replay ${n}: never a token (${r.status} ${r.body && r.body.code})`);
      if (r.body.code === 'RATE_LIMITED') {
        assert.equal(r.status, 429, `replay ${n}`);
        assert.equal(r.body.message, MESSAGES.RATE_LIMITED, `replay ${n}`);
      } else {
        assert.equal(r.body.code, 'EXPIRED', `replay ${n}: ${r.status} ${JSON.stringify(r.body)}`);
        assert.equal(r.status, 410, `replay ${n}`);
      }
      codes.push(r.body.code);
    }
    const seq = codes.map((c) => (c === 'EXPIRED' ? 'E' : 'R')).join('');
    assert.match(seq, /^E{0,3}R+$/, `replay codes ${codes.join(',')}: EXPIRED at most 3 times, then RATE_LIMITED every time`);
    if (existing === 0 && priorReplays === 0) assert.ok(seq.startsWith('E'), `fresh window: the first replay answers EXPIRED (${codes.join(',')})`);
    assert.equal((await one('SELECT state::text AS s FROM public.run_invocations WHERE correlation_id = $1', [corr])).s, 'EXPIRED');
    assert.equal(Number((await one('SELECT count(*) AS n FROM public.run_invocations WHERE invoker_id = $1 AND idempotency_key = $2', [aisha, idem])).n), 1, 'no new run for the replayed key');

    // Same rule as run starts: with the window filled by replays, a fresh key
    // is refused RATE_LIMITED too, and no run is created.
    const runsBefore = await windowRuns();
    assert.equal(runsBefore, existing + 1, 'only the one run in the window');
    const fresh = await startRun('aisha', { agent, reason: `${TAG} P5 fresh start after the replays` });
    assert.equal(fresh.status, 429, `fresh start: ${fresh.status} ${JSON.stringify(fresh.body)}`);
    assert.equal(fresh.body.code, 'RATE_LIMITED');
    assert.equal(await windowRuns(), runsBefore, 'the refused start created no run');
  } finally {
    await setLimit(seeded, 'P5 restore the seeded limit');
  }
});
