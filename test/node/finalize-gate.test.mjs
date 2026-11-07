// ============================================================================
// FinAgent OS - flagship Check Finalize Result (patch P1, KNOWN-LIMITS U16 (a))
// Controls: FAO-GOV-008 (a failed run fails the n8n execution, so the error
// workflow and failure alerting run), FAO-GOV-002 (agent not ACTIVE at
// commit, IC-24).
//
// fao_run_finalize returns the AGENT_NOT_ACTIVE envelope (ok:false) with
// COMMIT_BLOCKED and run FAILED committed. Check Finalize Result must fail
// the execution with one fixed message naming the code and the correlation
// id, pass every ok:true result through unchanged, and check-exports must
// refuse any layout that lets a finalize result skip it.
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { runCodeNode, WORKFLOWS } from './harness.mjs';
import { RULES } from '../../scripts/check-exports.mjs';

const WF = 'fao_reserve_recon_v1.json';
const NODE = 'Check Finalize Result';
const CORR = '11111111-2222-4333-8444-555555555555';
const CLAIM = { ok: true, code: 'OK', correlation_id: CORR, agent_id: 'fao_reserve_recon_v1' };
const MSG = (code, cid = CORR) => `FAO-GOV-008 recon: fao_run_finalize refused with ${code} for run ${cid}; the run was not committed`;

// The IC-24 finalize envelope for an agent that is not ACTIVE at commit.
const BLOCKED = {
  ok: false, code: 'AGENT_NOT_ACTIVE', http_status: 409, message: 'agent is not active', ref: 77,
  hitl_required: false, hitl_id: null, approval_url: null, timeout_at: null, hitl_requested_ledger_id: null,
  rollup_outcome: null, rollup_sub_tier: null, review_sub_tier: null, escalated_assets: null, counts: null,
  committed_ledger_id: null, state: 'FAILED',
};
const COMMITTED = {
  ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null, hitl_required: false, hitl_id: null,
  rollup_outcome: 'ALLOW', counts: { ALLOW: 7 }, committed_ledger_id: 901, state: 'COMMITTED',
};
const AWAITING = {
  ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null, hitl_required: true, hitl_id: 42,
  approval_url: 'http://localhost:4173/?hitl_id=42', review_sub_tier: 'CRITICAL', state: 'AWAITING_HITL',
};

const gate = (items, claim = CLAIM) => runCodeNode(WF, NODE, {
  items,
  upstream: { 'Claim Run': [{ r: claim }], 'Finalize Run': items },
});

test('Check Finalize Result fails the execution on the AGENT_NOT_ACTIVE envelope with the fixed message', async () => {
  await assert.rejects(gate([{ r: BLOCKED }]), (e) => {
    assert.equal(e.message, MSG('AGENT_NOT_ACTIVE'));
    return true;
  });
});

test('Check Finalize Result fails on every ok other than true and on a missing or extra item', async () => {
  const cases = [
    [[{ r: { ...BLOCKED, code: 'AUDIT_CHAIN_MISMATCH' } }], MSG('AUDIT_CHAIN_MISMATCH')],
    [[{ r: { ...COMMITTED, ok: 'true' } }], MSG('OK')],
    [[{ r: { ...COMMITTED, ok: 1 } }], MSG('OK')],
    [[{ r: { ...COMMITTED, ok: undefined } }], MSG('OK')],
    [[{ r: { state: 'COMMITTED' } }], MSG('UNKNOWN')],
    [[{ r: null }], MSG('UNKNOWN')],
    [[{ r: [COMMITTED] }], MSG('UNKNOWN')],
    [[{}], MSG('UNKNOWN')],
    [[], MSG('UNKNOWN')],
    [[{ r: COMMITTED }, { r: COMMITTED }], MSG('UNKNOWN')],
  ];
  for (const [items, msg] of cases) {
    await assert.rejects(gate(items), (e) => {
      assert.equal(e.message, msg, JSON.stringify(items));
      return true;
    });
  }
});

test('Check Finalize Result never echoes a code or id outside their formats', async () => {
  const markup = { ...BLOCKED, code: '<!channel> APPROVE_ALL' };
  await assert.rejects(gate([{ r: markup }]), (e) => {
    assert.equal(e.message, MSG('UNKNOWN'));
    return true;
  });
  await assert.rejects(gate([{ r: { ...BLOCKED, code: 'x'.repeat(5) } }]), (e) => e.message === MSG('UNKNOWN'));
  await assert.rejects(gate([{ r: { ...BLOCKED, code: 'A'.repeat(65) } }]), (e) => e.message === MSG('UNKNOWN'));
  for (const cid of ['not-a-uuid', '', null, `${CORR} ; DROP`]) {
    await assert.rejects(gate([{ r: BLOCKED }], { ...CLAIM, correlation_id: cid }), (e) => {
      assert.equal(e.message, MSG('AGENT_NOT_ACTIVE', 'unknown'), String(cid));
      return true;
    });
  }
});

test('Check Finalize Result passes COMMITTED and AWAITING_HITL results through unchanged', async () => {
  for (const r of [COMMITTED, AWAITING]) {
    const out = await gate([{ r }]);
    assert.deepEqual(out, [{ r }]);
  }
});

test('the AGENT_NOT_ACTIVE result never reaches Human Review Required?, Run Complete or the notifier', () => {
  // Walk the export's own connections from Finalize Run: the only way on is
  // through Check Finalize Result, which throws for this result (above).
  const wf = JSON.parse(readFileSync(join(WORKFLOWS, WF), 'utf8'));
  const next = (name) => ((wf.connections[name] || {}).main || []).flat().map((c) => c.node);
  assert.deepEqual(next('Finalize Run'), [NODE]);
  assert.deepEqual(next(NODE), ['Human Review Required?']);
  const into = (target) => Object.keys(wf.connections).filter((k) => next(k).includes(target));
  for (const later of ['Human Review Required?']) assert.deepEqual(into(later), [NODE], later);
  assert.deepEqual(into('Run Complete'), ['Human Review Required?']);
  assert.deepEqual(into('Notify Input'), ['Human Review Required?']);
  const node = wf.nodes.find((n) => n.name === NODE);
  assert.equal(node.type, 'n8n-nodes-base.code');
  assert.equal(node.onError, undefined);
  assert.equal(wf.settings.errorWorkflow, 'FaoErrHandlerV01');
});

// --- check-exports: checkFinalizeGate inside section4_nodes ------------------

test('check-exports refuses a flagship whose finalize result can skip Check Finalize Result', () => {
  const rule = RULES.find((r) => r.id === 'section4_nodes');
  const base = JSON.parse(readFileSync(join(WORKFLOWS, WF), 'utf8'));
  const run = (mutate) => {
    const wf = structuredClone(base);
    mutate(wf, Object.fromEntries(wf.nodes.map((n) => [n.name, n])));
    return rule.run({ file: WF, wf });
  };
  const edge = (node) => ({ node, type: 'main', index: 0 });
  assert.deepEqual(run(() => {}), [], 'the export passes');

  // The round 3 layout: Finalize Run straight into Human Review Required?.
  const bypass = run((wf) => { wf.connections['Finalize Run'] = { main: [[edge('Human Review Required?')]] }; });
  assert.ok(bypass.some((v) => /Finalize Run must lead only to Check Finalize Result/.test(v)), bypass.join('; '));
  assert.ok(bypass.some((v) => /only Check Finalize Result may lead to Human Review Required\?/.test(v)), bypass.join('; '));

  // A second branch next to the gate.
  const fork = run((wf) => { wf.connections['Finalize Run'].main[0].push(edge('Run Complete')); });
  assert.ok(fork.some((v) => /Finalize Run must lead only to Check Finalize Result/.test(v)), fork.join('; '));

  // An error output or continue-on-fail on either node.
  const errOut = run((wf, n) => { n['Finalize Run'].onError = 'continueErrorOutput'; wf.connections['Finalize Run'].main.push([edge('Run Complete')]); });
  assert.ok(errOut.some((v) => /Finalize Run" onError is continueErrorOutput/.test(v)), errOut.join('; '));
  assert.ok(errOut.some((v) => /Finalize Run must lead only/.test(v)), errOut.join('; '));
  const cont = run((wf, n) => { n[NODE].onError = 'continueRegularOutput'; });
  assert.ok(cont.some((v) => /Check Finalize Result" onError is continueRegularOutput/.test(v)), cont.join('; '));
  const cof = run((wf, n) => { n['Finalize Run'].continueOnFail = true; });
  assert.ok(cof.some((v) => /Finalize Run" has continueOnFail/.test(v)), cof.join('; '));

  // Another node feeding Human Review Required?.
  const side = run((wf) => { wf.connections['Check Writer Count'].main[0].push(edge('Human Review Required?')); });
  assert.ok(side.some((v) => /only Check Finalize Result may lead to Human Review Required\?/.test(v)), side.join('; '));

  // A gate that no longer throws on ok:false (the check only in a comment).
  const soft = run((wf, n) => { n[NODE].parameters.jsCode = '// if (r.ok !== true) throw\nreturn $input.all();'; });
  assert.ok(soft.some((v) => /must throw unless r\.ok === true/.test(v)), soft.join('; '));

  // The gate removed altogether.
  const gone = run((wf) => {
    wf.nodes = wf.nodes.filter((x) => x.name !== NODE);
    delete wf.connections[NODE];
    wf.connections['Finalize Run'] = { main: [[edge('Human Review Required?')]] };
  });
  assert.ok(gone.some((v) => /missing node "Check Finalize Result"/.test(v)), gone.join('; '));
  assert.ok(gone.some((v) => /no connection "Finalize Run" output 0 -> "Check Finalize Result"/.test(v)), gone.join('; '));
});
