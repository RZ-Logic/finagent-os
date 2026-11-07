// ============================================================================
// FinAgent OS - workflow export rules (scripts/check-exports.mjs)
// Controls: FAO-GOV-001, FAO-GOV-004, FAO-GOV-007, FAO-GOV-008.
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { checkExports, checkPublishDocs, RULES, WORKFLOWS_DIR, PUBLISH_ORDER, NODE_VERSIONS_N8N } from '../../scripts/check-exports.mjs';

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

// ----------------------------------------------------------------------------
// FAO-GOV-001 / FAO-GOV-007: node typeVersions are pinned to the ones the
// mapping model above and the e2e layer were run against (n8n 2.46.6).
// ----------------------------------------------------------------------------

test('node_type_versions refuses a re-added node at another typeVersion and an unpinned type', () => {
  const rule = RULES.find((r) => r.id === 'node_type_versions');
  assert.ok(rule, 'rule exists');
  const all = loadAll();
  for (const { file, wf } of all) assert.deepEqual(rule.run({ file, wf }), [], `${file} passes as exported`);
  const flagship = all.find((w) => w.file === 'fao_reserve_recon_v1.json').wf;
  const bump = (name, v) => {
    const wf = structuredClone(flagship);
    wf.nodes.find((n) => n.name === name).typeVersion = v;
    return rule.run({ file: 'fao_reserve_recon_v1.json', wf });
  };
  assert.ok(bump('Writer: STARTED', 1.4).some((v) => /Writer: STARTED.*executeWorkflow typeVersion 1\.4, pinned 1\.3/.test(v)));
  assert.ok(bump('Claim Run', 2.8).some((v) => /postgres typeVersion 2\.8, pinned 2\.6/.test(v)));
  assert.ok(bump('Init Execution', 1).some((v) => /code typeVersion 1, pinned 2/.test(v)));
  const odd = structuredClone(flagship);
  odd.nodes.push({ name: 'Set Fields', type: 'n8n-nodes-base.set', typeVersion: 3.4, parameters: {} });
  assert.ok(rule.run({ file: 'fao_reserve_recon_v1.json', wf: odd }).some((v) => /n8n-nodes-base\.set has no pinned typeVersion/.test(v)));
});

test('every Execute Workflow and Trigger node is at the version the mapping model assumes', () => {
  for (const { file, wf } of loadAll()) {
    for (const n of wf.nodes) {
      if (n.type === 'n8n-nodes-base.executeWorkflow') assert.equal(n.typeVersion, 1.3, `${file} ${n.name}`);
      if (n.type === 'n8n-nodes-base.executeWorkflowTrigger') assert.equal(n.typeVersion, 1.1, `${file} ${n.name}`);
    }
  }
});

test('check-exports fails when every Execute Workflow node is bumped (the R26 probe) and when versions.json moves', () => {
  const dir = mkdtempSync(join(tmpdir(), 'fao-exports-'));
  try {
    const wfDir = join(dir, 'wf');
    mkdirSync(wfDir);
    for (const { file, wf } of loadAll()) {
      const copy = structuredClone(wf);
      for (const n of copy.nodes) {
        if (n.type === 'n8n-nodes-base.executeWorkflow' || n.type === 'n8n-nodes-base.executeWorkflowTrigger') n.typeVersion = 9.9;
      }
      writeFileSync(join(wfDir, file), JSON.stringify(copy, null, 2));
    }
    const bumped = checkExports({ workflowsDir: wfDir });
    assert.ok(bumped.failed >= 5, `failed ${bumped.failed}`);
    assert.ok(bumped.violations.some((v) => /\[node_type_versions\].*typeVersion 9\.9, pinned 1\.3/.test(v)));
    assert.ok(bumped.violations.some((v) => /\[node_type_versions\].*typeVersion 9\.9, pinned 1\.1/.test(v)));
    const vf = join(dir, 'versions.json');
    writeFileSync(vf, JSON.stringify({ n8n: '2.47.0' }));
    const moved = checkExports({ versionsFile: vf });
    assert.deepEqual(moved.violations.filter((v) => !/\[node_versions_n8n\]/.test(v)), []);
    assert.ok(moved.violations.some((v) => /\[node_versions_n8n\].*"2\.47\.0".*2\.46\.6/.test(v)), moved.violations.join('; '));
    assert.equal(NODE_VERSIONS_N8N, JSON.parse(readFileSync(join(WORKFLOWS_DIR, '..', 'test', 'env', 'versions.json'), 'utf8')).n8n);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ----------------------------------------------------------------------------
// FAO-GOV-007 / FAO-GOV-008: n8n 2.x publish order (Writer, notifier, error
// handler, sweeper, flagship), enforced on the exports and the README.
// ----------------------------------------------------------------------------

test('PUBLISH_ORDER puts every sub-workflow and the error workflow before their callers', () => {
  assert.deepEqual(PUBLISH_ORDER, ['writer.json', 'fao_hitl_gateway_v1.json', 'fao_error_handler_v1.json', 'fao_hitl_sweeper_v1.json', 'fao_reserve_recon_v1.json']);
  const rule = RULES.find((r) => r.id === 'publish_order');
  assert.ok(rule, 'rule exists');
  const all = loadAll();
  const exportedById = new Map(all.map(({ wf }) => [wf.id, wf]));
  for (const { file, wf } of all) assert.deepEqual(rule.run({ file, wf, exportedById }), [], `${file} passes as exported`);
  // The Writer calling the flagship would need the flagship published first.
  const writer = structuredClone(all.find((w) => w.file === 'writer.json').wf);
  writer.nodes.push({ name: 'Call Flagship', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.3, parameters: { mode: 'once', workflowId: { __rl: true, value: 'uhB2KjEaJDuviM4D', mode: 'list' } } });
  assert.ok(rule.run({ file: 'writer.json', wf: writer, exportedById }).some((v) => /Call Flagship.*not published before writer\.json/.test(v)));
  // The notifier naming the sweeper as its error workflow.
  const gw = structuredClone(all.find((w) => w.file === 'fao_hitl_gateway_v1.json').wf);
  gw.settings.errorWorkflow = 'FaoSweeperV1x001';
  assert.ok(rule.run({ file: 'fao_hitl_gateway_v1.json', wf: gw, exportedById }).some((v) => /settings\.errorWorkflow.*not published before/.test(v)));
  // A sticky note that no longer states its step.
  const flag = structuredClone(all.find((w) => w.file === 'fao_reserve_recon_v1.json').wf);
  for (const n of flag.nodes) if (n.type === 'n8n-nodes-base.stickyNote') n.parameters.content = 'no step';
  assert.ok(rule.run({ file: 'fao_reserve_recon_v1.json', wf: flag, exportedById }).some((v) => /step 5 of 5/.test(v)));
});

test('publish_docs: the README publishes the five production ids in PUBLISH_ORDER and no harness', () => {
  const readme = readFileSync(join(WORKFLOWS_DIR, 'README.md'), 'utf8');
  assert.deepEqual(checkPublishDocs(readme), []);
  const ids = ['dQslIEVwF3WqMliT', 'mUAC9qIMkVzlV5qw', 'FaoErrHandlerV01', 'FaoSweeperV1x001', 'uhB2KjEaJDuviM4D'];
  const doc = (list) => list.map((id) => `n8n publish:workflow --id=${id}`).join('\n');
  assert.deepEqual(checkPublishDocs(doc(ids)), []);
  assert.equal(checkPublishDocs(doc([ids[0], ids[4], ids[1], ids[2], ids[3]])).length, 1, 'flagship before the notifier');
  assert.equal(checkPublishDocs(doc(ids.slice(1))).length, 1, 'Writer missing');
  assert.equal(checkPublishDocs(doc([...ids, 'OV7ukqcVKYfNXKHa'])).length, 1, 'a harness published');
  assert.equal(checkPublishDocs(`${doc(ids)}\nThe Writer, notifier and error handler run only when called.`).length, 1, 'n8n 1.x wording');
  for (const id of ['OV7ukqcVKYfNXKHa', 'V87nEh6HALqINIDz']) assert.ok(!readme.includes(`--id=${id}`), `README never publishes harness ${id}`);
});
