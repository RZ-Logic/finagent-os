// ============================================================================
// FinAgent OS - sweeper Code nodes (fao_hitl_sweeper_v1.json)
// Controls: FAO-GOV-004 (timeouts and escalation), FAO-GOV-007 (renotify),
// FAO-GOV-008 (sweep item errors surface as a failed node).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runCodeNode } from './harness.mjs';

const WF = 'fao_hitl_sweeper_v1.json';

function sweepResult(over = {}) {
  return {
    ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null,
    expired_runs: [], failed_runs: [], expired_requests: [], escalations: [], renotify: [], item_errors: [],
    grants_drift: false, clock_offset_seconds: 0,
    ...over,
  };
}

const key = (o) => `${o.kind}:${o.level}:${o.hitl_id}`;

test('Expand Notifications emits one item per escalation and per renotify entry', async () => {
  const r = sweepResult({
    escalations: [{ hitl_id: 1, level: 1, reason: 'TIMEOUT' }, { hitl_id: 2, level: 1, reason: 'NOTIFICATION_FAILED' }],
    renotify: [{ hitl_id: 3, attempt: 2 }, { hitl_id: 4, attempt: 3 }],
  });
  const out = await runCodeNode(WF, 'Expand Notifications', { items: [{ r }], upstream: { 'Run Sweep': [{ r }] } });
  assert.equal(out.length, 4);
  const expected = [
    { hitl_id: 1, kind: 'ESCALATED', level: 1 },
    { hitl_id: 2, kind: 'ESCALATED', level: 1 },
    { hitl_id: 3, kind: 'REQUESTED', level: 0 },
    { hitl_id: 4, kind: 'REQUESTED', level: 0 },
  ];
  assert.deepEqual([...out].sort((a, b) => key(a).localeCompare(key(b))), [...expected].sort((a, b) => key(a).localeCompare(key(b))));
});

test('Expand Notifications emits nothing for empty lists', async () => {
  const r = sweepResult();
  const out = await runCodeNode(WF, 'Expand Notifications', { items: [{ r }], upstream: { 'Run Sweep': [{ r }] } });
  assert.deepEqual(out, []);
});

test('Check Sweep Errors throws listing each item_errors entry', async () => {
  const r = sweepResult({
    item_errors: [
      { step: 'expire_request', id: '15', sqlstate: 'NO_RUN_RECORD' },
      { step: 'renotify', id: '16', sqlstate: 'P0001' },
    ],
  });
  await assert.rejects(
    runCodeNode(WF, 'Check Sweep Errors', { items: [{ r }], upstream: { 'Run Sweep': [{ r }] } }),
    (err) => {
      assert.match(err.message, /^FAO-GOV-008 sweep: 2 item errors: /);
      assert.ok(err.message.includes('expire_request:15:NO_RUN_RECORD'));
      assert.ok(err.message.includes('renotify:16:P0001'));
      return true;
    },
  );
});

test('Check Sweep Errors passes on an empty list', async () => {
  const r = sweepResult({ escalations: [{ hitl_id: 1, level: 1, reason: 'TIMEOUT' }] });
  await assert.doesNotReject(runCodeNode(WF, 'Check Sweep Errors', { items: [{ r }], upstream: { 'Run Sweep': [{ r }] } }));
  await assert.doesNotReject(runCodeNode(WF, 'Check Sweep Errors', { items: [], upstream: { 'Run Sweep': [{ r: sweepResult() }] } }));
});
