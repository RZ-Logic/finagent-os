// ============================================================================
// FinAgent OS API tests: fao_run_start with real sign-ins
// Controls: FAO-GOV-008 (invoker from the session, idempotency),
// FAO-GOV-002 (registry status gate, committed RUN_REFUSED),
// FAO-GOV-003 (rate limit), FAO-GOV-004 (invoker role required).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { startRun, one, q, uid, rpc, signIn, closeAll, newKey, MESSAGES } from './lib.mjs';

after(closeAll);

test('run start by Aisha records her id from the session', async () => {
  const r = await startRun('aisha');
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.state, 'REQUESTED');
  assert.equal(r.body.replayed, false);
  assert.match(r.body.run_token, /^[A-Za-z0-9_-]{43}$/);
  const row = await one('SELECT invoker_id, invoked_via, state::text AS state FROM public.run_invocations WHERE correlation_id = $1', [r.body.correlation_id]);
  assert.equal(row.invoker_id, uid('aisha'));
  assert.equal(row.invoked_via, 'test');
  assert.equal(row.state, 'REQUESTED');
});

test('a replay with the same key returns the same correlation id', async () => {
  const idem = newKey();
  const a = await startRun('aisha', { idem, reason: 'replay probe' });
  const b = await startRun('aisha', { idem, reason: 'replay probe' });
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.equal(b.body.correlation_id, a.body.correlation_id);
  assert.equal(b.body.replayed, true);
});

test('the rate-limit user gets 429 on the third run within the window', async () => {
  const agent = 'fao_ratelimit_test_v1';
  // After a fresh reset the user has no runs and the seeded limit (2) applies
  // as is. On a rerun without a reset, the limit is raised through the admin
  // RPC to 2 above the runs already in the window, then put back.
  const existing = Number((await one(
    "SELECT count(*) AS n FROM public.run_invocations WHERE invoker_id = $1 AND agent_id = $2 AND requested_at > now() - interval '1 hour'",
    [uid('ratelimit'), agent],
  )).n);
  const seeded = (await one('SELECT max_runs_per_hour AS m FROM public.agent_registry WHERE agent_id = $1', [agent])).m;
  const marcus = await signIn('marcus');
  const setLimit = (m, why) => rpc('fao_admin_set_agent', { p_agent_id: agent, p_status: null, p_ai_advisory_enabled: null, p_max_runs_per_hour: String(m), p_reason: why }, { token: marcus });
  if (existing > 0) {
    assert.ok(existing + 2 <= 60, 'room to raise the limit');
    assert.equal((await setLimit(existing + 2, 'api start test: window already holds runs')).status, 200);
  }
  try {
    const r1 = await startRun('ratelimit', { agent });
    const r2 = await startRun('ratelimit', { agent });
    const r3 = await startRun('ratelimit', { agent });
    assert.equal(r1.status, 200, `first run ${r1.status} ${r1.body && r1.body.code}`);
    assert.equal(r2.status, 200, `second run ${r2.status} ${r2.body && r2.body.code}`);
    assert.equal(r3.status, 429);
    assert.equal(r3.body.code, 'RATE_LIMITED');
    assert.equal(r3.body.message, MESSAGES.RATE_LIMITED);
  } finally {
    if (existing > 0) await setLimit(seeded, 'api start test: restore the seeded limit');
  }
});

test('Marcus (an owner without the invoker role) gets NOT_AUTHORISED', async () => {
  const r = await startRun('marcus');
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'NOT_AUTHORISED');
});

test('the reader and Outsider get NOT_AN_OWNER', async () => {
  for (const key of ['reader', 'outsider']) {
    const r = await startRun(key);
    assert.equal(r.status, 403, key);
    assert.equal(r.body.code, 'NOT_AN_OWNER', key);
    assert.equal(r.body.message, MESSAGES.NOT_AN_OWNER);
  }
});

// R28: only rows newer than the call are read, so RUN_REFUSED rows left by
// earlier runs (a --no-reset rerun) cannot satisfy the invoker check.
test('a STUB agent gives 409 and a committed RUN_REFUSED row', async () => {
  const before = (await one('SELECT coalesce(max(ledger_id), 0)::text AS m FROM public.shadow_ledger')).m;
  const r = await startRun('aisha', { agent: 'fao_variance_analyzer_v1' });
  assert.equal(r.status, 409);
  assert.equal(r.body.code, 'AGENT_NOT_ACTIVE');
  const rows = await q(
    "SELECT inputs->>'invoker_id' AS inv, policy_outcome::text AS o FROM public.shadow_ledger WHERE ledger_id > $1::bigint AND agent_id = 'fao_variance_analyzer_v1' AND inputs->>'event_type' = 'RUN_REFUSED' ORDER BY ledger_id",
    [before],
  );
  assert.equal(rows.length, 1, 'exactly one new RUN_REFUSED row, committed and visible to another connection');
  assert.equal(rows[0].inv, uid('aisha'), 'the new row names the invoker from the session');
  assert.equal(rows[0].o, 'DENY', 'the new row is DENY');
});
