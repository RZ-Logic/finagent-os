// ============================================================================
// FinAgent OS - flagship fixtures against the exported Code nodes (F-40)
// Controls: FAO-REC-001, FAO-REC-002, FAO-REC-004, FAO-REC-006, FAO-REC-007.
//
// fixtures/wallet_data.json and fixtures/ledger_data.json are the documented
// reconciliation snapshot; the flagship holds the same values as literals in
// Init Execution. This file proves which values run and that they agree:
//   1. Init Execution's wallet, ledger and provenance equal the two files
//      (so the inline constants are the fixtures, ADA included);
//   2. Check Thresholds and Per-Asset Reconcile, fed Init Execution's own
//      output and the policy_branches.json thresholds (equal to seed 0006),
//      give the outcomes, band statuses and controls fixtures/README.md
//      documents, row by row;
//   3. the STARTED row carries ALLOW and SUCCESS because migration 0014
//      requires it, as fixtures/README.md says.
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { runCodeNode, readJson, REPO_ROOT } from './harness.mjs';

const WF = 'fao_reserve_recon_v1.json';
const WALLET = readJson('fixtures/wallet_data.json');
const LEDGER = readJson('fixtures/ledger_data.json');
const BRANCHES = readJson('fixtures/policy_branches.json');
const README = readFileSync(join(REPO_ROOT, 'fixtures', 'README.md'), 'utf8').replace(/\r\n/g, '\n');
const TOKEN = 'A'.repeat(20) + 'b_c-' + '9'.repeat(19);

const CLAIM = {
  ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null,
  correlation_id: '11111111-2222-4333-8444-555555555555',
  execution_id: '66666666-7777-4888-9999-aaaaaaaaaaaa',
  agent_id: 'fao_reserve_recon_v1',
  risk_tier: 'RED',
};

const byAsset = (rows, field) => Object.fromEntries(rows.map((r) => [r.asset, r[field]]));

async function initOutput() {
  const out = await runCodeNode(WF, 'Init Execution', {
    items: [{ r: CLAIM }],
    upstream: {
      'Claim Run': [{ r: CLAIM }],
      'Claim OK?': [{ r: CLAIM }],
      'Respond 202': [{ r: CLAIM }],
      'Validate Invoke Body': [{ valid: true, run_token: TOKEN, n8n_execution_id: 'test-exec-1' }],
      'Webhook: Invoke': [{ body: { run_token: TOKEN } }],
    },
  });
  assert.equal(out.length, 1);
  // Items cross the n8n task runner as JSON.
  return JSON.parse(JSON.stringify(out[0]));
}

// The README's per-asset table (| Asset | Provenance | Wallet | Ledger | ...).
function readmeTable() {
  const lines = README.split('\n');
  const head = lines.findIndex((l) => /^\|\s*Asset\s*\|\s*Provenance\s*\|/.test(l));
  assert.ok(head >= 0, 'fixtures/README.md has the per-asset table');
  const cols = lines[head].split('|').slice(1, -1).map((c) => c.trim());
  const rows = [];
  for (let i = head + 2; i < lines.length && lines[i].startsWith('|'); i += 1) {
    const cells = lines[i].split('|').slice(1, -1).map((c) => c.trim());
    rows.push(Object.fromEntries(cols.map((c, j) => [c, cells[j]])));
  }
  return rows;
}
const num = (s) => Number(String(s).replace(/,/g, ''));
const PROVENANCE = {
  'Kraken Dec 2025 PoR anchor': 'kraken_por_2025_q4_anchor',
  'Synthetic clean baseline': 'synthetic_clean_baseline',
  'Synthetic anomaly': 'synthetic_anomaly',
};

test('Init Execution runs exactly the wallet and ledger balances of the fixture files', async () => {
  const ev = await initOutput();
  assert.deepEqual(ev._wallet_data, byAsset(WALLET.wallets, 'wallet_balance'));
  assert.deepEqual(ev._ledger_data, byAsset(LEDGER.ledger, 'client_liabilities'));
  assert.equal(ev._wallet_data.ADA, 47293847, 'ADA wallet balance agrees (inline and wallet_data.json)');
  assert.deepEqual(ev.inputs.asset_scope, [...new Set([...WALLET.wallets, ...LEDGER.ledger].map((r) => r.asset))].sort());
  assert.equal(WALLET._meta.scenario_count, ev.inputs.asset_count);
});

test('Init Execution provenance matches the _provenance and _anomaly_control of both files', async () => {
  const ev = await initOutput();
  const meta = ev.inputs.fixture_provenance;
  assert.deepEqual(meta, ev._fixture_metadata);
  for (const file of [WALLET.wallets, LEDGER.ledger]) {
    for (const row of file) {
      assert.equal(meta[row.asset].source, row._provenance, `${row.asset} source`);
      assert.equal(meta[row.asset].control, row._anomaly_control, `${row.asset} control`);
    }
  }
});

test('the README table states the fixture files balances and provenance', () => {
  const rows = readmeTable();
  assert.deepEqual(rows.map((r) => r.Asset).sort(), WALLET.wallets.map((w) => w.asset).sort());
  const wallet = byAsset(WALLET.wallets, 'wallet_balance');
  const ledger = byAsset(LEDGER.ledger, 'client_liabilities');
  const prov = byAsset(WALLET.wallets, '_provenance');
  for (const r of rows) {
    assert.equal(num(r.Wallet), wallet[r.Asset], `${r.Asset} wallet`);
    assert.equal(num(r.Ledger), ledger[r.Asset], `${r.Asset} ledger`);
    assert.equal(PROVENANCE[r.Provenance], prov[r.Asset], `${r.Asset} provenance`);
  }
});

test('policy_branches.json thresholds equal seed 0006 (scope Spot)', () => {
  const seed = readFileSync(join(REPO_ROOT, 'supabase', 'seeds', '0006_materiality_thresholds_seed.sql'), 'utf8');
  const rows = [...seed.matchAll(/\(\s*'([A-Z0-9]+)',\s*'Spot',\s*'([A-Za-z_]+)',\s*([0-9.]+),\s*([0-9.]+),\s*([0-9.]+),\s*([0-9.]+),/g)]
    .map((m) => ({ asset_symbol: m[1], asset_class: m[2], ratio_floor: Number(m[4]), ratio_band_lower: Number(m[5]), ratio_band_upper: Number(m[6]), materiality_usd: Number(m[3]) }))
    .sort((a, b) => a.asset_symbol.localeCompare(b.asset_symbol));
  assert.equal(rows.length, 7, 'seven seeded Spot thresholds');
  const fix = [...BRANCHES.thresholds].sort((a, b) => a.asset_symbol.localeCompare(b.asset_symbol));
  assert.deepEqual(fix, rows);
});

test('Per-Asset Reconcile on Init Execution output gives the README outcomes, band statuses and controls', async () => {
  const ev = await initOutput();
  const thresholds = await runCodeNode(WF, 'Check Thresholds', { items: BRANCHES.thresholds, upstream: { 'Get Materiality Thresholds': BRANCHES.thresholds } });
  const out = await runCodeNode(WF, 'Per-Asset Reconcile', {
    items: thresholds,
    upstream: {
      'Webhook: Invoke': [{ body: { run_token: TOKEN }, headers: {}, query: {} }],
      'Validate Invoke Body': [{ valid: true, run_token: TOKEN, n8n_execution_id: 'test-exec-1' }],
      'Claim Run': [{ r: CLAIM }],
      'Respond 202': [{ r: CLAIM }],
      'Init Execution': [ev],
      'Writer: STARTED': [{ count: 1, inserted: [{ ledger_id: 1, event_type: 'STARTED', asset: null }] }],
      'Get Materiality Thresholds': BRANCHES.thresholds,
      'Check Thresholds': thresholds,
    },
  });
  const rows = readmeTable();
  assert.equal(out.length, rows.length, 'one ASSET_RECONCILED per README row');
  const got = Object.fromEntries(out.map((o) => [o.inputs.asset, o]));
  for (const r of rows) {
    const item = got[r.Asset];
    assert.ok(item, `${r.Asset} reconciled`);
    const m = /^([A-Z_]+)(?:\s*\(([A-Z]+)\))?$/.exec(r['Expected Outcome']);
    assert.ok(m, `README outcome ${r['Expected Outcome']} parses`);
    assert.equal(item.event_type, 'ASSET_RECONCILED');
    assert.equal(item.policy_outcome, m[1], `${r.Asset} outcome`);
    assert.equal(item.policy_sub_tier ?? null, m[2] || null, `${r.Asset} sub-tier`);
    assert.ok(item.policy_rationale.includes(r.Control), `${r.Asset} rationale names ${r.Control}: ${item.policy_rationale}`);
    if (r.Ratio === 'undefined') assert.equal(item.inputs.ratio, null, `${r.Asset} ratio`);
    else assert.ok(Math.abs(item.inputs.ratio - Number(r.Ratio)) < 0.0005, `${r.Asset} ratio ${item.inputs.ratio} vs README ${r.Ratio}`);
  }
  const bands = /the run reaches five band statuses: ([A-Z_, ]+) and ([A-Z_]+)\./.exec(README.replace(/\s+/g, ' '));
  assert.ok(bands, 'README names the five band statuses');
  const documented = [...bands[1].split(',').map((s) => s.trim()), bands[2]].sort();
  assert.deepEqual([...new Set(out.map((o) => o.inputs.band_status))].sort(), documented);
});

test('STARTED carries ALLOW and SUCCESS because migration 0014 requires it, as the README says', async () => {
  const ev = await initOutput();
  assert.equal(ev.event_type, 'STARTED');
  assert.equal(ev.policy_outcome, 'ALLOW');
  assert.equal(ev.status, 'SUCCESS');
  assert.equal(ev.hitl_status, 'NOT_REQUIRED');
  assert.equal(ev.policy_sub_tier, null);
  const sql = readFileSync(join(REPO_ROOT, 'supabase', 'migrations', '20261107_0014_run_rpcs.sql'), 'utf8');
  assert.match(sql, /IF v_et = 'STARTED' THEN[\s\S]{0,600}STARTED must be ALLOW and SUCCESS/, '0014 refuses a STARTED that is not ALLOW and SUCCESS');
  assert.match(README.replace(/\s+/g, ' '), /STARTED must be ALLOW and SUCCESS/, 'fixtures/README.md explains the STARTED outcome');
});
