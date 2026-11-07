// ============================================================================
// FinAgent OS API tests: input classes in every argument of every client RPC
// Controls: FAO-GOV-001 (refusals journaled; no database error text ever
// returned), FAO-GOV-004 and FAO-GOV-008 (fixed validation before any
// authorization or lookup).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { rpc, signIn, uid, maxRefusalId, journalSince, closeAll, MESSAGES, FORBIDDEN_TEXT, FLAGSHIP } from './lib.mjs';

after(closeAll);

const BIG = 'x'.repeat(100 * 1024);
const CTRL = 'ab\u0001cd';
const SQLISH = "1'; DROP TABLE public.hitl_queue; --";
const JSONISH = '{"hitl_id": 1, "decision": "APPROVED"}';
const OBJ = { injected: true };

// Per argument kind: the classes that are invalid for it. Free text (reasons,
// notes) accepts enum-like, SQL-shaped and JSON-shaped text as plain data, so
// only the length and control-character classes apply there.
const CLASSES = {
  id: { wrong_json_type: OBJ, enum_like: 'PENDING', big: '1'.repeat(100 * 1024), control: '1\u00012', sql: '1 OR 1=1', json: '{"id": 1}' },
  decision: { wrong_json_type: OBJ, enum_like: 'approved', big: BIG, control: 'APPROVED\u0001', sql: "APPROVED'; --", json: '{"d": "APPROVED"}' },
  agent_id: { wrong_json_type: OBJ, enum_like: 'FAO_RESERVE_RECON_V1', big: 'a'.repeat(100 * 1024), control: CTRL, sql: SQLISH, json: JSONISH },
  reason: { big: BIG, control: CTRL },
  notes: { big: BIG, control: CTRL },
  key: { wrong_json_type: OBJ, enum_like: 'APPROVE', big: BIG, control: 'abcdefgh\u0001', sql: "abcdefgh'--", json: JSONISH },
  via: { wrong_json_type: OBJ, enum_like: 'MCP', big: BIG, control: 'mcp\u0001', sql: SQLISH, json: JSONISH },
  symbol: { wrong_json_type: OBJ, enum_like: 'btc', big: 'A'.repeat(100 * 1024), control: 'BTC\u0001', sql: SQLISH, json: JSONISH },
  scope: { wrong_json_type: OBJ, enum_like: 'spot', big: BIG, control: 'Spot\u0001', sql: SQLISH, json: JSONISH },
  asset_class: { wrong_json_type: OBJ, enum_like: 'stablecoin', big: BIG, control: 'Major\u0001', sql: SQLISH, json: JSONISH },
  number: { wrong_json_type: OBJ, enum_like: 'NaN', big: '9'.repeat(100 * 1024), control: '1\u00010', sql: '1; SELECT 1', json: '{"n": 1}' },
  bool: { wrong_json_type: OBJ, enum_like: 'TRUE', big: BIG, control: 'true\u0001', sql: "true' OR '1'='1", json: '{"b": true}' },
  uuid: { wrong_json_type: OBJ, enum_like: 'NULL', big: BIG, control: CTRL, sql: SQLISH, json: JSONISH },
  role: { wrong_json_type: OBJ, enum_like: 'Admin', big: BIG, control: 'admin\u0001', sql: SQLISH, json: JSONISH },
  status: { wrong_json_type: OBJ, enum_like: 'active', big: BIG, control: 'ACTIVE\u0001', sql: SQLISH, json: JSONISH },
};

// Each RPC with a base call whose inputs are valid, and the kind of each argument.
const RPCS = [
  ['fao_run_start', { p_agent_id: ['agent_id', FLAGSHIP], p_reason: ['reason', 'r'], p_idempotency_key: ['key', 'abcdefgh12'], p_invoked_via: ['via', 'test'] }],
  ['fao_hitl_get', { p_hitl_id: ['id', '1'] }],
  ['fao_hitl_decide', { p_hitl_id: ['id', '1'], p_decision: ['decision', 'APPROVED'], p_notes: ['notes', 'n'] }],
  ['fao_ledger_correct', { p_ledger_id: ['id', '1'], p_reason: ['reason', 'r'] }],
  ['fao_admin_set_threshold', {
    p_asset_symbol: ['symbol', 'BTC'], p_scope: ['scope', 'Spot'], p_asset_class: ['asset_class', 'Major'], p_materiality_usd: ['number', '500000'],
    p_ratio_floor: ['number', '1'], p_ratio_band_lower: ['number', '1.05'], p_ratio_band_upper: ['number', '1.25'], p_notes: ['notes', 'n'], p_reason: ['reason', 'r'],
  }],
  ['fao_admin_set_agent', { p_agent_id: ['agent_id', FLAGSHIP], p_status: ['status', 'ACTIVE'], p_ai_advisory_enabled: ['bool', 'false'], p_max_runs_per_hour: ['number', '60'], p_reason: ['reason', 'r'] }],
  ['fao_admin_set_role', { p_user_id: ['uuid', null], p_role: ['role', 'invoker'], p_agent_id: ['agent_id', FLAGSHIP], p_grant: ['bool', 'true'], p_reason: ['reason', 'r'] }],
  ['fao_admin_set_owner_active', { p_user_id: ['uuid', null], p_active: ['bool', 'true'], p_reason: ['reason', 'r'] }],
];

for (const [fn, argSpec] of RPCS) {
  test(`${fn}: every invalid input class in every argument is 400 INVALID_INPUT, journaled once, with no database text`, async () => {
    const token = await signIn('marcus');
    const base = Object.fromEntries(Object.entries(argSpec).map(([k, [, v]]) => [k, v === null ? uid('sarah') : v]));
    let cases = 0;
    for (const [arg, [kind]] of Object.entries(argSpec)) {
      for (const [cls, value] of Object.entries(CLASSES[kind])) {
        const label = `${fn}.${arg} ${cls}`;
        const before = await maxRefusalId();
        const r = await rpc(fn, { ...base, [arg]: value }, { token });
        assert.equal(r.status, 400, `${label}: status ${r.status} ${r.text.slice(0, 120)}`);
        assert.equal(r.body.code, 'INVALID_INPUT', label);
        assert.equal(r.body.message, MESSAGES.INVALID_INPUT, label);
        assert.ok(!FORBIDDEN_TEXT.test(r.text), `${label}: response carries database text`);
        const rows = await journalSince(before);
        assert.equal(rows.length, 1, `${label}: exactly one journal row`);
        assert.equal(rows[0].code, 'INVALID_INPUT', label);
        assert.equal(rows[0].entry_point, `rpc:${fn}`, label);
        assert.equal(Number(rows[0].refusal_id), Number(r.body.ref), label);
        cases += 1;
      }
    }
    assert.ok(cases > 0);
  });
}
