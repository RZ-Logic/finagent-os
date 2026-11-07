// ============================================================================
// FinAgent OS API tests: HTTP statuses and committed refusals
// Controls: FAO-GOV-004 (decision outcomes with fixed codes and messages),
// FAO-GOV-001 (the journal row of a 4xx response is committed).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { rpc, signIn, makeRequest, journalRow, owner, closeAll, MESSAGES } from './lib.mjs';

after(closeAll);

async function expectEnvelope(r, status, code, { journaled } = {}) {
  assert.equal(r.status, status, `status for ${code}`);
  assert.ok(r.body && typeof r.body === 'object', `envelope for ${code}`);
  assert.equal(r.body.code, code);
  assert.equal(r.body.message, MESSAGES[code]);
  assert.equal(r.body.http_status, status);
  if (journaled) {
    assert.ok(r.body.ref, `${code}: journal reference returned`);
    const row = await journalRow(r.body.ref);
    assert.ok(row, `${code}: journal row is readable after the response (committed)`);
    assert.equal(row.code, code);
  }
}

test('fao_hitl_get statuses 200, 400, 401, 403, 404, 410', async () => {
  const pending = await makeRequest('aisha');
  const decided = await makeRequest('aisha');
  const sarah = await signIn('sarah');
  const outsider = await signIn('outsider');
  await rpc('fao_hitl_decide', { p_hitl_id: String(decided.hitlId), p_decision: 'APPROVED' }, { token: sarah });

  const ok = await rpc('fao_hitl_get', { p_hitl_id: String(pending.hitlId) }, { token: sarah });
  await expectEnvelope(ok, 200, 'OK');
  assert.equal(ok.body.request.hitl_id, pending.hitlId);
  await expectEnvelope(await rpc('fao_hitl_get', { p_hitl_id: 'abc' }, { token: sarah }), 400, 'INVALID_INPUT', { journaled: true });
  const anon = await rpc('fao_hitl_get', { p_hitl_id: String(pending.hitlId) });
  assert.equal(anon.status, 401, 'anonymous fao_hitl_get is 401');
  assert.equal(anon.body && anon.body.request, undefined);
  await expectEnvelope(await rpc('fao_hitl_get', { p_hitl_id: String(pending.hitlId) }, { token: outsider }), 403, 'NOT_AUTHORISED', { journaled: true });
  await expectEnvelope(await rpc('fao_hitl_get', { p_hitl_id: '999999999' }, { token: sarah }), 404, 'NOT_FOUND');
  const gone = await rpc('fao_hitl_get', { p_hitl_id: String(decided.hitlId) }, { token: sarah });
  await expectEnvelope(gone, 410, 'ALREADY_DECIDED');
  assert.deepEqual(Object.keys(gone.body.request).sort(), ['decided_at', 'decision', 'hitl_id']);
});

test('fao_hitl_decide statuses 200, 400, 401, 403, 404, 409, 410', async () => {
  const a = await makeRequest('aisha');
  const b = await makeRequest('aisha');
  const sarah = await signIn('sarah');
  const aisha = await signIn('aisha');

  await expectEnvelope(await rpc('fao_hitl_decide', { p_hitl_id: 'abc', p_decision: 'APPROVED' }, { token: sarah }), 400, 'INVALID_INPUT', { journaled: true });
  await expectEnvelope(await rpc('fao_hitl_decide', { p_hitl_id: String(a.hitlId), p_decision: 'APPROVED' }), 401, 'NO_SESSION', { journaled: true });
  await expectEnvelope(await rpc('fao_hitl_decide', { p_hitl_id: String(a.hitlId), p_decision: 'APPROVED' }, { token: aisha }), 403, 'SOD_SELF_APPROVAL', { journaled: true });
  await expectEnvelope(await rpc('fao_hitl_decide', { p_hitl_id: '999999999', p_decision: 'APPROVED' }, { token: sarah }), 404, 'NOT_FOUND', { journaled: true });

  // BUSY while another session holds the row lock
  const client = await owner().connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT 1 FROM public.hitl_queue WHERE hitl_id = $1 FOR UPDATE', [b.hitlId]);
    await expectEnvelope(await rpc('fao_hitl_decide', { p_hitl_id: String(b.hitlId), p_decision: 'APPROVED' }, { token: sarah }), 409, 'BUSY', { journaled: true });
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }

  const done = await rpc('fao_hitl_decide', { p_hitl_id: String(a.hitlId), p_decision: 'APPROVED' }, { token: sarah });
  await expectEnvelope(done, 200, 'OK');
  assert.equal(done.body.committed, true);
  await expectEnvelope(await rpc('fao_hitl_decide', { p_hitl_id: String(a.hitlId), p_decision: 'REJECTED' }, { token: sarah }), 410, 'ALREADY_DECIDED', { journaled: true });
  const afterBusy = await rpc('fao_hitl_decide', { p_hitl_id: String(b.hitlId), p_decision: 'REJECTED' }, { token: sarah });
  await expectEnvelope(afterBusy, 200, 'OK');
});
