// ============================================================================
// FinAgent OS - error handler Code node (fao_error_handler_v1.json)
// Controls: FAO-GOV-008 (every failed flagship, notifier or sweeper execution
// is recorded through the 4-argument fao_run_fail with a bounded,
// control-character-free node name and message, and a source chosen from a
// fixed map: round 5, F-20, contract K1, settled detail D4).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { runCodeNode, nodeOf, WORKFLOWS } from './harness.mjs';
import { RULES, ERROR_SOURCES, upstreamOf, downstreamOf, preClaimNodesOf, checkErrorHandler } from '../../scripts/check-exports.mjs';

const WF = 'fao_error_handler_v1.json';
const FLAGSHIP = 'uhB2KjEaJDuviM4D';
const GATEWAY = 'mUAC9qIMkVzlV5qw';
const SWEEPER = 'FaoSweeperV1x001';
const readWf = (f) => JSON.parse(readFileSync(join(WORKFLOWS, f), 'utf8'));

// The field names Record Run Failure passes as $1 to $4, read from its
// queryReplacement expression so the test follows the exported wiring.
function recordFields() {
  const n = nodeOf(WF, 'Record Run Failure');
  const qr = String((n && n.parameters && n.parameters.options && n.parameters.options.queryReplacement) || '');
  const names = [...qr.matchAll(/\$json(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[\s*['"]([^'"]+)['"]\s*\])/g)].map((m) => m[1] || m[2]);
  return names.length === 4 ? names : null;
}

function errorItem(message, lastNode = 'Per-Asset Reconcile', id = '4711', workflowId = FLAGSHIP) {
  return {
    execution: {
      id,
      url: 'http://localhost:5678/execution/4711',
      retryOf: null,
      mode: 'webhook',
      lastNodeExecuted: lastNode,
      error: { message, stack: `Error: ${message}\n    at somewhere` },
    },
    workflow: { id: workflowId, name: 'some workflow' },
  };
}

async function extract(item, file = WF) {
  const out = await runCodeNode(file, 'Extract Failure', { items: [item], upstream: { 'Error Trigger': [item] } });
  assert.equal(out.length, 1);
  return out[0];
}

function values(o) {
  const fields = recordFields();
  assert.ok(fields, 'queryReplacement names four $json fields');
  return { fields, id: o[fields[0]], node: o[fields[1]], message: o[fields[2]], source: o[fields[3]] };
}

test('Record Run Failure calls the 4-argument fao_run_fail with id, node, message, source', () => {
  const n = nodeOf(WF, 'Record Run Failure');
  assert.equal(n.parameters.query, 'SELECT public.fao_run_fail($1, $2, $3, $4) AS r;');
  assert.deepEqual(recordFields(), ['n8n_execution_id', 'failed_node', 'message', 'source']);
  const wf = readWf(WF);
  assert.equal(wf.connections['Record Run Failure'], undefined, 'Record Run Failure is the last node');
});

test('Extract Failure passes the execution id, the last node and the source', async () => {
  const v = values(await extract(errorItem('boom')));
  assert.equal(String(v.id), '4711');
  assert.equal(v.node, 'Per-Asset Reconcile');
  assert.equal(v.message, 'boom');
  assert.equal(v.source, 'flagship');
});

test('Extract Failure strips control characters from the message and the node name', async () => {
  const msg = 'line1\nline2\r\u0000nul\u0007bell\ttab\u001bend\u007f';
  const v = values(await extract(errorItem(msg, 'Per-Asset\nReconcile\u0000')));
  assert.equal(typeof v.message, 'string');
  assert.ok(!/[\u0000-\u001f\u007f]/.test(v.message), `control characters remain: ${JSON.stringify(v.message)}`);
  for (const part of ['line1', 'line2', 'nul', 'bell', 'tab', 'end']) assert.ok(v.message.includes(part), `keeps ${part}`);
  assert.equal(v.node, 'Per-Asset Reconcile ');
});

test('Extract Failure cuts the message to 500 and the node name to 200 characters', async () => {
  const msg = 'FAO-GOV-001 ' + 'y'.repeat(2000);
  const v = values(await extract(errorItem(msg, 'N'.repeat(900))));
  assert.ok(v.message.length <= 500, `length ${v.message.length}`);
  assert.ok(v.message.length >= 450, 'keeps the start of the message');
  assert.ok(v.message.startsWith('FAO-GOV-001 yyy'));
  assert.equal(v.node.length, 200);
});

// --- source (K1, D4) ---------------------------------------------------------

test('the source map in Extract Failure equals the exports that name the handler', () => {
  const want = {};
  for (const [file, src] of Object.entries(ERROR_SOURCES)) {
    const wf = readWf(file);
    assert.equal(wf.settings.errorWorkflow, 'FaoErrHandlerV01', `${file} names the error handler`);
    want[wf.id] = src;
  }
  assert.deepEqual(want, { [FLAGSHIP]: 'flagship', [GATEWAY]: 'gateway', [SWEEPER]: 'sweeper' });
  const code = nodeOf(WF, 'Extract Failure').parameters.jsCode;
  for (const [id, src] of Object.entries(want)) {
    const line = `  '${id}': '${src}',`;
    assert.equal(code.split('\n').filter((l) => l === line).length, 1, `exactly one line ${line}`);
    assert.equal(code.split(`'${id}': '${src}'`).length - 1, 1, `the entry for ${id} appears once`);
  }
});

test('every flagship node maps to flagship_pre_claim exactly when it is not Respond 202 and not downstream of it', async () => {
  // Round 6, P1 (red team r5 item 1): Claim Run and the refused and
  // bad-input branches never hold a claimed run, so they are pre-claim too.
  const flagship = readWf('fao_reserve_recon_v1.json');
  const pre = new Set(preClaimNodesOf(flagship));
  assert.deepEqual([...pre].sort(), [
    'Body Valid?', 'Claim OK?', 'Claim Run', 'Respond 400', 'Respond Claim Refused', 'Validate Invoke Body', 'Webhook: Invoke',
  ]);
  // The set is the complement of Respond 202 and its downstream nodes, and
  // it covers everything upstream of Claim Run.
  const after = new Set(['Respond 202', ...downstreamOf(flagship, 'Respond 202')]);
  for (const n of flagship.nodes) {
    if (n.type === 'n8n-nodes-base.stickyNote') continue;
    assert.equal(pre.has(n.name), !after.has(n.name), n.name);
  }
  for (const u of upstreamOf(flagship, 'Claim Run')) assert.ok(pre.has(u), u);
  for (const n of ['Respond 202', 'Init Execution', 'Finalize Run', 'HITL Gateway']) assert.ok(!pre.has(n), n);
  for (const n of flagship.nodes) {
    if (n.type === 'n8n-nodes-base.stickyNote') continue;
    const v = values(await extract(errorItem('x', n.name)));
    assert.equal(v.source, pre.has(n.name) ? 'flagship_pre_claim' : 'flagship', n.name);
  }
  for (const odd of ['', 'webhook: invoke', 'Body Valid', 'Claim Run ', 'respond 400', 'Respond Claim Refused ']) {
    assert.equal(values(await extract(errorItem('x', odd))).source, 'flagship', JSON.stringify(odd));
  }
  const noLast = errorItem('x');
  delete noLast.execution.lastNodeExecuted;
  assert.equal(values(await extract(noLast)).source, 'flagship');
});

test('a notifier or sweeper failure maps to its own source whatever the node name', async () => {
  for (const [wfId, src, nodes] of [
    [GATEWAY, 'gateway', ['Get Notification Context', 'Record Notification', 'Validate Invoke Body', 'Webhook: Invoke']],
    [SWEEPER, 'sweeper', ['Run Sweep', 'Check Sweep Errors', 'Body Valid?']],
  ]) {
    for (const nodeName of nodes) {
      const v = values(await extract(errorItem('boom', nodeName, '90', wfId)));
      assert.equal(v.source, src, `${src} ${nodeName}`);
      assert.equal(String(v.id), '90');
    }
  }
});

test('Extract Failure refuses loudly a workflow outside the map and a payload without a workflow or execution id', async () => {
  const cases = [
    [errorItem('x', 'Run Sweep', '9', 'dQslIEVwF3WqMliT'), /workflow dQslIEVwF3WqMliT is not in the error handler source map; nothing was recorded/],
    [errorItem('x', 'A', '9', 'FaoErrHandlerV01'), /workflow FaoErrHandlerV01 is not in the error handler source map/],
    [errorItem('x', 'A', '9', 'uhb2kjeaJDuviM4D'), /not in the error handler source map/],
    [errorItem('x', 'A', '9', '<!channel> flagship'), /workflow unknown is not in the error handler source map/],
    [errorItem('x', 'A', '9', 'toString'), /workflow toString is not in the error handler source map/],
    [errorItem('x', 'A', '9', '__proto__'), /workflow unknown is not in the error handler source map/],
    [{ execution: { id: '9', lastNodeExecuted: 'A', error: { message: 'x' } } }, /workflow unknown is not in the error handler source map/],
    [{ execution: { lastNodeExecuted: 'A', error: { message: 'x' } }, workflow: { id: FLAGSHIP } }, /has no execution id/],
    [{ trigger: { error: { message: 'trigger failed' } }, workflow: { id: GATEWAY } }, /has no execution id/],
  ];
  for (const [item, re] of cases) {
    await assert.rejects(extract(item), (e) => {
      assert.match(e.message, re, JSON.stringify(item));
      assert.ok(e.message.startsWith('FAO-GOV-008 error handler: '));
      return true;
    });
  }
});

test('an e2e copy patched in next to its entry, as test/e2e/variants.mjs does, maps to that source', async () => {
  // D4: the e2e layer adds its variant ids by rewriting the export's entry
  // lines. Applied here to a temporary copy of the export.
  const wf = readWf(WF);
  const n = wf.nodes.find((x) => x.name === 'Extract Failure');
  const add = (code, entry, extra) => {
    assert.equal(code.split(entry).length - 1, 1, `${entry} matches once`);
    return code.replace(entry, `${entry}\n  '${extra}': '${entry.split("'")[3]}',`);
  };
  n.parameters.jsCode = add(add(n.parameters.jsCode, `  '${FLAGSHIP}': 'flagship',`, 'FaoE2eReconInbd1'), `  '${SWEEPER}': 'sweeper',`, 'FaoE2eSweepHook1');
  const dir = mkdtempSync(join(tmpdir(), 'fao-eh-'));
  try {
    const file = join(dir, 'fao_error_handler_e2e_patch_probe.json');
    writeFileSync(file, JSON.stringify(wf, null, 2));
    assert.equal(values(await extract(errorItem('x', 'Init Execution', '5', 'FaoE2eReconInbd1'), file)).source, 'flagship');
    assert.equal(values(await extract(errorItem('x', 'Body Valid?', '5', 'FaoE2eReconInbd1'), file)).source, 'flagship_pre_claim');
    assert.equal(values(await extract(errorItem('x', 'Run Sweep', '5', 'FaoE2eSweepHook1'), file)).source, 'sweeper');
    // The patched copy is not an export: the export rule refuses it.
    assert.ok(checkErrorHandler(wf, null).some((v) => /FaoE2eReconInbd1, which is not an export/.test(v)));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// --- check-exports: error_handler_map and error_workflow ---------------------

test('check-exports error_handler_map refuses a wrong map, a wrong pre-claim list and the 3-argument call', () => {
  const rule = RULES.find((r) => r.id === 'error_handler_map');
  assert.ok(rule, 'rule exists');
  const all = ['fao_reserve_recon_v1.json', 'fao_hitl_gateway_v1.json', 'fao_hitl_sweeper_v1.json', 'writer.json', WF].map(readWf);
  const exportedById = new Map(all.map((w) => [w.id, w]));
  const base = readWf(WF);
  const run = (mutate, byId = exportedById) => {
    const wf = structuredClone(base);
    mutate(wf, wf.nodes.find((x) => x.name === 'Extract Failure'), wf.nodes.find((x) => x.name === 'Record Run Failure'));
    return rule.run({ file: WF, wf, exportedById: byId });
  };
  const has = (out, re) => assert.ok(out.some((v) => re.test(v)), out.join('; '));
  assert.deepEqual(run(() => {}), [], 'the export passes');
  assert.deepEqual(rule.run({ file: 'writer.json', wf: readWf('writer.json'), exportedById }), [], 'other files are not checked');

  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace(`'${GATEWAY}': 'gateway'`, `'${GATEWAY}': 'sweeper'`); }), /gives mUAC9qIMkVzlV5qw sweeper, expected gateway/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace(`  '${SWEEPER}': 'sweeper',\n`, ''); }), /gives FaoSweeperV1x001 \(nothing\), expected sweeper/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace(`  '${SWEEPER}': 'sweeper',`, `  '${SWEEPER}': 'sweeper',\n  'dQslIEVwF3WqMliT': 'flagship',`); }), /lists dQslIEVwF3WqMliT, which is not an export/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace(`  '${FLAGSHIP}': 'flagship',`, `  "${FLAGSHIP}": "flagship",`); }), /is not written '<id>': '<source>',/);
  has(run((wf, e) => { e.parameters.jsCode = `// '${FLAGSHIP}': 'flagship'\n${e.parameters.jsCode}`; }), /appears 2 times in Extract Failure/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace("  'Body Valid?',\n", ''); }), /pre-claim list is .*expected the flagship nodes that are not Respond 202 and not downstream of it/);
  // Round 6, P1: each node added to the list is required.
  for (const name of ['Respond 400', 'Claim Run', 'Claim OK?', 'Respond Claim Refused']) {
    has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace(`  '${name}',\n`, ''); }), /pre-claim list is .*expected the flagship nodes that are not Respond 202/);
  }
  // Respond 202 and a node after it are refused, and so is a repeat.
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace("  'Body Valid?',", "  'Body Valid?',\n  'Respond 202',"); }), /pre-claim list is/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace("  'Body Valid?',", "  'Body Valid?',\n  'Init Execution',"); }), /pre-claim list is/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace("  'Body Valid?',", "  'Body Valid?',\n  'Respond 400',"); }), /pre-claim list is/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace("  'Body Valid?',", "  'Body Valid?',\n  'Body Valid?',"); }), /pre-claim list is/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace("source = 'flagship_pre_claim'", "source = 'flagship'"); }), /does not map a pre-claim flagship failure/);
  has(run((wf, e) => { e.parameters.jsCode = e.parameters.jsCode.replace('Object.prototype.hasOwnProperty.call(SOURCE_BY_WORKFLOW, wfId)', 'true'); }), /does not refuse a workflow id outside the map/);
  has(run((wf, e, r) => { r.parameters.query = 'SELECT public.fao_run_fail($1, $2, $3) AS r;'; }), /query is not SELECT public\.fao_run_fail\(\$1, \$2, \$3, \$4\)/);
  has(run((wf, e, r) => { r.parameters.options.queryReplacement = '={{ [ $json.n8n_execution_id, $json.failed_node, $json.message, "flagship" ] }}'; }), /does not pass n8n_execution_id, failed_node, message, source/);
  has(run((wf) => { wf.connections['Record Run Failure'] = { main: [[{ node: 'Error Trigger', type: 'main', index: 0 }]] }; }), /must be the last node/);

  // The pre-claim list follows the flagship's own connections: a new node
  // before Claim Run or an unconnected node makes the export's list stale, a
  // new node after Respond 202 does not, and a flagship without Respond 202
  // is refused.
  const flag = structuredClone(exportedById.get(FLAGSHIP));
  flag.connections['Body Valid?'].main[0] = [{ node: 'Pre Check', type: 'main', index: 0 }];
  flag.connections['Pre Check'] = { main: [[{ node: 'Claim Run', type: 'main', index: 0 }]] };
  has(run(() => {}, new Map([...exportedById, [FLAGSHIP, flag]])), /expected the flagship nodes that are not Respond 202 and not downstream of it \["Body Valid\?","Claim OK\?","Claim Run","Pre Check","Respond 400","Respond Claim Refused","Validate Invoke Body","Webhook: Invoke"\]/);
  const later = structuredClone(exportedById.get(FLAGSHIP));
  later.nodes.push({ parameters: {}, type: 'n8n-nodes-base.noOp', typeVersion: 1, position: [0, 0], id: 'x1', name: 'After Run Complete' });
  later.connections['Run Complete'] = { main: [[{ node: 'After Run Complete', type: 'main', index: 0 }]] };
  assert.deepEqual(run(() => {}, new Map([...exportedById, [FLAGSHIP, later]])), [], 'a node after Respond 202 is not pre-claim');
  const stray = structuredClone(exportedById.get(FLAGSHIP));
  stray.nodes.push({ parameters: {}, type: 'n8n-nodes-base.noOp', typeVersion: 1, position: [0, 0], id: 'x2', name: 'Stray Node' });
  has(run(() => {}, new Map([...exportedById, [FLAGSHIP, stray]])), /pre-claim list is .*"Stray Node"/);
  const no202 = structuredClone(exportedById.get(FLAGSHIP));
  no202.nodes = no202.nodes.filter((n) => n.name !== 'Respond 202');
  delete no202.connections['Respond 202'];
  no202.connections['Claim OK?'].main[0] = [{ node: 'Init Execution', type: 'main', index: 0 }];
  has(run(() => {}, new Map([...exportedById, [FLAGSHIP, no202]])), /the flagship has no Respond 202 node/);
  // A workflow that names the handler without a source.
  const writer = structuredClone(exportedById.get('dQslIEVwF3WqMliT'));
  writer.settings.errorWorkflow = 'FaoErrHandlerV01';
  has(run(() => {}, new Map([...exportedById, ['dQslIEVwF3WqMliT', writer]])), /workflow dQslIEVwF3WqMliT names this handler but has no source/);
});

test('check-exports error_workflow requires the handler on the flagship, the notifier and the sweeper only', () => {
  const rule = RULES.find((r) => r.id === 'error_workflow');
  for (const f of Object.keys(ERROR_SOURCES)) {
    const wf = readWf(f);
    assert.deepEqual(rule.run({ file: f, wf }), [], `${f} passes`);
    delete wf.settings.errorWorkflow;
    assert.ok(rule.run({ file: f, wf }).some((v) => /settings\.errorWorkflow is \(unset\), expected FaoErrHandlerV01/.test(v)), `${f} without it fails`);
    wf.settings.errorWorkflow = 'FaoSweeperV1x001';
    assert.ok(rule.run({ file: f, wf }).length === 1, `${f} with another error workflow fails`);
  }
  for (const f of ['writer.json', WF, 'test_writer_harness_multi_item.json', 'test_hitl_gateway_harness.json']) {
    const wf = readWf(f);
    assert.deepEqual(rule.run({ file: f, wf }), [], `${f} passes`);
    wf.settings = { ...(wf.settings || {}), errorWorkflow: 'FaoErrHandlerV01' };
    assert.ok(rule.run({ file: f, wf }).some((v) => /outside the flagship, the notifier and the sweeper/.test(v)), `${f} with it fails`);
  }
});
