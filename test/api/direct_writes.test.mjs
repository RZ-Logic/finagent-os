// ============================================================================
// FinAgent OS API tests: direct table writes through PostgREST
// Controls: FAO-GOV-001 (ledger and journal append-only), FAO-GOV-004
// (decisions only through fao_hitl_decide), FAO-GOV-002 (registry, owners,
// thresholds, roles and settings changed only through the admin path).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { rest, signIn, q, makeRequest, closeAll } from './lib.mjs';

after(closeAll);

// Table, a column every row has (for a filter), and a plausible body.
const TABLES = [
  ['shadow_ledger', 'ledger_id', { policy_rationale: 'api direct write' }],
  ['hitl_queue', 'hitl_id', { decision: 'APPROVED', decision_notes: 'api direct write' }],
  ['agent_registry', 'agent_id', { max_runs_per_hour: 1 }],
  ['process_owners', 'id', { active: false }],
  ['materiality_thresholds', 'asset_symbol', { materiality_usd: 1 }],
  ['run_invocations', 'correlation_id', { state: 'COMMITTED' }],
  ['fao_user_roles', 'id', { revoked_at: '2026-01-01T00:00:00Z' }],
  ['fao_settings', 'key', { value: 'http://evil.invalid' }],
  ['fao_refusal_journal', 'refusal_id', { code: 'OK' }],
  ['fao_admin_audit', 'audit_id', { reason: 'api direct write' }],
  ['fao_notifications', 'notification_id', { outcome: 'SENT' }],
  ['fao_run_summary', 'correlation_id', { run_state: 'COMMITTED' }],
];
const USERS = ['aisha', 'sarah', 'marcus', 'reader', 'outsider', 'ratelimit'];

async function snapshot() {
  const out = {};
  for (const [t] of TABLES) {
    const rows = await q(`SELECT md5(coalesce(string_agg(x::text, '|' ORDER BY x::text), '')) AS h, count(*) AS n FROM public.${t} x`);
    out[t] = `${rows[0].n}:${rows[0].h}`;
  }
  return out;
}

test('POST, PATCH and DELETE by every signed-in user on every FinAgent table are refused and change nothing', async () => {
  await makeRequest('aisha');
  const before = await snapshot();
  for (const key of USERS) {
    const token = await signIn(key);
    for (const [t, col, body] of TABLES) {
      const post = await rest('POST', t, { token, body, headers: { Prefer: 'return=minimal' } });
      assert.ok(post.status >= 400 && post.status < 500, `${key} POST ${t}: ${post.status}`);
      const patch = await rest('PATCH', t, { token, query: `?${col}=not.is.null`, body, headers: { Prefer: 'return=minimal' } });
      assert.ok(patch.status >= 400 && patch.status < 500, `${key} PATCH ${t}: ${patch.status}`);
      const del = await rest('DELETE', t, { token, query: `?${col}=not.is.null`, headers: { Prefer: 'return=minimal' } });
      assert.ok(del.status >= 400 && del.status < 500, `${key} DELETE ${t}: ${del.status}`);
    }
  }
  assert.deepEqual(await snapshot(), before, 'every table is unchanged');
});
