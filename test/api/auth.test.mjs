// ============================================================================
// FinAgent OS API tests: sessions and anonymous callers
// Controls: FAO-GOV-004 and FAO-GOV-008 (identity only from a valid Supabase
// Auth session), FAO-GOV-001 (anonymous refusals journaled).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  cfg, rpc, rest, signIn, jwtPayload, forgeJwt, maxRefusalId, journalSince, closeAll, uid, EMAIL, newKey, FLAGSHIP, MESSAGES,
} from './lib.mjs';

after(closeAll);

test('public key alone: fao_hitl_decide and fao_run_start return 401 NO_SESSION, each journaled once as anon', async () => {
  for (const [fn, args] of [
    ['fao_hitl_decide', { p_hitl_id: '1', p_decision: 'APPROVED' }],
    ['fao_run_start', { p_agent_id: FLAGSHIP, p_reason: 'anon probe', p_idempotency_key: newKey() }],
  ]) {
    const before = await maxRefusalId();
    const r = await rpc(fn, args);
    assert.equal(r.status, 401, `${fn} status`);
    assert.equal(r.body.code, 'NO_SESSION');
    assert.equal(r.body.message, MESSAGES.NO_SESSION);
    assert.equal(r.body.ok, false);
    const rows = await journalSince(before);
    assert.equal(rows.length, 1, `${fn}: exactly one journal row`);
    assert.equal(rows[0].actor_uid, null);
    assert.equal(rows[0].db_role, 'anon');
    assert.equal(rows[0].entry_point, `rpc:${fn}`);
    assert.equal(Number(r.body.ref), Number(rows[0].refusal_id));
  }
});

test('public key alone: other FinAgent functions, tables and the view get PostgREST 401 or 403 with no journal row', async () => {
  const before = await maxRefusalId();
  const calls = [
    ['fao_whoami', {}],
    ['fao_hitl_get', { p_hitl_id: '1' }],
    ['fao_ledger_correct', { p_ledger_id: '1', p_reason: 'x' }],
    ['fao_admin_set_agent', { p_agent_id: FLAGSHIP, p_status: null, p_ai_advisory_enabled: null, p_max_runs_per_hour: '6', p_reason: 'x' }],
    ['fao_run_claim', { p_run_token: 'x', p_n8n_execution_id: 'y' }],
    ['fao_maintenance_sweep', {}],
  ];
  for (const [fn, args] of calls) {
    const r = await rpc(fn, args);
    assert.ok([401, 403].includes(r.status), `${fn}: status ${r.status}`);
  }
  for (const t of ['shadow_ledger', 'hitl_queue', 'run_invocations', 'agent_registry', 'process_owners', 'fao_refusal_journal', 'fao_settings', 'fao_run_summary']) {
    const r = await rest('GET', t, { query: '?limit=1' });
    assert.ok([401, 403].includes(r.status), `${t}: status ${r.status}`);
  }
  assert.equal((await journalSince(before)).length, 0, 'no journal row');
});

test('expired, tampered and foreign-secret tokens get PostgREST 401 and leave no journal row', async () => {
  const sarahToken = await signIn('sarah');
  const now = Math.floor(Date.now() / 1000);
  const claims = { sub: uid('sarah'), role: 'authenticated', aud: 'authenticated', email: EMAIL.sarah, aal: 'aal1' };
  const [h, p, s] = sarahToken.split('.');
  const flipped = s.slice(0, -2) + (s.slice(-2) === 'AA' ? 'BB' : 'AA');
  const tokens = {
    tampered_signature: `${h}.${p}.${flipped}`,
    tampered_payload: `${h}.${Buffer.from(JSON.stringify({ ...jwtPayload(sarahToken), sub: uid('marcus') })).toString('base64url')}.${s}`,
    other_secret: forgeJwt({ ...claims, iat: now, exp: now + 3600 }, 'not-the-project-secret-not-the-project-secret'),
  };
  if (cfg.jwtSecret) tokens.expired = forgeJwt({ ...claims, iat: now - 7200, exp: now - 3600 }, cfg.jwtSecret);
  const before = await maxRefusalId();
  for (const [label, token] of Object.entries(tokens)) {
    const r = await rpc('fao_hitl_decide', { p_hitl_id: '1', p_decision: 'APPROVED' }, { token });
    assert.equal(r.status, 401, `${label}: status ${r.status}`);
    assert.notEqual(r.body && r.body.code, 'NO_SESSION', `${label}: rejected before the database`);
  }
  assert.equal((await journalSince(before)).length, 0, 'no journal row (the stated residual)');
});

test('a cookie-only request with no Authorization header is anonymous', async () => {
  const sarahToken = await signIn('sarah');
  const before = await maxRefusalId();
  const r = await rpc('fao_hitl_decide', { p_hitl_id: '1', p_decision: 'APPROVED' }, {
    token: sarahToken,
    noAuthHeader: true,
    headers: { Cookie: `sb-access-token=${sarahToken}; sb-127-auth-token=${sarahToken}` },
  });
  assert.equal(r.status, 401);
  assert.equal(r.body.code, 'NO_SESSION');
  const rows = await journalSince(before);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].actor_uid, null);
  assert.equal(rows[0].db_role, 'anon');
});

test('a differently cased email at sign-in resolves to the same user id', async () => {
  const lower = await signIn('sarah');
  const upper = await signIn('sarah', { email: EMAIL.sarah.toUpperCase() });
  assert.equal(jwtPayload(upper).sub, jwtPayload(lower).sub);
  assert.equal(jwtPayload(upper).sub, uid('sarah'));
  const w = await rpc('fao_whoami', {}, { token: upper });
  assert.equal(w.status, 200);
  assert.equal(w.body.user_id, uid('sarah'));
});
