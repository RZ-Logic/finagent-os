// ============================================================================
// FinAgent OS offline lint: pgTAP calls of client RPCs pass a JSON object
// Controls: FAO-GOV-008 and FAO-GOV-001 evidence (IC-18). Every client RPC
// takes one unnamed json body. A call written the old way with one text
// literal, for example fao_hitl_get('0'), still resolves after IC-18 (the
// literal becomes a JSON scalar) and is refused as not_object instead of by
// the field rule it targets, so an INVALID_INPUT assertion could pass for the
// wrong reason. This lint fails when any call of a client RPC in
// supabase/tests/**/*.sql (helpers included) does not start its argument
// with json_build_object( or a '{...}' JSON object literal ('' inside a
// quoted SQL string).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const TESTS = join(ROOT, 'supabase', 'tests');

export const CLIENT_RPCS = [
  'fao_whoami', 'fao_run_start', 'fao_hitl_get', 'fao_hitl_decide', 'fao_ledger_correct',
  'fao_admin_set_threshold', 'fao_admin_set_agent', 'fao_admin_set_role', 'fao_admin_set_owner_active',
];

const TYPE_LIST = /^\s*(?:(?:json|jsonb|text|uuid|bigint|integer|int|numeric|boolean)\s*(?:,\s*(?:json|jsonb|text|uuid|bigint|integer|int|numeric|boolean)\s*)*)?$/i;
const OK_ARG = /^\s*(?:json_build_object\s*\(|'\{|''\{)/i;

// SQL with comments blanked (same length, so offsets and line numbers hold).
export function blankComments(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/--[^\n]*/g, (m) => ' '.repeat(m.length));
}

// Text between the parenthesis at `open` and its matching close (quotes and
// nesting respected well enough for test SQL); the rest of the text when
// unbalanced.
function argText(sql, open) {
  let depth = 0;
  for (let i = open; i < sql.length; i += 1) {
    const c = sql[i];
    if (c === '(') depth += 1;
    else if (c === ')') {
      depth -= 1;
      if (depth === 0) return sql.slice(open + 1, i);
    }
  }
  return sql.slice(open + 1);
}

// Every call of a client RPC whose argument is not a JSON object. A quoted
// signature reference such as 'public.fao_whoami(json)' (regprocedure,
// has_function_privilege) is not a call and is skipped.
export function badCalls(sql) {
  const body = blankComments(sql);
  const re = new RegExp(`(['"]?)((?:public\\.)?)\\b(${CLIENT_RPCS.join('|')})\\s*\\(`, 'g');
  const bad = [];
  let m;
  while ((m = re.exec(body)) !== null) {
    const open = m.index + m[0].length - 1;
    const arg = argText(body, open);
    const quotedName = m[1] !== '' || /['"]$/.test(body.slice(0, m.index + m[1].length));
    if (quotedName && TYPE_LIST.test(arg)) continue;
    if (OK_ARG.test(arg)) continue;
    const line = body.slice(0, m.index).split('\n').length;
    bad.push({ line, call: `${m[3]}(${arg.slice(0, 60).replace(/\s+/g, ' ')}` });
  }
  return bad;
}

function sqlFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...sqlFiles(p));
    else if (e.isFile() && e.name.endsWith('.sql')) out.push(p);
  }
  return out.sort();
}

test('lint self-check: old-style calls are caught and JSON-object calls and signatures pass', () => {
  const caught = [
    "SELECT public.fao_hitl_get('0');",
    'SELECT fao_whoami();',
    "SELECT public.fao_hitl_decide('1', 'APPROVED', NULL);",
    "SELECT throws_ok($$SELECT public.fao_ledger_correct('1', 'r')$$, '42501');",
    "SELECT tests.do_as('sarah', 'SELECT public.fao_hitl_get(''7'')');",
    'SELECT public.fao_run_start(v_body);',
    "SELECT public.fao_admin_set_role('[1]'::json);",
  ];
  for (const s of caught) assert.equal(badCalls(s).length, 1, s);
  const passing = [
    "SELECT public.fao_hitl_get(json_build_object('p_hitl_id', '0'));",
    "SELECT public.fao_whoami('{}'::json);",
    "SELECT public.fao_hitl_decide('{\"p_hitl_id\": \"1\", \"p_decision\": \"a\\u0000b\"}');",
    "SELECT tests.do_as('sarah', 'SELECT public.fao_hitl_get(''{\"p_hitl_id\": \"7\"}''::json)');",
    "SELECT has_function_privilege('anon', 'public.fao_whoami(json)', 'EXECUTE');",
    "SELECT to_regprocedure('public.fao_run_start(text, text, text, text)') IS NULL;",
    "SELECT 'fao_hitl_decide()'::text;",
    '-- fao_hitl_get(p_hitl_id text) in a comment',
    '/* SELECT public.fao_whoami(); */ SELECT 1;',
  ];
  for (const s of passing) assert.deepEqual(badCalls(s), [], s);
});

test('IC-18: every client RPC call in supabase/tests passes a JSON object (json_build_object or a \'{...}\' literal)', () => {
  const files = sqlFiles(TESTS);
  assert.ok(files.length > 10, 'pgTAP files found');
  assert.ok(files.some((f) => f.endsWith(join('_helpers', 'install.sql'))), 'helpers are linted too');
  const problems = [];
  let calls = 0;
  for (const f of files) {
    const sql = readFileSync(f, 'utf8');
    calls += (blankComments(sql).match(new RegExp(`\\b(${CLIENT_RPCS.join('|')})\\s*\\(`, 'g')) || []).length;
    for (const b of badCalls(sql)) problems.push(`${relative(ROOT, f)}:${b.line} ${b.call}`);
  }
  assert.ok(calls > 50, `client RPC calls found (${calls})`);
  assert.deepEqual(problems, [], `calls whose argument is not a JSON object:\n${problems.join('\n')}`);
});
