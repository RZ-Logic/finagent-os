// ============================================================================
// FinAgent OS - workflow export rules (scripts/check-exports.mjs)
// Controls: FAO-GOV-001, FAO-GOV-004, FAO-GOV-007, FAO-GOV-008.
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { checkExports, RULES, WORKFLOWS_DIR } from '../../scripts/check-exports.mjs';

test('check-exports reports zero violations', () => {
  const report = checkExports();
  assert.ok(report.total >= RULES.length * 7 + 1, `ran ${report.total} checks`);
  assert.deepEqual(report.violations, []);
  assert.equal(report.failed, 0);
});

// ----------------------------------------------------------------------------
// FAO-GOV-001 / FAO-GOV-007: Execute Workflow input mapping.
// The Writer and notifier calls map every field explicitly by expression, so
// they do not depend on the parent item passing through an empty mapping.
// ----------------------------------------------------------------------------

const WRITER_ID = 'dQslIEVwF3WqMliT';
const NOTIFIER_ID = 'mUAC9qIMkVzlV5qw';

// BUILD-CORE 2.11, in the order of the Writer trigger's jsonExample.
const WRITER_FIELDS = [
  'correlation_id', 'event_type', 'inputs', 'policy_outcome', 'policy_sub_tier',
  'policy_rationale', 'obligations', 'status', 'error_details', 'ai_prompt',
  'ai_output', 'ai_confidence', 'fractional_cost_usd', 'hitl_status',
  'execution_id', 'agent_id', 'risk_tier',
];
const NOTIFIER_FIELDS = ['hitl_id', 'kind', 'level'];
const NOTIFIER_TYPES = { hitl_id: 'number', kind: 'string', level: 'number' };

function loadAll() {
  return readdirSync(WORKFLOWS_DIR)
    .filter((f) => f.endsWith('.json'))
    .map((f) => ({ file: f, wf: JSON.parse(readFileSync(join(WORKFLOWS_DIR, f), 'utf8')) }));
}

function execNodes() {
  const out = [];
  for (const { file, wf } of loadAll()) {
    for (const n of wf.nodes) {
      if (n.type === 'n8n-nodes-base.executeWorkflow') out.push({ file, node: n, target: n.parameters.workflowId.value });
    }
  }
  return out;
}

test('every Writer and notifier call maps each 2.11 field by expression', () => {
  const calls = execNodes();
  const writerCalls = calls.filter((c) => c.target === WRITER_ID);
  const notifierCalls = calls.filter((c) => c.target === NOTIFIER_ID);
  // recon STARTED + ASSET_RECONCILED, harness valid + bad batch; recon and sweeper notifier.
  assert.equal(writerCalls.length, 4, 'four Writer calls');
  assert.equal(notifierCalls.length, 2, 'two notifier calls');
  assert.equal(calls.length, writerCalls.length + notifierCalls.length, 'no other Execute Workflow targets');

  for (const { file, node, target } of calls) {
    const label = `${file} "${node.name}"`;
    const fields = target === WRITER_ID ? WRITER_FIELDS : NOTIFIER_FIELDS;
    const wi = node.parameters.workflowInputs;
    assert.equal(wi.mappingMode, 'defineBelow', label);
    assert.equal(wi.attemptToConvertTypes, false, label);
    assert.deepEqual(Object.keys(wi.value), fields, `${label} value keys`);
    for (const k of fields) assert.equal(wi.value[k], `={{ $json.${k} }}`, `${label} ${k}`);
    assert.deepEqual(wi.schema.map((e) => e.id), fields, `${label} schema ids`);
    for (const e of wi.schema) {
      assert.equal(e.displayName, e.id, `${label} ${e.id} displayName`);
      assert.notEqual(e.removed, true, `${label} ${e.id} removed`);
    }
    if (target === NOTIFIER_ID) {
      for (const e of wi.schema) assert.equal(e.type, NOTIFIER_TYPES[e.id], `${label} ${e.id} type`);
    }
  }
});

// Minimal model of what n8n does with the mapping (Execute Workflow node 1.3
// and Execute Workflow Trigger 1.1 with a jsonExample): the parent resolves
// each mapped expression per item, type-checks it against the schema (strict,
// strings not cast to other types), merges it over the item, and the child
// trigger fills schema fields with null and keeps only schema fields.
function resolveMapping(wi, json) {
  const out = {};
  for (const [k, expr] of Object.entries(wi.value)) {
    const m = /^=\{\{\s*\$json\.([A-Za-z0-9_]+)\s*\}\}$/.exec(String(expr));
    out[k] = m ? json[m[1]] : expr;
  }
  for (const e of wi.schema) {
    const v = out[e.id];
    if (v === null || v === undefined || !e.type) continue;
    const ok = e.type === 'number' ? typeof v === 'number'
      : e.type === 'string' ? typeof v === 'string'
        : e.type === 'array' ? Array.isArray(v)
          : e.type === 'object' ? typeof v === 'object' && !Array.isArray(v)
            : true;
    if (!ok) throw new Error(`Invalid input for '${e.id}'`);
  }
  return out;
}
function deliver(wi, items) {
  const keys = wi.schema.filter((e) => !e.removed).map((e) => e.id);
  return items.map((json) => {
    const merged = { ...json, ...resolveMapping(wi, json) };
    const child = Object.fromEntries(keys.map((k) => [k, null]));
    for (const k of keys) if (Object.prototype.hasOwnProperty.call(merged, k)) child[k] = merged[k];
    return child;
  });
}

test('the notifier receives hitl_id as a JS number from both callers', () => {
  for (const { file, node } of execNodes().filter((c) => c.target === NOTIFIER_ID)) {
    const wi = node.parameters.workflowInputs;
    const [got] = deliver(wi, [{ hitl_id: 77, kind: 'ESCALATED', level: 1 }]);
    assert.deepEqual(got, { hitl_id: 77, kind: 'ESCALATED', level: 1 }, file);
    assert.equal(typeof got.hitl_id, 'number', file);
    assert.throws(() => deliver(wi, [{ hitl_id: '77', kind: 'REQUESTED', level: 0 }]), /hitl_id/, `${file} string hitl_id refused`);
  }
});

test('the Writer receives each event field unchanged and no extra keys', () => {
  const ev = {
    correlation_id: '11111111-1111-4111-8111-111111111111',
    event_type: 'ASSET_RECONCILED',
    execution_id: '22222222-2222-4222-8222-222222222222',
    agent_id: 'fao_reserve_recon_v1',
    risk_tier: 'RED',
    inputs: { event_type: 'ASSET_RECONCILED', asset: 'BTC', ratio: 1.003, band_status: 'IN_BAND' },
    ai_prompt: null,
    ai_output: null,
    ai_confidence: null,
    fractional_cost_usd: null,
    policy_outcome: 'ALLOW',
    policy_sub_tier: null,
    policy_rationale: 'FAO-REC-006 BTC ratio 1.003000 within expected band.',
    obligations: [],
    hitl_status: 'NOT_REQUIRED',
    status: 'SUCCESS',
    error_details: null,
    _wallet_data: { BTC: 1 },
  };
  const { _wallet_data, ...expected } = ev;
  for (const { file, node } of execNodes().filter((c) => c.target === WRITER_ID)) {
    const [got] = deliver(node.parameters.workflowInputs, [ev]);
    assert.deepEqual(got, expected, file);
  }
});

test('execute_workflow_inputs flags pass-through, null refill, literals, wrong types and extras', () => {
  const rule = RULES.find((r) => r.id === 'execute_workflow_inputs');
  assert.ok(rule, 'rule exists');
  const all = loadAll();
  const exportedById = new Map(all.map(({ wf }) => [wf.id, wf]));
  const sweeper = all.find((w) => w.file === 'fao_hitl_sweeper_v1.json').wf;
  const run = (mutate) => {
    const wf = structuredClone(sweeper);
    const n = wf.nodes.find((x) => x.name === 'HITL Gateway');
    mutate(n.parameters.workflowInputs, n.parameters);
    return rule.run({ wf, exportedById });
  };
  assert.deepEqual(run(() => {}), [], 'current export passes');
  // Run 0 shape: empty mapping, empty schema (relies on pass-through).
  const empty = run((wi) => { wi.value = {}; wi.schema = []; });
  assert.ok(empty.some((v) => /field hitl_id is not mapped/.test(v)), empty.join('; '));
  assert.ok(empty.some((v) => /schema has no entry for level/.test(v)), empty.join('; '));
  // Editor refilled the mapping with nulls.
  const nulls = run((wi) => { for (const k of Object.keys(wi.value)) wi.value[k] = null; });
  assert.equal(nulls.filter((v) => /is mapped to null/.test(v)).length, 3, nulls.join('; '));
  // A fixed value instead of the item's own field.
  assert.ok(run((wi) => { wi.value.level = 0; }).some((v) => /field level is mapped to 0/.test(v)));
  assert.ok(run((wi) => { wi.value.kind = '={{ $json.level }}'; }).some((v) => /field kind is mapped/.test(v)));
  // hitl_id typed as a string, a removed field, an extra field, casting on.
  assert.ok(run((wi) => { wi.schema[0].type = 'string'; }).some((v) => /hitl_id type is string, expected number/.test(v)));
  assert.ok(run((wi) => { wi.schema[1].removed = true; }).some((v) => /kind is removed/.test(v)));
  assert.ok(run((wi) => { wi.value.extra = '={{ $json.extra }}'; }).some((v) => /mapped field extra is not in the target trigger/.test(v)));
  assert.ok(run((wi) => { wi.attemptToConvertTypes = true; }).some((v) => /attemptToConvertTypes is not false/.test(v)));
  assert.ok(run((wi, p) => { delete p.workflowInputs; }).some((v) => /workflowInputs is missing/.test(v)));
  assert.ok(run((wi) => { wi.mappingMode = 'autoMapInputData'; }).some((v) => /mappingMode is autoMapInputData/.test(v)));
});
