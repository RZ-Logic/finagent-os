// ============================================================================
// FinAgent OS API tests: the reader user and the service-role key
// Controls: FAO-GOV-015 (reader is read-only; service_role reaches nothing),
// FAO-GOV-004 (workflow RPCs only for fao_workflow).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { cfg, rpc, rest, signIn, closeAll, uid, makeRequest, FLAGSHIP } from './lib.mjs';

after(closeAll);

const TABLES = ['shadow_ledger', 'hitl_queue', 'agent_registry', 'process_owners', 'materiality_thresholds', 'run_invocations',
  'fao_user_roles', 'fao_settings', 'fao_refusal_journal', 'fao_admin_audit', 'fao_notifications'];
// A real column per table, so PATCH is not short-circuited as an empty update.
const WRITE = {
  shadow_ledger: ['ledger_id', { policy_rationale: 'reader probe' }],
  hitl_queue: ['hitl_id', { decision_notes: 'reader probe' }],
  agent_registry: ['agent_id', { max_runs_per_hour: 1 }],
  process_owners: ['id', { active: false }],
  materiality_thresholds: ['asset_symbol', { materiality_usd: 1 }],
  run_invocations: ['correlation_id', { last_error: 'reader probe' }],
  fao_user_roles: ['id', { reason: 'reader probe' }],
  fao_settings: ['key', { value: 'reader probe' }],
  fao_refusal_journal: ['refusal_id', { code: 'OK' }],
  fao_admin_audit: ['audit_id', { reason: 'reader probe' }],
  fao_notifications: ['notification_id', { error: 'reader probe' }],
};
const WORKFLOW_RPCS = [
  ['fao_run_claim', { p_run_token: 'A'.repeat(43), p_n8n_execution_id: 'x', p_agent_id: FLAGSHIP }],
  ['fao_ledger_append_batch', { p_events: [] }],
  ['fao_run_finalize', { p_correlation_id: '00000000-0000-4000-8000-000000000000' }],
  // K1 (round 5): the full 4-argument signature, so a refusal is a permission
  // refusal and not a missing-function 404.
  ['fao_run_fail', { p_n8n_execution_id: 'x', p_failed_node: 'x', p_message: 'x', p_source: 'flagship' }],
  ['fao_notification_context', { p_hitl_id: 1, p_kind: 'REQUESTED', p_level: 0 }],
  ['fao_notification_record', { p_hitl_id: 1, p_kind: 'REQUESTED', p_level: 0, p_outcome: 'SENT', p_channel: 'slack', p_external_ref: null, p_error: null }],
  ['fao_maintenance_sweep', {}],
];
const refused = (s) => s >= 400 && s < 500;

test('every write and every workflow RPC with the reader session is refused', async () => {
  const token = await signIn('reader');
  for (const t of TABLES) {
    const [col, body] = WRITE[t];
    const post = await rest('POST', t, { token, body });
    assert.ok(refused(post.status), `POST ${t}: ${post.status}`);
    const patch = await rest('PATCH', t, { token, query: `?${col}=not.is.null`, body });
    assert.ok(refused(patch.status), `PATCH ${t}: ${patch.status}`);
    const del = await rest('DELETE', t, { token, query: `?${col}=not.is.null` });
    assert.ok(refused(del.status), `DELETE ${t}: ${del.status}`);
  }
  for (const [fn, args] of WORKFLOW_RPCS) {
    const r = await rpc(fn, args, { token });
    assert.ok(refused(r.status), `${fn}: ${r.status}`);
    assert.ok(!(r.body && r.body.ok === true), `${fn} did not succeed`);
  }
  const admin = await rpc('fao_admin_set_agent', { p_agent_id: FLAGSHIP, p_status: null, p_ai_advisory_enabled: null, p_max_runs_per_hour: '5', p_reason: 'reader probe' }, { token });
  assert.equal(admin.status, 403);
  assert.equal(admin.body.code, 'NOT_AUTHORISED');
  const { hitlId } = await makeRequest('aisha');
  const decide = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED' }, { token });
  assert.equal(decide.status, 403);
  assert.equal(decide.body.code, 'NOT_AUTHORISED');
});

test('the service-role key reaches no FinAgent table, view or function', async () => {
  const variants = [];
  if (cfg.serviceKey) variants.push({ label: 'secret key', apikey: cfg.serviceKey, token: cfg.serviceKey.startsWith('eyJ') ? cfg.serviceKey : undefined });
  if (cfg.serviceJwt) variants.push({ label: 'service JWT', apikey: cfg.serviceJwt, token: cfg.serviceJwt });
  assert.ok(variants.length > 0, 'a local service key is available');
  for (const v of variants) {
    for (const t of [...TABLES, 'fao_run_summary']) {
      const r = await rest('GET', t, { apikey: v.apikey, token: v.token, query: '?limit=1' });
      assert.ok(refused(r.status), `${v.label} GET ${t}: ${r.status}`);
    }
    for (const [fn, args] of [
      ['fao_whoami', {}], ['fao_run_start', { p_agent_id: FLAGSHIP, p_reason: 'x', p_idempotency_key: 'abcdefgh' }],
      ['fao_hitl_get', { p_hitl_id: '1' }], ['fao_hitl_decide', { p_hitl_id: '1', p_decision: 'APPROVED' }], ...WORKFLOW_RPCS,
    ]) {
      const r = await rpc(fn, args, { apikey: v.apikey, token: v.token });
      assert.ok(refused(r.status), `${v.label} ${fn}: ${r.status}`);
      assert.ok(!(r.body && r.body.ok === true), `${v.label} ${fn} did not succeed`);
    }
  }
});

// K1 (round 5, D1): fao_run_fail has exactly the strict 4-argument signature.
// The reader's 4-argument call reaches the function and is refused for lack
// of EXECUTE (not a 404 for a missing function), and the old 3-argument form
// no longer exists (PostgREST finds no function: 404 PGRST202).
test('fao_run_fail: the 4-argument call is a permission refusal, the 3-argument form is gone', async () => {
  const token = await signIn('reader');
  const four = await rpc('fao_run_fail', { p_n8n_execution_id: 'x', p_failed_node: 'x', p_message: 'x', p_source: 'flagship' }, { token });
  assert.ok(refused(four.status) && four.status !== 404, `4 arguments: ${four.status} ${four.text}`);
  assert.ok(!(four.body && four.body.ok === true));
  const three = await rpc('fao_run_fail', { p_n8n_execution_id: 'x', p_failed_node: 'x', p_message: 'x' }, { token });
  assert.equal(three.status, 404, `3 arguments: ${three.status} ${three.text}`);
  assert.equal(three.body && three.body.code, 'PGRST202');
});

test('the reader\'s fao_whoami shows exactly one global reader role', async () => {
  const token = await signIn('reader');
  const r = await rpc('fao_whoami', {}, { token });
  assert.equal(r.status, 200);
  assert.equal(r.body.user_id, uid('reader'));
  assert.equal(r.body.is_owner, false);
  assert.deepEqual(r.body.roles, [{ role: 'reader', agent_id: null }]);
});
