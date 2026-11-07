// ============================================================================
// FinAgent OS API tests: segregation of duties with real sign-ins
// Controls: FAO-GOV-004 (no self-approval; identity never from arguments or
// headers), FAO-GOV-001 (refusal journaled with the caller's id).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { rpc, signIn, uid, makeRequest, one, q, journalRow, closeAll, newKey, FLAGSHIP, MESSAGES } from './lib.mjs';

after(closeAll);

const decision = async (id) => (await one('SELECT decision::text AS d FROM public.hitl_queue WHERE hitl_id = $1', [id])).d;

// IC-18: an extra body key is refused by fao_private.client_args as
// unknown_key, before any authorization, journaled with the caller's id.
const assertUnknownKey = async (r, label, who) => {
  assert.equal(r.status, 400, `${label}: status ${r.status}`);
  assert.equal(r.body.code, 'INVALID_INPUT', label);
  assert.equal(r.body.message, MESSAGES.INVALID_INPUT, label);
  assert.notEqual(r.body.ok, true, label);
  assert.ok(r.body.ref, `${label}: journal reference returned`);
  const row = await journalRow(r.body.ref);
  assert.equal(row.code, 'INVALID_INPUT', label);
  assert.equal(row.actor_uid, uid(who), `${label}: journal names the signed-in caller`);
  assert.equal(row.attempted.invalid_body, 'unknown_key', `${label}: refused by the body rule`);
};

test('identity named in extra body keys is refused with 400 INVALID_INPUT (unknown_key), journaled', async () => {
  const { hitlId } = await makeRequest('aisha');
  const aisha = await signIn('aisha');
  for (const extra of [{ p_approver_id: uid('sarah') }, { p_user_id: uid('sarah') }, { approver_id: uid('sarah') }]) {
    const r = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED', ...extra }, { token: aisha });
    await assertUnknownKey(r, `decide + ${Object.keys(extra)[0]}`, 'aisha');
  }
  const runsBefore = Number((await one('SELECT count(*) AS n FROM public.run_invocations WHERE invoker_id = $1', [uid('sarah')])).n);
  const s = await rpc('fao_run_start', { p_agent_id: FLAGSHIP, p_reason: 'x', p_idempotency_key: newKey(), p_invoker_id: uid('sarah') }, { token: aisha });
  await assertUnknownKey(s, 'run start + p_invoker_id', 'aisha');
  assert.equal(Number((await one('SELECT count(*) AS n FROM public.run_invocations WHERE invoker_id = $1', [uid('sarah')])).n), runsBefore, 'no run recorded under Sarah');
  assert.equal(await decision(hitlId), 'PENDING');
});

test('identity in headers changes nothing', async () => {
  const { hitlId } = await makeRequest('aisha');
  const forged = {
    'X-User-Id': uid('sarah'),
    'X-Forwarded-For': '127.0.0.1',
    'X-Forwarded-User': 'sarah.chen@finagent-os.demo',
    'X-Forwarded-Email': 'sarah.chen@finagent-os.demo',
    Prefer: 'tx=commit, return=representation',
  };
  const outsider = await signIn('outsider');
  const g = await rpc('fao_hitl_get', { p_hitl_id: String(hitlId) }, { token: outsider, headers: forged });
  assert.equal(g.status, 403);
  assert.equal(g.body.code, 'NOT_AUTHORISED');
  assert.equal(g.body.request, undefined);
  // Callers who could not decide on their own account (Outsider: no role;
  // the reader: read-only) send headers naming Sarah, an approver. If any
  // header became the identity, the decision would succeed as Sarah.
  for (const key of ['outsider', 'reader']) {
    const token = await signIn(key);
    const r = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED' }, { token, headers: forged });
    assert.equal(r.status, 403, `${key}: status ${r.status}`);
    assert.equal(r.body.code, 'NOT_AUTHORISED', `${key}: code ${r.body && r.body.code}`);
    assert.notEqual(r.body.ok, true);
    assert.ok(r.body.ref, `${key}: journal reference returned`);
    const row = await journalRow(r.body.ref);
    assert.equal(row.actor_uid, uid(key), `${key}: journal names the signed-in caller`);
    assert.notEqual(row.actor_uid, uid('sarah'));
    assert.equal(row.code, 'NOT_AUTHORISED');
    assert.equal(await decision(hitlId), 'PENDING', `${key}: request still PENDING`);
  }
  const h = await one('SELECT approver_id FROM public.hitl_queue WHERE hitl_id = $1', [hitlId]);
  assert.equal(h.approver_id, null);
  const aisha = await signIn('aisha');
  const d = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED' }, { token: aisha, headers: forged });
  assert.equal(d.status, 403);
  assert.equal(d.body.code, 'SOD_SELF_APPROVAL');
  assert.equal(await decision(hitlId), 'PENDING');
});

test('Aisha cannot decide her own run; the refusal is journaled with her id and session_role authenticator', async () => {
  const { hitlId } = await makeRequest('aisha');
  const aisha = await signIn('aisha');
  const r = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED' }, { token: aisha });
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'SOD_SELF_APPROVAL');
  assert.equal(r.body.message, MESSAGES.SOD_SELF_APPROVAL);
  assert.ok(r.body.ref, 'journal reference returned');
  const row = await journalRow(r.body.ref);
  assert.equal(row.actor_uid, uid('aisha'));
  assert.equal(row.session_role, 'authenticator');
  assert.equal(row.db_role, 'authenticated');
  assert.equal(row.code, 'SOD_SELF_APPROVAL');
  assert.equal(row.target_table, 'hitl_queue');
  assert.equal(await decision(hitlId), 'PENDING');
});

test('Sarah approves Aisha\'s run and the ledger names Sarah', async () => {
  const { hitlId, corr } = await makeRequest('aisha');
  const sarah = await signIn('sarah');
  const r = await rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: 'APPROVED', p_notes: 'api sod test' }, { token: sarah });
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.committed, true);
  const h = await one('SELECT approver_id, decision::text AS d FROM public.hitl_queue WHERE hitl_id = $1', [hitlId]);
  assert.equal(h.approver_id, uid('sarah'));
  assert.equal(h.d, 'APPROVED');
  const rows = await q(
    "SELECT inputs->>'event_type' AS t, inputs->>'approver_id' AS a, hitl_approver_id FROM public.shadow_ledger WHERE correlation_id = $1 AND inputs->>'event_type' IN ('HITL_RESOLVED','COMMITTED') ORDER BY ledger_id",
    [corr],
  );
  assert.deepEqual(rows.map((x) => x.t), ['HITL_RESOLVED', 'COMMITTED']);
  assert.equal(rows[0].a, uid('sarah'));
  assert.equal(rows[0].hitl_approver_id, uid('sarah'));
  assert.equal(rows[1].hitl_approver_id, uid('sarah'));
});
