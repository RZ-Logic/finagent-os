// ============================================================================
// FinAgent OS API tests: the full governed path without n8n
// Controls: FAO-GOV-008 (start, claim), FAO-GOV-001 (batch append, ordered
// chain), FAO-GOV-004 (request, decision by a different approver),
// FAO-REC-001 (rollup), FAO-GOV-015 (reader sees the summary).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  startRun, claim, append, finalize, startedEvent, flagshipEvents, rpc, rest, signIn, one, ledgerTypes, uid, closeAll,
} from './lib.mjs';

after(closeAll);

test('start, claim, append, finalize, review and approve, in one correlation', async () => {
  const s = await startRun('aisha', { reason: 'api flow test' });
  assert.equal(s.status, 200);
  const corr = s.body.correlation_id;

  const c = await claim(s.body.run_token);
  assert.equal(c.ok, true, `claim: ${c.code}`);
  assert.equal(c.correlation_id, corr);
  assert.equal(c.invoker_id, uid('aisha'));

  const { assets, events } = flagshipEvents(corr);
  const a1 = await append([startedEvent(corr, assets)]);
  assert.equal(a1.count, 1);
  const a2 = await append(events);
  assert.equal(a2.count, 7);

  const f = await finalize(corr);
  assert.equal(f.hitl_required, true);
  assert.equal(f.state, 'AWAITING_HITL');
  const hitlId = String(f.hitl_id);

  const sarah = await signIn('sarah');
  const g = await rpc('fao_hitl_get', { p_hitl_id: hitlId }, { token: sarah });
  assert.equal(g.status, 200);
  assert.equal(g.body.request.viewer_can_decide, true);
  assert.equal(g.body.request.viewer_is_invoker, false);
  assert.equal(g.body.request.configured_approvals, 2);
  assert.equal(g.body.request.enforced_approvals, 1);

  const rowBefore = await one('SELECT to_jsonb(h) AS h FROM public.hitl_queue h WHERE hitl_id = $1', [hitlId]);
  const ledgerBefore = await ledgerTypes(corr);
  const g2 = await rpc('fao_hitl_get', { p_hitl_id: hitlId }, { token: sarah });
  const g3 = await rpc('fao_hitl_get', { p_hitl_id: hitlId }, { token: sarah });
  assert.equal(g2.status, 200);
  assert.deepEqual(g3.body.request, g2.body.request);
  assert.deepEqual((await one('SELECT to_jsonb(h) AS h FROM public.hitl_queue h WHERE hitl_id = $1', [hitlId])).h, rowBefore.h, 'repeated reads leave the row unchanged');
  assert.deepEqual(await ledgerTypes(corr), ledgerBefore, 'repeated reads leave the ledger unchanged');

  const d = await rpc('fao_hitl_decide', { p_hitl_id: hitlId, p_decision: 'APPROVED', p_notes: 'api flow approval' }, { token: sarah });
  assert.equal(d.status, 200);
  assert.equal(d.body.committed, true);

  assert.deepEqual(await ledgerTypes(corr), [
    'STARTED',
    ...Array(7).fill('ASSET_RECONCILED'),
    'HITL_REQUESTED', 'HITL_RESOLVED', 'COMMITTED',
  ]);
  const ids = await one('SELECT count(DISTINCT correlation_id) AS n, count(DISTINCT execution_id) AS e FROM public.shadow_ledger WHERE correlation_id = $1', [corr]);
  assert.equal(Number(ids.n), 1);
  assert.equal(Number(ids.e), 1);

  const again = await rpc('fao_hitl_decide', { p_hitl_id: hitlId, p_decision: 'REJECTED' }, { token: sarah });
  assert.equal(again.status, 410);
  assert.equal(again.body.code, 'ALREADY_DECIDED');

  const reader = await signIn('reader');
  const sum = await rest('GET', 'fao_run_summary', { token: reader, query: `?correlation_id=eq.${corr}` });
  assert.equal(sum.status, 200);
  assert.equal(sum.body.length, 1);
  assert.equal(sum.body[0].hitl_decision, 'APPROVED');
  assert.equal(sum.body[0].latest_committed_status, 'SUCCESS');
  assert.equal(sum.body[0].run_state, 'COMMITTED');
  assert.equal(sum.body[0].approver_id, uid('sarah'));
  assert.equal(sum.body[0].invoker_id, uid('aisha'));
  assert.equal(sum.body[0].has_run_record, true);
});
