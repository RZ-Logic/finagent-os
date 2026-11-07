// ============================================================================
// FinAgent OS - sweeper Code nodes (fao_hitl_sweeper_v1.json)
// Controls: FAO-GOV-004 (timeouts and escalation), FAO-GOV-007 (renotify,
// notifier call failures surface), FAO-GOV-008 (sweep item errors surface as
// a failed node). Fix round 3: both kinds of failure surface in one
// execution, proven on the export's own branch order (executionOrder v1).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runCodeNode, readJson } from './harness.mjs';
import { RULES } from '../../scripts/check-exports.mjs';

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
      assert.ok(!err.message.includes('FAO-GOV-007'), 'no notices listed, so no notifier part');
      return true;
    },
  );
});

test('Check Sweep Errors passes on an empty list once the listed notices all have results', async () => {
  const r = sweepResult({ escalations: [{ hitl_id: 1, level: 1, reason: 'TIMEOUT' }] });
  const summary = { notifier_calls: 1, notifier_failures: 0, failures: [] };
  const out = await runCodeNode(WF, 'Check Sweep Errors', { items: [{ r }], upstream: { 'Run Sweep': [{ r }], 'Check Notifier Results': [summary] } });
  assert.deepEqual(out, [{ item_errors: 0, notifier_calls: 1, notifier_failures: 0, grants_drift: false, clock_offset_seconds: 0 }]);
  await assert.doesNotReject(runCodeNode(WF, 'Check Sweep Errors', { items: [], upstream: { 'Run Sweep': [{ r: sweepResult() }] } }));
});

test('Check Sweep Errors fails closed when notices were listed but no notifier results can be read', async () => {
  const r = sweepResult({ escalations: [{ hitl_id: 1, level: 1, reason: 'TIMEOUT' }], renotify: [{ hitl_id: 3, attempt: 2 }] });
  // No 'Check Notifier Results' upstream: $() throws, as n8n does for a node
  // that has not run (for example if the branch order were ever reversed).
  await assert.rejects(
    runCodeNode(WF, 'Check Sweep Errors', { items: [{ r }], upstream: { 'Run Sweep': [{ r }] } }),
    (err) => { assert.equal(err.message, 'FAO-GOV-007 sweep: 1 notifier failures: missing (2 notices listed, no notifier results read)'); return true; },
  );
  // A summary covering fewer calls than listed is a failure too.
  await assert.rejects(
    runCodeNode(WF, 'Check Sweep Errors', {
      items: [{ r }],
      upstream: { 'Run Sweep': [{ r }], 'Check Notifier Results': [{ notifier_calls: 1, notifier_failures: 0, failures: [] }] },
    }),
    (err) => { assert.equal(err.message, 'FAO-GOV-007 sweep: 1 notifier failures: missing (1 of 2 notices have no notifier result)'); return true; },
  );
});

// --- Check Notifier Results (FAO-GOV-007) -------------------------------------

const EXPANDED = [
  { hitl_id: 1, kind: 'ESCALATED', level: 1 },
  { hitl_id: 3, kind: 'REQUESTED', level: 0 },
  { hitl_id: 4, kind: 'REQUESTED', level: 0 },
];
const okResult = { r: { ok: true, code: 'OK', attempt: 1, notification_id: 9 } };
const R3 = sweepResult({ escalations: [{ hitl_id: 1, level: 1, reason: 'TIMEOUT' }], renotify: [{ hitl_id: 3, attempt: 2 }, { hitl_id: 4, attempt: 2 }] });

test('Check Notifier Results lists each failed call without stopping the execution; Check Sweep Errors throws naming each', async () => {
  // HITL Gateway output, item i paired with Expand Notifications item i:
  // call 0 and 2 failed (continueRegularOutput gives {error}), call 1 recorded.
  const items = [
    { error: 'Workflow is not active and cannot be executed.' },
    okResult,
    { error: 'invalid input syntax for type bigint' },
  ];
  const out = await runCodeNode(WF, 'Check Notifier Results', { items, upstream: { 'Expand Notifications': EXPANDED } });
  assert.equal(out.length, 1);
  assert.equal(out[0].notifier_calls, 3);
  assert.equal(out[0].notifier_failures, 2);
  assert.deepEqual(out[0].failures, [
    '1:ESCALATED:1 (Workflow is not active and cannot be executed.)',
    '4:REQUESTED:0 (invalid input syntax for type bigint)',
  ]);
  await assert.rejects(
    runCodeNode(WF, 'Check Sweep Errors', { items: [{ r: R3 }], upstream: { 'Run Sweep': [{ r: R3 }], 'Check Notifier Results': out } }),
    (err) => {
      assert.match(err.message, /^FAO-GOV-007 sweep: 2 notifier failures: /);
      assert.ok(err.message.includes('1:ESCALATED:1 (Workflow is not active'), err.message);
      assert.ok(err.message.includes('4:REQUESTED:0 (invalid input syntax'), err.message);
      assert.ok(!err.message.includes('3:REQUESTED:0'), 'the recorded call is not listed');
      assert.ok(!err.message.includes('FAO-GOV-008'), 'no item errors, so no sweep part');
      return true;
    },
  );
});

test('Check Notifier Results reports no failures when every call returned a result, including send:false', async () => {
  const items = [okResult, { r: { ok: true, send: false, code: 'NOT_PENDING' } }, okResult];
  const out = await runCodeNode(WF, 'Check Notifier Results', { items, upstream: { 'Expand Notifications': EXPANDED } });
  assert.deepEqual(out, [{ notifier_calls: 3, notifier_failures: 0, failures: [] }]);
  await assert.doesNotReject(runCodeNode(WF, 'Check Sweep Errors', { items: [{ r: R3 }], upstream: { 'Run Sweep': [{ r: R3 }], 'Check Notifier Results': out } }));
});

test('Check Notifier Results still counts a failure it cannot pair', async () => {
  const out = await runCodeNode(WF, 'Check Notifier Results', { items: [{ error: { message: 'boom' } }], upstream: { 'Expand Notifications': [] } });
  assert.deepEqual(out, [{ notifier_calls: 1, notifier_failures: 1, failures: ['unknown (boom)'] }]);
  const r = sweepResult({ renotify: [{ hitl_id: 9, attempt: 2 }] });
  await assert.rejects(
    runCodeNode(WF, 'Check Sweep Errors', { items: [{ r }], upstream: { 'Run Sweep': [{ r }], 'Check Notifier Results': out } }),
    /FAO-GOV-007 sweep: 1 notifier failures: unknown \(boom\)$/,
  );
});

// --- The whole export, in n8n's v1 branch order ------------------------------
// runExport walks the exported workflow the way n8n runs executionOrder v1:
// depth first from the trigger; a node's children (one output) run one
// branch at a time, each branch completed before the next, ordered by canvas
// position (top first, then left); a node that outputs no items ends its
// branch; the first throw ends the execution. Code nodes run as exported
// (harness); Run Sweep and HITL Gateway are stubs. $() serves only nodes that
// have run so far, as n8n does.

async function runExport({ sweep, notifier, wf = readJson(`workflows/${WF}`) }) {
  assert.equal((wf.settings || {}).executionOrder, 'v1', 'the export runs with executionOrder v1');
  const byName = new Map(wf.nodes.map((n) => [n.name, n]));
  const ran = {};
  const order = [];
  const calls = [];
  const stubs = {
    'Schedule Trigger': () => [{}],
    'Run Sweep': () => [{ r: sweep }],
    // Execute Workflow, mode each, onError continueRegularOutput: one result
    // per input item, an {error} item when the call failed.
    'HITL Gateway': (items) => items.map((it) => {
      calls.push(it);
      const res = notifier(it);
      return res instanceof Error ? { error: res.message } : res;
    }),
  };
  const children = (name) => {
    const out = ((((wf.connections || {})[name] || {}).main || [])[0] || []).map((c) => c.node);
    return out.map((n) => byName.get(n)).sort((a, b) => (a.position[1] - b.position[1]) || (a.position[0] - b.position[0])).map((n) => n.name);
  };
  async function exec(name, items) {
    const node = byName.get(name);
    order.push(name);
    let out;
    if (node.type === 'n8n-nodes-base.code') {
      out = await runCodeNode(WF, name, { items, upstream: { ...ran } });
    } else if (stubs[name]) {
      out = stubs[name](items);
    } else {
      throw new Error(`runExport: no stub for ${node.type} "${name}"`);
    }
    ran[name] = out;
    if (out.length === 0) return;
    for (const child of children(name)) await exec(child, out);
  }
  let error = null;
  try {
    await exec('Schedule Trigger', []);
  } catch (e) {
    error = e;
  }
  return { error, order, calls, ran };
}

test('v1 order: a failed notifier call and sweep item_errors in the same sweep both surface, after every notice was attempted', async () => {
  const sweep = sweepResult({
    escalations: [{ hitl_id: 21, level: 1, reason: 'TIMEOUT' }],
    renotify: [{ hitl_id: 22, attempt: 2 }, { hitl_id: 23, attempt: 2 }],
    item_errors: [{ step: 'expire_request', id: '21', sqlstate: 'NO_ESCALATION_TARGET' }],
  });
  const res = await runExport({
    sweep,
    notifier: (it) => (it.hitl_id === 21 ? new Error('Workflow is not active and cannot be executed.') : okResult),
  });
  assert.deepEqual(res.order, ['Schedule Trigger', 'Run Sweep', 'Expand Notifications', 'HITL Gateway', 'Check Notifier Results', 'Check Sweep Errors']);
  assert.deepEqual(res.calls.map(key).sort(), ['ESCALATED:1:21', 'REQUESTED:0:22', 'REQUESTED:0:23'], 'every listed notice was attempted');
  assert.ok(res.error, 'the execution fails');
  assert.equal(res.error.message,
    'FAO-GOV-007 sweep: 1 notifier failures: 21:ESCALATED:1 (Workflow is not active and cannot be executed.); '
    + 'FAO-GOV-008 sweep: 1 item errors: expire_request:21:NO_ESCALATION_TARGET');
});

test('v1 order: sweep item_errors alone, with nothing due, still fail the execution', async () => {
  const sweep = sweepResult({ item_errors: [{ step: 'fail_run', id: 'c0ffee', sqlstate: '42501' }] });
  const res = await runExport({ sweep, notifier: () => { throw new Error('not called'); } });
  assert.deepEqual(res.order, ['Schedule Trigger', 'Run Sweep', 'Expand Notifications', 'Check Sweep Errors']);
  assert.equal(res.calls.length, 0);
  assert.equal(res.error && res.error.message, 'FAO-GOV-008 sweep: 1 item errors: fail_run:c0ffee:42501');
});

test('v1 order: notifier failures alone fail the execution; a clean sweep passes', async () => {
  const sweep = sweepResult({ renotify: [{ hitl_id: 31, attempt: 2 }, { hitl_id: 32, attempt: 2 }] });
  const failing = await runExport({ sweep, notifier: (it) => (it.hitl_id === 32 ? new Error('boom') : okResult) });
  assert.equal(failing.calls.length, 2);
  assert.equal(failing.error && failing.error.message, 'FAO-GOV-007 sweep: 1 notifier failures: 32:REQUESTED:0 (boom)');
  const clean = await runExport({ sweep, notifier: () => okResult });
  assert.equal(clean.error, null);
  assert.deepEqual(clean.ran['Check Sweep Errors'], [{ item_errors: 0, notifier_calls: 2, notifier_failures: 0, grants_drift: false, clock_offset_seconds: 0 }]);
  const idle = await runExport({ sweep: sweepResult(), notifier: () => okResult });
  assert.equal(idle.error, null);
  assert.deepEqual(idle.order, ['Schedule Trigger', 'Run Sweep', 'Expand Notifications', 'Check Sweep Errors']);
});

test('v1 order: with the final check moved above the notifier branch, a sweep with notices fails closed', async () => {
  const wf = readJson(`workflows/${WF}`);
  wf.nodes.find((n) => n.name === 'Check Sweep Errors').position = [440, 100];
  const sweep = sweepResult({ renotify: [{ hitl_id: 41, attempt: 2 }] });
  const res = await runExport({ wf, sweep, notifier: () => okResult });
  assert.deepEqual(res.order, ['Schedule Trigger', 'Run Sweep', 'Check Sweep Errors']);
  assert.match(res.error && res.error.message, /^FAO-GOV-007 sweep: 1 notifier failures: missing \(1 notices listed, no notifier results read\)$/);
  // and check-exports refuses that layout
  const rule = RULES.find((r) => r.id === 'section4_nodes');
  assert.ok(rule.run({ file: WF, wf }).some((v) => /Check Sweep Errors must sit below Expand Notifications/.test(v)));
});

test('check-exports holds the sweeper order: v1, both branches from Run Sweep, only Check Sweep Errors throws', () => {
  const rule = RULES.find((r) => r.id === 'section4_nodes');
  const base = readJson(`workflows/${WF}`);
  assert.deepEqual(rule.run({ file: WF, wf: base }), []);
  const mutate = (fn) => { const wf = structuredClone(base); fn(wf); return rule.run({ file: WF, wf }); };
  assert.ok(mutate((wf) => { wf.settings.executionOrder = 'v0'; }).some((v) => /executionOrder is not v1/.test(v)));
  assert.ok(mutate((wf) => { wf.nodes.find((n) => n.name === 'Expand Notifications').position = [440, 460]; wf.nodes.find((n) => n.name === 'Check Sweep Errors').position = [300, 460]; })
    .some((v) => /must sit below Expand Notifications/.test(v)));
  assert.ok(mutate((wf) => { wf.connections['Run Sweep'].main[0].pop(); }).some((v) => /Run Sweep output 0 must lead to exactly/.test(v)));
  assert.ok(mutate((wf) => { wf.nodes.find((n) => n.name === 'Check Notifier Results').parameters.jsCode += '\nif (failures.length) throw new Error(\'x\');'; })
    .some((v) => /Code node "Check Notifier Results" throws/.test(v)));
  assert.ok(mutate((wf) => { wf.nodes.find((n) => n.name === 'Expand Notifications').parameters.jsCode += '\nthrow new Error(\'x\');'; })
    .some((v) => /Code node "Expand Notifications" throws/.test(v)));
});
