// ============================================================================
// FinAgent OS - flagship Code nodes (fao_reserve_recon_v1.json)
// Controls: FAO-GOV-008 (run claim and ids), FAO-REC-001/002/004/006/007
// (Per-Asset Reconcile decision matrix, fail-closed inputs), FAO-GOV-001
// (writer count check), FAO-GOV-007 (notifier input shape).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runCodeNode, codeOf, decodeBalances, readJson } from './harness.mjs';

const WF = 'fao_reserve_recon_v1.json';
const FIX = readJson('fixtures/policy_branches.json');
const TOKEN = 'A'.repeat(20) + 'b_c-' + '9'.repeat(19); // 43 characters
const RANK = { ALLOW: 0, ALLOW_WITH_OBLIGATIONS: 1, REQUIRE_HUMAN: 2, DENY: 3, BLOCKED: 4 };
const FORBIDDEN = ['event_timestamp', 'hitl_approver_id'];

const CLAIM = {
  ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null,
  correlation_id: '11111111-2222-4333-8444-555555555555',
  execution_id: '66666666-7777-4888-9999-aaaaaaaaaaaa',
  agent_id: 'fao_reserve_recon_v1',
  risk_tier: 'RED',
  invoker_id: 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff',
  invoker_name: 'Aisha Okonkwo',
  reason: 'node test',
  invoked_via: 'test',
};

function initUpstream(wallet, ledger, claim = CLAIM) {
  return {
    correlation_id: claim.correlation_id,
    execution_id: claim.execution_id,
    agent_id: claim.agent_id,
    risk_tier: claim.risk_tier,
    event_type: 'STARTED',
    inputs: { event_type: 'STARTED', asset_scope: Object.keys({ ...wallet, ...ledger }).sort() },
    policy_outcome: 'ALLOW',
    policy_rationale: 'node test STARTED',
    status: 'SUCCESS',
    _wallet_data: wallet,
    _ledger_data: ledger,
    _fixture_metadata: {},
  };
}

function upstreamFor(wallet, ledger, thresholds) {
  return {
    'Webhook: Invoke': [{ body: { run_token: TOKEN }, headers: {}, query: {} }],
    'Validate Invoke Body': [{ valid: true, run_token: TOKEN, n8n_execution_id: 'test-exec-1' }],
    'Claim Run': [{ r: CLAIM }],
    'Respond 202': [{ r: CLAIM }],
    'Init Execution': [initUpstream(wallet, ledger)],
    'Writer: STARTED': [{ count: 1, inserted: [{ ledger_id: 1, event_type: 'STARTED', asset: null }] }],
    'Get Materiality Thresholds': thresholds,
    'Check Thresholds': thresholds,
  };
}

async function reconcile(wallet, ledger, thresholds = FIX.thresholds) {
  return runCodeNode(WF, 'Per-Asset Reconcile', { items: thresholds, upstream: upstreamFor(wallet, ledger, thresholds) });
}

function assertNoForbidden(item, label) {
  for (const k of FORBIDDEN) {
    assert.ok(!(k in item), `${label}: item carries ${k}`);
  }
}

// --- Validate Invoke Body ----------------------------------------------------

test('Validate Invoke Body accepts a 43-character token and emits only valid, run_token, n8n_execution_id', async () => {
  const out = await runCodeNode(WF, 'Validate Invoke Body', {
    items: [{
      body: { run_token: TOKEN, invoker_id: 'evil-invoker', agent_id: 'other_agent', reason: 'x' },
      headers: { 'x-user-id': 'evil-header' },
      query: { run_token: 'B'.repeat(43), invoker: 'evil-query' },
    }],
    executionId: 'exec-123',
  });
  assert.equal(out.length, 1);
  assert.deepEqual(Object.keys(out[0]).sort(), ['n8n_execution_id', 'run_token', 'valid']);
  assert.equal(out[0].valid, true);
  assert.equal(out[0].run_token, TOKEN);
  assert.equal(out[0].n8n_execution_id, 'exec-123');
  const text = JSON.stringify(out);
  for (const s of ['evil-invoker', 'other_agent', 'evil-header', 'evil-query']) assert.ok(!text.includes(s), `output carries ${s}`);
});

test('Validate Invoke Body refuses every token that is not exactly 43 URL-safe characters in the body', async () => {
  const bad = [
    { body: { run_token: TOKEN.slice(0, 42) } },
    { body: { run_token: TOKEN + 'x' } },
    { body: { run_token: TOKEN.slice(0, 42) + '+' } },
    { body: { run_token: TOKEN.slice(0, 42) + '=' } },
    { body: { run_token: TOKEN.slice(0, 42) + '/' } },
    { body: { run_token: ' ' + TOKEN.slice(1) } },
    { body: { run_token: 12345 } },
    { body: { run_token: null } },
    { body: { run_token: [TOKEN] } },
    { body: { run_token: { v: TOKEN } } },
    { body: {} },
    { body: null },
    {},
    { query: { run_token: TOKEN }, body: {} },
    { headers: { run_token: TOKEN }, body: {} },
  ];
  for (const input of bad) {
    const out = await runCodeNode(WF, 'Validate Invoke Body', { items: [input], executionId: 'exec-9' });
    assert.equal(out.length, 1, `one item for ${JSON.stringify(input)}`);
    assert.equal(out[0].valid, false, `valid must be false for ${JSON.stringify(input)}`);
  }
});

// --- Init Execution ----------------------------------------------------------

test('Init Execution takes correlation_id, execution_id, agent_id and risk_tier from the claim result', async () => {
  for (const tier of ['RED', 'AMBER']) {
    const claim = { ...CLAIM, risk_tier: tier, correlation_id: `0000000${tier === 'RED' ? 1 : 2}-0000-4000-8000-000000000000` };
    const out = await runCodeNode(WF, 'Init Execution', {
      items: [{ r: claim }],
      upstream: {
        'Claim Run': [{ r: claim }],
        'Claim OK?': [{ r: claim }],
        'Respond 202': [{ r: claim }],
        'Validate Invoke Body': [{ valid: true, run_token: TOKEN, n8n_execution_id: 'test-exec-1' }],
        'Webhook: Invoke': [{ body: { run_token: TOKEN } }],
      },
    });
    assert.ok(out.length >= 1);
    const ev = out[0];
    assert.equal(ev.correlation_id, claim.correlation_id);
    assert.equal(ev.execution_id, claim.execution_id);
    assert.equal(ev.agent_id, claim.agent_id);
    assert.equal(ev.risk_tier, tier);
    assert.equal(ev.event_type, 'STARTED');
    assert.ok(ev.inputs && Array.isArray(ev.inputs.asset_scope), 'STARTED inputs.asset_scope is an array');
    assert.equal(ev.inputs.asset_count, ev.inputs.asset_scope.length);
    assert.equal(typeof ev.policy_rationale, 'string');
    assert.ok(ev._wallet_data && ev._ledger_data, 'keeps _wallet_data and _ledger_data');
    for (const o of out) assertNoForbidden(o, 'Init Execution');
  }
});

test('Init Execution has no invoker email and no Math.random', () => {
  const code = codeOf(WF, 'Init Execution');
  assert.ok(!/Math\.random/.test(code), 'uses Math.random');
  assert.ok(!/agent_invoker_email/.test(code), 'mentions agent_invoker_email');
  assert.ok(!/@finagent-os\.demo/.test(code), 'contains a demo email address');
  assert.ok(!/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.test(code), 'contains an email address');
});

// --- Per-Asset Reconcile ----------------------------------------------------

for (const c of FIX.cases) {
  test(`Per-Asset Reconcile branch ${c.branch} (${c.id})`, async () => {
    const wallet = decodeBalances(c.wallet);
    const ledger = decodeBalances(c.ledger);
    const out = await reconcile(wallet, ledger);
    const union = new Set([...Object.keys(wallet), ...Object.keys(ledger)]);
    assert.equal(out.length, union.size, 'output count equals the key union');
    const item = out.find((o) => o.inputs && o.inputs.asset === c.expect.asset);
    assert.ok(item, `an item for ${c.expect.asset}`);
    const e = c.expect;
    assert.equal(item.event_type, 'ASSET_RECONCILED');
    assert.equal(item.correlation_id, CLAIM.correlation_id);
    assert.equal(item.inputs.band_status, e.band_status);
    assert.equal(item.policy_outcome, e.policy_outcome);
    assert.equal(item.policy_sub_tier ?? null, e.policy_sub_tier);
    assert.equal(item.hitl_status, e.hitl_status);
    assert.equal(typeof item.policy_rationale, 'string');
    assert.ok(item.policy_rationale.length > 0);
    if (e.ratio === 'number') assert.ok(typeof item.inputs.ratio === 'number' && Number.isFinite(item.inputs.ratio), 'ratio is a finite number');
    if (e.ratio === 'null') assert.equal(item.inputs.ratio, null);
    if (e.input_problem_side) {
      assert.equal(typeof item.inputs.input_problem, 'string', 'input_problem is set');
      assert.ok(item.inputs.input_problem.toLowerCase().includes(e.input_problem_side), `input_problem names side ${e.input_problem_side}`);
    }
    if (e.input_problem_class) {
      assert.ok(item.inputs.input_problem.includes(e.input_problem_class), `input_problem names class ${e.input_problem_class}`);
    }
    if (c.branch === 'INVALID_INPUT' || c.branch === 'ONE_SIDED' || c.branch === 'NO_THRESHOLD') {
      assert.ok(RANK[item.policy_outcome] >= 2, 'a bad input never yields ALLOW or ALLOW_WITH_OBLIGATIONS');
    }
    assertNoForbidden(item, c.id);
  });
}

test('Per-Asset Reconcile: every BLOCKED item routes to review and no bad input is allowed', async () => {
  const bad = FIX.cases.filter((c) => ['INVALID_INPUT', 'ONE_SIDED', 'NO_THRESHOLD'].includes(c.branch));
  assert.ok(bad.length >= 17);
  for (const c of bad) {
    const out = await reconcile(decodeBalances(c.wallet), decodeBalances(c.ledger));
    for (const item of out) {
      assert.notEqual(item.policy_outcome, 'ALLOW', c.id);
      assert.notEqual(item.policy_outcome, 'ALLOW_WITH_OBLIGATIONS', c.id);
      if (item.policy_outcome === 'BLOCKED') {
        assert.equal(item.hitl_status, 'PENDING', `${c.id}: BLOCKED item has hitl_status PENDING`);
        assert.equal(item.inputs.ratio, null, `${c.id}: BLOCKED item has ratio null`);
      }
    }
  }
});

test('Per-Asset Reconcile iterates the sorted key union of wallet and ledger', async () => {
  const wallet = { USDC: 1000, BTC: 1003, SOL: 950, ZZZ: 5 };
  const ledger = { USDC: 1000, BTC: 1000, SOL: 1000, AAA: 7, ETH: 1000 };
  const out = await reconcile(wallet, ledger);
  const union = [...new Set([...Object.keys(wallet), ...Object.keys(ledger)])].sort();
  assert.equal(out.length, union.length);
  assert.deepEqual(out.map((o) => o.inputs.asset), union);
  for (const o of out) {
    assertNoForbidden(o, o.inputs.asset);
    if (o.policy_outcome === 'BLOCKED') assert.equal(o.hitl_status, 'PENDING');
  }
  const byAsset = Object.fromEntries(out.map((o) => [o.inputs.asset, o]));
  assert.equal(byAsset.ZZZ.inputs.band_status, 'ONE_SIDED');
  assert.equal(byAsset.AAA.inputs.band_status, 'ONE_SIDED');
  assert.equal(byAsset.ETH.inputs.band_status, 'ONE_SIDED');
  assert.equal(byAsset.USDC.inputs.band_status, 'IN_BAND');
});

test('Per-Asset Reconcile on the flagship fixtures gives the documented outcomes', async () => {
  const wallet = { BTC: 167690.25, ETH: 2884112, USDC: 891723456, USDT: 1234567890.5, SOL: 8740000, XRP: 128265000, ADA: 47293847 };
  const ledger = { BTC: 167188.68, ETH: 2847100, USDC: 891723456, USDT: 1234500000, SOL: 9200000, XRP: 127500000, ADA: -150000 };
  const out = await reconcile(wallet, ledger);
  assert.equal(out.length, 7);
  const got = Object.fromEntries(out.map((o) => [o.inputs.asset, [o.policy_outcome, o.policy_sub_tier ?? null]]));
  assert.deepEqual(got, {
    ADA: ['REQUIRE_HUMAN', 'CRITICAL'],
    BTC: ['ALLOW_WITH_OBLIGATIONS', null],
    ETH: ['ALLOW', null],
    SOL: ['REQUIRE_HUMAN', 'CRITICAL'],
    USDC: ['ALLOW', null],
    USDT: ['REQUIRE_HUMAN', 'STANDARD'],
    XRP: ['ALLOW', null],
  });
});

// --- Check Thresholds ----------------------------------------------------------

test('Check Thresholds throws on [{}] and on []', async () => {
  for (const items of [[{}], []]) {
    await assert.rejects(
      runCodeNode(WF, 'Check Thresholds', { items, upstream: { 'Get Materiality Thresholds': items } }),
      /FAO-REC-002/,
      `throws for ${JSON.stringify(items)}`,
    );
  }
});

test('Check Thresholds passes threshold rows through', async () => {
  const out = await runCodeNode(WF, 'Check Thresholds', { items: FIX.thresholds, upstream: { 'Get Materiality Thresholds': FIX.thresholds } });
  assert.equal(out.length, FIX.thresholds.length);
  assert.deepEqual(out.map((o) => o.asset_symbol), FIX.thresholds.map((t) => t.asset_symbol));
});

// --- Check Writer Count --------------------------------------------------------

test('Check Writer Count throws on a mismatch and passes on a match', async () => {
  const perAsset = Array.from({ length: 7 }, (_, i) => ({ event_type: 'ASSET_RECONCILED', inputs: { asset: `A${i}` } }));
  const upstream = { 'Per-Asset Reconcile': perAsset, 'Writer: ASSET_RECONCILED': [{ count: 6, inserted: [] }] };
  await assert.rejects(
    runCodeNode(WF, 'Check Writer Count', { items: [{ count: 6, inserted: [] }], upstream }),
    /FAO-GOV-001 recon: writer stored 6 of 7 asset events/,
  );
  const okUp = { ...upstream, 'Writer: ASSET_RECONCILED': [{ count: 7, inserted: [] }] };
  await assert.doesNotReject(runCodeNode(WF, 'Check Writer Count', { items: [{ count: 7, inserted: [] }], upstream: okUp }));
});

// --- Notify Input ---------------------------------------------------------------

test('Notify Input has exactly hitl_id, kind and level', async () => {
  const r = {
    ok: true, code: 'OK', hitl_required: true, hitl_id: 42, approval_url: 'http://localhost:4173/?hitl_id=42',
    timeout_at: '2026-11-08T00:00:00Z', review_sub_tier: 'CRITICAL', escalated_assets: [{ asset: 'SOL' }],
    invoker_id: CLAIM.invoker_id, invoker_name: 'Aisha Okonkwo',
  };
  const out = await runCodeNode(WF, 'Notify Input', {
    items: [{ r }],
    upstream: { 'Finalize Run': [{ r }], 'Human Review Required?': [{ r }], 'Claim Run': [{ r: CLAIM }] },
  });
  assert.deepEqual(out, [{ hitl_id: 42, kind: 'REQUESTED', level: 0 }]);
});
