// ============================================================================
// FinAgent OS - error handler Code node (fao_error_handler_v1.json)
// Controls: FAO-GOV-008 (a failed flagship run is recorded through
// fao_run_fail with a bounded, control-character-free message).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runCodeNode, nodeOf } from './harness.mjs';

const WF = 'fao_error_handler_v1.json';

// The field names Record Run Failure passes as $1, $2, $3, read from its
// queryReplacement expression so the test follows the exported wiring.
function recordFields() {
  const n = nodeOf(WF, 'Record Run Failure');
  const qr = String((n && n.parameters && n.parameters.options && n.parameters.options.queryReplacement) || '');
  const names = [...qr.matchAll(/\$json(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[\s*['"]([^'"]+)['"]\s*\])/g)].map((m) => m[1] || m[2]);
  return names.length === 3 ? names : null;
}

function errorItem(message, lastNode = 'Per-Asset Reconcile', id = '4711') {
  return {
    execution: {
      id,
      url: 'http://localhost:5678/execution/4711',
      retryOf: null,
      mode: 'webhook',
      lastNodeExecuted: lastNode,
      error: { message, stack: `Error: ${message}\n    at somewhere` },
    },
    workflow: { id: 'uhB2KjEaJDuviM4D', name: 'fao_reserve_recon_v1' },
  };
}

async function extract(item) {
  const out = await runCodeNode(WF, 'Extract Failure', { items: [item], upstream: { 'Error Trigger': [item] } });
  assert.equal(out.length, 1);
  return out[0];
}

function values(o) {
  const fields = recordFields();
  if (fields) return { fields, id: o[fields[0]], node: o[fields[1]], message: o[fields[2]] };
  return { fields: null, all: Object.values(o) };
}

test('Record Run Failure passes three fields from Extract Failure', () => {
  assert.ok(recordFields(), 'queryReplacement names three $json fields');
});

test('Extract Failure passes the execution id and the last node', async () => {
  const o = await extract(errorItem('boom'));
  const v = values(o);
  assert.ok(v.fields, 'field names known');
  assert.equal(String(v.id), '4711');
  assert.equal(v.node, 'Per-Asset Reconcile');
  assert.equal(v.message, 'boom');
});

test('Extract Failure strips control characters', async () => {
  const msg = 'line1\nline2\r\u0000nul\u0007bell\ttab\u001bend\u007f';
  const o = await extract(errorItem(msg));
  const v = values(o);
  assert.equal(typeof v.message, 'string');
  assert.ok(!/[\u0000-\u001f\u007f]/.test(v.message), `control characters remain: ${JSON.stringify(v.message)}`);
  for (const part of ['line1', 'line2', 'nul', 'bell', 'tab', 'end']) assert.ok(v.message.includes(part), `keeps ${part}`);
});

test('Extract Failure cuts the message to 500 characters', async () => {
  const msg = 'FAO-GOV-001 ' + 'y'.repeat(2000);
  const o = await extract(errorItem(msg));
  const v = values(o);
  assert.ok(v.message.length <= 500, `length ${v.message.length}`);
  assert.ok(v.message.length >= 450, 'keeps the start of the message');
  assert.ok(v.message.startsWith('FAO-GOV-001 yyy'));
});
