// ============================================================================
// FinAgent OS - Writer Code nodes (writer.json)
// Controls: FAO-GOV-001 (batch validation before the all-or-none append;
// writer-only event types; forbidden keys; stored count check).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runCodeNode } from './harness.mjs';

const WF = 'writer.json';
const CORR = '11111111-2222-4333-8444-555555555555';
const ASSETS = ['ADA', 'BTC', 'ETH', 'SOL', 'USDC', 'USDT'];

function started() {
  return {
    correlation_id: CORR,
    event_type: 'STARTED',
    inputs: { event_type: 'STARTED', asset_scope: ASSETS, asset_count: ASSETS.length, wallet_source: 'test', ledger_source: 'test', fixture_provenance: {} },
    policy_outcome: 'ALLOW',
    policy_sub_tier: null,
    policy_rationale: 'FAO-GOV-008 run started',
    obligations: [],
    status: 'SUCCESS',
    hitl_status: 'NOT_REQUIRED',
  };
}

function asset(sym, outcome = 'ALLOW', sub = null) {
  const review = ['REQUIRE_HUMAN', 'DENY', 'BLOCKED'].includes(outcome);
  return {
    correlation_id: CORR,
    event_type: 'ASSET_RECONCILED',
    inputs: { event_type: 'ASSET_RECONCILED', asset: sym, wallet: 100, ledger: 100, ratio: review ? null : 1, discrepancy: 0, band_status: 'IN_BAND', threshold: {}, input_problem: null },
    policy_outcome: outcome,
    policy_sub_tier: sub,
    policy_rationale: `FAO-REC-006 ${sym} test`,
    obligations: [],
    status: 'SUCCESS',
    hitl_status: review ? 'PENDING' : 'NOT_REQUIRED',
    ai_prompt: null,
    ai_output: null,
    ai_confidence: null,
    fractional_cost_usd: null,
  };
}

const seven = () => [started(), ...ASSETS.map((s) => asset(s))];

async function validate(items) {
  return runCodeNode(WF, 'Validate Batch', { items, upstream: { 'Trigger input schema': items } });
}

test('Validate Batch: 7 items in gives one item with 7 events and expected 7', async () => {
  const out = await validate(seven());
  assert.equal(out.length, 1);
  assert.equal(out[0].expected, 7);
  assert.equal(typeof out[0].events_json, 'string');
  const events = JSON.parse(out[0].events_json);
  assert.equal(events.length, 7);
  assert.deepEqual(events.map((e) => e.event_type), ['STARTED', ...ASSETS.map(() => 'ASSET_RECONCILED')]);
});

test('Validate Batch: item 2 missing policy_rationale throws an error naming item 2', async () => {
  const items = seven();
  delete items[2].policy_rationale;
  await assert.rejects(validate(items), (err) => {
    assert.match(err.message, /^FAO-GOV-001 writer: /);
    assert.match(err.message, /item 2\b/);
    assert.match(err.message, /policy_rationale/);
    assert.ok(!/item [013456]\b/.test(err.message), 'names only the bad item');
    return true;
  });
});

test('Validate Batch: several bad items are all listed in one error', async () => {
  const items = seven();
  delete items[1].policy_rationale;
  items[4].policy_outcome = 'MAYBE';
  items[6].correlation_id = 'not-a-uuid';
  await assert.rejects(validate(items), (err) => {
    assert.match(err.message, /^FAO-GOV-001 writer: /);
    for (const i of [1, 4, 6]) assert.match(err.message, new RegExp(`item ${i}\\b`));
    assert.ok(err.message.includes('; '), 'problems joined by "; "');
    return true;
  });
});

test('Validate Batch refuses forbidden keys', async () => {
  for (const key of ['event_timestamp', 'hitl_approver_id', 'ledger_id', 'corrects_ledger_id']) {
    const items = seven();
    items[3][key] = key === 'event_timestamp' ? '2026-01-01T00:00:00Z' : key === 'hitl_approver_id' ? CORR : 1;
    await assert.rejects(validate(items), (err) => {
      assert.match(err.message, /^FAO-GOV-001 writer: /);
      assert.match(err.message, /item 3\b/);
      return true;
    }, `refuses ${key}`);
  }
});

test('Validate Batch refuses CORRECTION, HITL_* and other non-writer event types', async () => {
  for (const type of ['CORRECTION', 'HITL_REQUESTED', 'HITL_RESOLVED', 'HITL_EXPIRED', 'HITL_ESCALATED', 'COMMITTED', 'COMMIT_BLOCKED', 'RUN_REFUSED', 'NOTIFICATION_SENT', 'started']) {
    const items = seven();
    items[5].event_type = type;
    items[5].inputs.event_type = type;
    await assert.rejects(validate(items), /FAO-GOV-001 writer: .*item 5\b/, `refuses ${type}`);
  }
});

test('Validate Batch enforces the hitl_status rule', async () => {
  const bad = seven();
  bad[1].hitl_status = 'PENDING'; // ALLOW asset with PENDING
  await assert.rejects(validate(bad), /item 1\b/);
  const bad2 = seven();
  bad2[0].hitl_status = 'PENDING'; // STARTED with PENDING
  await assert.rejects(validate(bad2), /item 0\b/);
  const bad3 = seven();
  bad3[2].hitl_status = 'APPROVED';
  await assert.rejects(validate(bad3), /item 2\b/);
  const good = [started(), asset('ADA', 'REQUIRE_HUMAN', 'CRITICAL'), asset('BTC', 'BLOCKED')];
  const out = await validate(good);
  assert.equal(out[0].expected, 3);
});

test('Validate Batch strips keys starting with _', async () => {
  const items = seven().map((it) => ({ ...it, _wallet_data: { BTC: 1 }, _ledger_data: { BTC: 1 }, _fixture_metadata: {} }));
  const out = await validate(items);
  const events = JSON.parse(out[0].events_json);
  for (const e of events) {
    for (const k of Object.keys(e)) assert.ok(!k.startsWith('_'), `event keeps ${k}`);
  }
});

test('Check Inserted throws on a count mismatch and emits count and inserted on a match', async () => {
  const inserted = Array.from({ length: 7 }, (_, i) => ({ ledger_id: 100 + i, event_type: i === 0 ? 'STARTED' : 'ASSET_RECONCILED', asset: i === 0 ? null : ASSETS[i - 1] }));
  const upstream = { 'Validate Batch': [{ events_json: '[]', expected: 7 }] };
  await assert.rejects(
    runCodeNode(WF, 'Check Inserted', { items: [{ r: { ok: true, count: 6, inserted: inserted.slice(0, 6) } }], upstream: { ...upstream, 'Append Ledger Batch': [{ r: { ok: true, count: 6, inserted: inserted.slice(0, 6) } }] } }),
    /FAO-GOV-001 writer: stored 6 of 7/,
  );
  const r = { ok: true, code: 'OK', count: 7, inserted };
  const out = await runCodeNode(WF, 'Check Inserted', { items: [{ r }], upstream: { ...upstream, 'Append Ledger Batch': [{ r }] } });
  assert.equal(out.length, 1);
  assert.equal(out[0].count, 7);
  assert.deepEqual(out[0].inserted, inserted);
});
