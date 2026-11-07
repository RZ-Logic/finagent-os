// ============================================================================
// FinAgent OS API tests: admin changes through the RPCs with real sign-ins
// Controls: FAO-GOV-002 (registry and threshold changes audited with actor
// and reason), FAO-GOV-004 (role changes, no self change), FAO-REC-002.
// Every change made here is put back, so later files see the seeded state.
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { rpc, signIn, one, q, uid, closeAll, FLAGSHIP, MESSAGES } from './lib.mjs';

after(closeAll);

const TAG = `api-admin-${randomUUID().slice(0, 8)}`;
const audits = (like) => q('SELECT * FROM public.fao_admin_audit WHERE reason LIKE $1 ORDER BY audit_id', [`%${like}%`]);

test('Marcus changes a threshold, a rate limit, a role and an owner flag; each writes one audit row naming him', async () => {
  const marcus = await signIn('marcus');
  const seed = await one("SELECT asset_class::text AS c, materiality_usd::text AS m, ratio_floor::text AS f, ratio_band_lower::text AS l, ratio_band_upper::text AS u, notes FROM public.materiality_thresholds WHERE asset_symbol = 'BTC' AND scope = 'Spot'");
  const flagship = await one('SELECT max_runs_per_hour AS m FROM public.agent_registry WHERE agent_id = $1', [FLAGSHIP]);

  const changes = [
    ['threshold', 'fao_admin_set_threshold', { p_asset_symbol: 'BTC', p_scope: 'Spot', p_asset_class: seed.c, p_materiality_usd: seed.m, p_ratio_floor: seed.f, p_ratio_band_lower: seed.l, p_ratio_band_upper: seed.u, p_notes: seed.notes, p_reason: `${TAG} threshold` }, 'public.materiality_thresholds'],
    ['agent', 'fao_admin_set_agent', { p_agent_id: FLAGSHIP, p_status: null, p_ai_advisory_enabled: null, p_max_runs_per_hour: String(Math.max(1, flagship.m - 1)), p_reason: `${TAG} agent` }, 'public.agent_registry'],
    ['role', 'fao_admin_set_role', { p_user_id: uid('aisha'), p_role: 'reader', p_agent_id: null, p_grant: 'true', p_reason: `${TAG} role` }, 'public.fao_user_roles'],
    ['owner', 'fao_admin_set_owner_active', { p_user_id: uid('ratelimit'), p_active: 'false', p_reason: `${TAG} owner` }, 'public.process_owners'],
  ];
  try {
    for (const [label, fn, args, table] of changes) {
      const r = await rpc(fn, args, { token: marcus });
      assert.equal(r.status, 200, `${label}: ${r.status} ${r.body && r.body.code}`);
      assert.equal(r.body.ok, true, label);
      assert.ok('before' in r.body && 'after' in r.body, `${label}: before and after returned`);
      const rows = await audits(`${TAG} ${label}`);
      assert.equal(rows.length, 1, `${label}: one audit row`);
      assert.equal(rows[0].actor_uid, uid('marcus'), `${label}: audit names Marcus`);
      assert.equal(rows[0].table_name, table, label);
      assert.equal(rows[0].session_role, 'authenticator', label);
    }
    assert.equal((await one('SELECT max_runs_per_hour AS m FROM public.agent_registry WHERE agent_id = $1', [FLAGSHIP])).m, Math.max(1, flagship.m - 1));
    assert.equal((await one('SELECT active FROM public.process_owners WHERE id = $1', [uid('ratelimit')])).active, false);
  } finally {
    await rpc('fao_admin_set_agent', { p_agent_id: FLAGSHIP, p_status: null, p_ai_advisory_enabled: null, p_max_runs_per_hour: String(flagship.m), p_reason: `${TAG} restore agent` }, { token: marcus });
    await rpc('fao_admin_set_role', { p_user_id: uid('aisha'), p_role: 'reader', p_agent_id: null, p_grant: 'false', p_reason: `${TAG} restore role` }, { token: marcus });
    await rpc('fao_admin_set_owner_active', { p_user_id: uid('ratelimit'), p_active: 'true', p_reason: `${TAG} restore owner` }, { token: marcus });
  }
  assert.equal((await one('SELECT max_runs_per_hour AS m FROM public.agent_registry WHERE agent_id = $1', [FLAGSHIP])).m, flagship.m, 'rate limit restored');
  assert.equal((await one('SELECT active FROM public.process_owners WHERE id = $1', [uid('ratelimit')])).active, true, 'owner restored');
  assert.equal(Number((await one("SELECT count(*) AS n FROM public.fao_user_roles WHERE user_id = $1 AND role = 'reader' AND revoked_at IS NULL", [uid('aisha')])).n), 0, 'role restored');
});

test('Sarah is refused every admin change', async () => {
  const sarah = await signIn('sarah');
  const before = Number((await one('SELECT count(*) AS n FROM public.fao_admin_audit')).n);
  for (const [fn, args] of [
    ['fao_admin_set_threshold', { p_asset_symbol: 'BTC', p_scope: 'Spot', p_asset_class: 'Major', p_materiality_usd: '1', p_ratio_floor: '1', p_ratio_band_lower: '1', p_ratio_band_upper: '1', p_notes: null, p_reason: `${TAG} sarah` }],
    ['fao_admin_set_agent', { p_agent_id: FLAGSHIP, p_status: null, p_ai_advisory_enabled: null, p_max_runs_per_hour: '1', p_reason: `${TAG} sarah` }],
    ['fao_admin_set_role', { p_user_id: uid('aisha'), p_role: 'admin', p_agent_id: null, p_grant: 'true', p_reason: `${TAG} sarah` }],
    ['fao_admin_set_owner_active', { p_user_id: uid('aisha'), p_active: 'false', p_reason: `${TAG} sarah` }],
    ['fao_ledger_correct', { p_ledger_id: '1', p_reason: `${TAG} sarah` }],
  ]) {
    const r = await rpc(fn, args, { token: sarah });
    assert.equal(r.status, 403, fn);
    assert.equal(r.body.code, 'NOT_AUTHORISED', fn);
    assert.equal(r.body.message, MESSAGES.NOT_AUTHORISED);
    assert.ok(r.body.ref, `${fn}: journaled`);
  }
  assert.equal(Number((await one('SELECT count(*) AS n FROM public.fao_admin_audit')).n), before, 'no audit row for refused changes');
});

test('Marcus changing his own roles or active flag gets SELF_CHANGE', async () => {
  const marcus = await signIn('marcus');
  for (const [fn, args] of [
    ['fao_admin_set_role', { p_user_id: uid('marcus'), p_role: 'invoker', p_agent_id: null, p_grant: 'true', p_reason: `${TAG} self` }],
    ['fao_admin_set_role', { p_user_id: uid('marcus'), p_role: 'admin', p_agent_id: null, p_grant: 'false', p_reason: `${TAG} self` }],
    ['fao_admin_set_owner_active', { p_user_id: uid('marcus'), p_active: 'false', p_reason: `${TAG} self` }],
  ]) {
    const r = await rpc(fn, args, { token: marcus });
    assert.equal(r.status, 403, fn);
    assert.equal(r.body.code, 'SELF_CHANGE', fn);
    assert.equal(r.body.message, MESSAGES.SELF_CHANGE);
  }
  assert.equal((await audits(`${TAG} self`)).length, 0);
});
