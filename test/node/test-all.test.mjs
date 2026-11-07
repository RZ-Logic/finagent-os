// ============================================================================
// FinAgent OS offline tests: the single test command and the CI pins
// Controls: control evidence for FAO-GOV-001 to FAO-GOV-015 (a skipped or
// todo test can never count as a pass: R23 pgTAP, R25 CI jobs), R29 (the CI
// toolchain is pinned and the Python lock agrees with the direct pins).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parsePgProve, pgtapSkipCalls, scanPgtapSkips, judge } from '../../scripts/test-all.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (rel) => readFileSync(join(ROOT, rel), 'utf8');

// R23: what pg_prove 3.36 prints, non-verbose, for plan(3) with one pass(),
// one skip() and a failing todo (measured in fix round 2 review).
const PG_PROVE_SKIP_TODO = [
  'psql:/t/skip.test.sql:2: NOTICE:  extension "pgtap" already exists, skipping',
  '/t/skip.test.sql .. ',
  '# Failed (TODO) test 3: "failing control"',
  'ok',
  'All tests successful.',
  'Files=1, Tests=3,  0 wallclock secs ( 0.02 usr +  0.00 sys =  0.02 CPU)',
  'Result: PASS',
  '',
].join('\n');

const PG_PROVE_CLEAN = [
  '/t/010_grants.test.sql .. ok',
  'All tests successful.',
  'Files=1, Tests=40,  1 wallclock secs ( 0.02 usr +  0.00 sys =  0.02 CPU)',
  'Result: PASS',
  '',
].join('\n');

test('R23: a failing pgTAP todo in non-verbose pg_prove output fails the layer', () => {
  const c = parsePgProve(PG_PROVE_SKIP_TODO);
  assert.equal(c.found, true);
  assert.ok(c.todo > 0, 'the "# Failed (TODO)" line is counted');
  assert.equal(judge('pgtap', { status: 0 }, { cancelled: 0, ...c }).result, 'FAIL');
});

test('R23: verbose skip and todo lines are counted too', () => {
  const verbose = `ok 1 - a\nok 2 # skip later\nnot ok 3 # TODO known\n${PG_PROVE_CLEAN}`;
  const c = parsePgProve(verbose);
  assert.ok(c.skipped > 0, 'skip line counted');
  assert.ok(c.todo > 0, 'todo line counted');
});

test('R23: clean pg_prove output still passes, and the extension NOTICE is not a skip', () => {
  const c = parsePgProve(`psql: NOTICE:  extension "pgtap" already exists, skipping\n${PG_PROVE_CLEAN}`);
  assert.deepEqual([c.skipped, c.todo, c.failed, c.passed], [0, 0, 0, 40]);
  assert.equal(judge('pgtap', { status: 0 }, { cancelled: 0, ...c }).result, 'PASS');
});

test('R23: pgTAP skip and todo calls in SQL are found whatever pg_prove prints', () => {
  const cases = [
    ["SELECT skip('later', 1);", { skip: 1, todo: 0 }],
    ['SELECT * FROM skip(2);', { skip: 1, todo: 0 }],
    ["SELECT * FROM todo('known', 1);", { skip: 0, todo: 1 }],
    ["SELECT todo_start('x'); SELECT ok(false); SELECT todo_end();", { skip: 0, todo: 2 }],
    ['SELECT in_todo();', { skip: 0, todo: 1 }],
    ["SELECT extensions.skip ( 'later' );", { skip: 1, todo: 0 }],
    ['-- SELECT skip(1); in a comment still counts (fail closed)', { skip: 1, todo: 0 }],
    ["SELECT ok(true, 'skip_reason(x) and todo_list(y) are other names');", { skip: 0, todo: 0 }],
    ["SELECT is(tests.skipped_count(), 0, 'no skip');", { skip: 0, todo: 0 }],
  ];
  for (const [sql, want] of cases) assert.deepEqual(pgtapSkipCalls(sql), want, sql);
});

test('R23: the repository pgTAP tests and helpers hold no skip or todo call', () => {
  const found = scanPgtapSkips([join(ROOT, 'supabase', 'tests')]);
  assert.deepEqual(found, { skip: 0, todo: 0, files: [] });
});

test('R25: every CI test job runs through test-all.mjs, never a bare test command', () => {
  const ci = read('.github/workflows/ci.yml');
  assert.match(ci, /run: node scripts\/test-all\.mjs --layer exports --layer node\b/, 'static job');
  assert.match(ci, /run: node scripts\/test-all\.mjs --layer pytest\b/, 'mcp job');
  assert.match(ci, /run: node scripts\/test-all\.mjs --no-reset --layer pgtap --layer api\b/, 'db job');
  assert.match(ci, /run: node scripts\/test-all\.mjs --no-reset --layer e2e\b/, 'e2e job');
  for (const bare of ['npm run test:node', 'npm run test:py', 'npm run check:exports', 'npm run test:api', 'npm run test:db', 'npm test', 'pytest ', 'node --test']) {
    assert.ok(!ci.includes(`run: ${bare}`), `ci.yml has no bare "${bare}" step`);
  }
});

test('R29: CI pins the runner image, Node and Python to test/env/versions.json', () => {
  const ci = read('.github/workflows/ci.yml');
  const v = JSON.parse(read('test/env/versions.json'));
  assert.match(v.node, /^\d+\.\d+\.\d+$/, 'versions.json node is exact');
  assert.match(v.python, /^\d+\.\d+\.\d+$/, 'versions.json python is exact');
  const runners = [...ci.matchAll(/runs-on: (\S+)/g)].map((m) => m[1]);
  assert.ok(runners.length >= 4, 'four jobs');
  assert.deepEqual([...new Set(runners)], [v.ci_runner], 'every job on the pinned runner');
  const nodes = [...ci.matchAll(/node-version: "([^"]+)"/g)].map((m) => m[1]);
  assert.ok(nodes.length >= 4, 'setup-node in static, mcp, db and e2e');
  assert.deepEqual([...new Set(nodes)], [v.node]);
  const pythons = [...ci.matchAll(/python-version: "([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(pythons)], [v.python]);
  assert.ok(ci.includes(`--require-hashes --no-deps -r ${v.python_lock}`), 'mcp job installs the hashed lock only');
});

test('R29: the hashed Python lock pins exactly the direct versions in mcp/requirements*.txt', () => {
  const v = JSON.parse(read('test/env/versions.json'));
  const lock = read(v.python_lock);
  const pins = new Map();
  for (const m of lock.matchAll(/^([A-Za-z0-9._-]+)==(\S+) \\\n((?:\s+--hash=sha256:[0-9a-f]{64}(?: \\)?\n)+)/gm)) {
    pins.set(m[1].toLowerCase().replace(/[._]/g, '-'), m[2]);
  }
  const entries = (lock.match(/^[A-Za-z0-9._-]+==/gm) || []).length;
  assert.ok(entries > 5, 'lock lists the transitive tree');
  assert.equal(pins.size, entries, 'every lock entry carries sha256 hashes');
  for (const f of ['mcp/requirements.txt', 'mcp/requirements-dev.txt']) {
    for (const line of read(f).split(/\r?\n/)) {
      const t = line.replace(/#.*/, '').trim();
      if (!t) continue;
      const m = /^([A-Za-z0-9._-]+)==(\S+)$/.exec(t);
      assert.ok(m, `${f}: "${t}" is an exact pin`);
      const name = m[1].toLowerCase().replace(/[._]/g, '-');
      assert.equal(pins.get(name), m[2], `${f}: ${m[1]} ${m[2]} matches the lock (regenerate it with the command in its header)`);
    }
  }
});
