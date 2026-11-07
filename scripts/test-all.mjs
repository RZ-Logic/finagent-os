#!/usr/bin/env node
// ============================================================================
// FinAgent OS: the single test command (local only, never live)
// ============================================================================
// Runs every test layer and prints one pass/fail summary. Each layer runs as
// a child process; its output is saved to .local/reports/<layer>.log and the
// summary to .local/reports/summary.json.
//
// Control evidence: every control test (FAO-GOV-001 to FAO-GOV-014,
// FAO-REC-*) runs through this command; a skipped or todo test counts as a
// failure, so no control can pass by being skipped.
//
// Layers, in order:
//   exports  node scripts/check-exports.mjs
//   node     node --test --test-reporter=tap "test/node/*.test.mjs"
//   pytest   python -m pytest mcp/tests -q --junitxml=.local/reports/pytest.xml
//   pgtap    supabase test db --workdir .local/supabase
//   api      node --test --test-concurrency=1 --test-reporter=tap "test/api/*.test.mjs"
//   e2e      node scripts/e2e-n8n.mjs (fresh n8n in Docker, real executions,
//            TAP from node --test test/e2e/*.test.mjs)
//
// Flags:
//   --offline       layers exports, node and pytest only (no Docker needed)
//   --no-reset      skip `supabase db reset` and local-setup before DB layers
//   --layer <name>  run only the named layers (repeatable)
//
// A layer passes only when its process exits 0, at least one test ran, and
// nothing was skipped or marked todo. For pgtap, any pgTAP skip() or todo()
// call in the SQL it runs also counts (R23), since pg_prove's non-verbose
// output reports those tests as passed. A layer that cannot start is ERROR.
// CI runs its static, mcp, db and e2e jobs through this command (R25).
// Exit code 0 only when every selected layer passes.
// ============================================================================

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPORTS = join(ROOT, '.local', 'reports');
const WORKDIR_REL = '.local/supabase';
const STAGED_CONFIG = join(ROOT, '.local', 'supabase', 'supabase', 'config.toml');
const ALL_LAYERS = ['exports', 'node', 'pytest', 'pgtap', 'api', 'e2e'];
const OFFLINE_LAYERS = ['exports', 'node', 'pytest'];
const DB_LAYERS = new Set(['pgtap', 'api', 'e2e']);
const LOCAL_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------
export function parseArgs(argv) {
  const opts = { offline: false, reset: true, layers: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--offline') opts.offline = true;
    else if (a === '--no-reset') opts.reset = false;
    else if (a === '--layer' || a.startsWith('--layer=')) {
      const v = a === '--layer' ? argv[++i] : a.slice('--layer='.length);
      if (!ALL_LAYERS.includes(v)) throw new Error(`unknown layer "${v}"; layers are ${ALL_LAYERS.join(', ')}`);
      if (!opts.layers.includes(v)) opts.layers.push(v);
    } else throw new Error(`unknown argument: ${a}`);
  }
  let selected = opts.layers.length ? ALL_LAYERS.filter((l) => opts.layers.includes(l)) : [...ALL_LAYERS];
  if (opts.offline) selected = selected.filter((l) => OFFLINE_LAYERS.includes(l));
  if (selected.length === 0) throw new Error('no layers selected (--offline excludes pgtap, api and e2e)');
  return { ...opts, selected };
}

// ---------------------------------------------------------------------------
// Output parsers (exported for reuse in tests)
// ---------------------------------------------------------------------------

// TAP summary lines from node --test and check-exports: "# pass N" etc.
// Nested subtest summaries are indented; only top-level lines count.
export function parseTap(text) {
  const grab = (name) => {
    const re = new RegExp(`^# ${name} (\\d+)\\s*$`, 'gm');
    let m;
    let last = null;
    while ((m = re.exec(text)) !== null) last = Number(m[1]);
    return last;
  };
  const pass = grab('pass');
  const fail = grab('fail');
  if (pass === null && fail === null) {
    const m = /check-exports: (\d+) checks, (\d+) passed, (\d+) failed/.exec(text);
    if (m) return { found: true, passed: Number(m[2]), failed: Number(m[3]), skipped: 0, todo: 0, cancelled: 0 };
    return { found: false, passed: 0, failed: 0, skipped: 0, todo: 0, cancelled: 0 };
  }
  return {
    found: true,
    passed: pass || 0,
    failed: fail || 0,
    skipped: grab('skipped') || 0,
    todo: grab('todo') || 0,
    cancelled: grab('cancelled') || 0,
  };
}

// JUnit XML from pytest: attributes on <testsuite> (or <testsuites>).
export function parseJunit(xml) {
  const m = /<testsuite\b([^>]*)>/.exec(xml) || /<testsuites\b([^>]*)>/.exec(xml);
  if (!m) return { found: false, passed: 0, failed: 0, skipped: 0, todo: 0 };
  const attr = (name) => {
    const a = new RegExp(`\\b${name}="(\\d+)"`).exec(m[1]);
    return a ? Number(a[1]) : 0;
  };
  const tests = attr('tests');
  const failures = attr('failures');
  const errors = attr('errors');
  const skipped = attr('skipped');
  return { found: true, passed: Math.max(0, tests - failures - errors - skipped), failed: failures + errors, skipped, todo: 0 };
}

// pg_prove summary from `supabase test db`: "Files=3, Tests=48, ..." and
// "Result: PASS|FAIL"; per-file "(Wstat: n Tests: n Failed: n)" lines in the
// failure report. A file with a bad plan or a non-zero exit and no counted
// failure adds one failure, so it can never pass. No summary means ERROR.
export function parsePgProve(text) {
  const files = /Files=(\d+), Tests=(\d+)/.exec(text);
  const result = /^Result: (PASS|FAIL|NOTESTS)\s*$/m.exec(text);
  if (!files || !result) return { found: false, passed: 0, failed: 0, skipped: 0, todo: 0, result: null };
  const tests = Number(files[2]);
  let counted = 0; // failed assertions that are part of Tests=
  let broken = 0;  // files that failed without a counted assertion (bad plan, crash)
  const report = text.split(/^Test Summary Report\s*$/m)[1] || '';
  const blocks = report.split(/\n(?=\S)/);
  for (const b of blocks) {
    const fm = /\(Wstat: \d+(?: \([^)]*\))? Tests: (\d+) Failed: (\d+)\)/.exec(b);
    if (!fm) continue;
    const n = Number(fm[2]);
    if (n > 0) counted += n;
    else if (/Parse errors|Non-zero exit status/.test(b)) broken += 1;
  }
  // R23: `supabase test db` runs pg_prove without --verbose, so a per-test
  // skip prints nothing and a failing todo prints "# Failed (TODO) test N".
  // Both are matched here when they do appear; pgtapSkipCalls() below is the
  // guard that does not depend on the console output.
  const skipM = text.match(/# SKIP|skipped:|^ok \d+ # skip/gim);
  const todoM = text.match(/# TODO|# Failed \(TODO\)|^(?:not )?ok \d+ # TODO/gim);
  if (result[1] === 'FAIL' && counted + broken === 0) broken = 1;
  return {
    found: true,
    passed: Math.max(0, tests - counted),
    failed: counted + broken,
    skipped: skipM ? skipM.length : 0,
    todo: todoM ? todoM.length : 0,
    result: result[1],
  };
}

// R23 (FAO-GOV-001 to FAO-GOV-015 control evidence): pgTAP skip(), todo(),
// todo_start(), todo_end() and in_todo() calls in the SQL the pgtap layer
// runs (the staged tests and the source tests, helpers included). pg_prove's
// non-verbose output reports such tests as passed, so each call found counts
// as a skip or todo and fails the layer. Comments and string literals are
// not exempt (fail closed): a comment that spells such a call fails too.
export function pgtapSkipCalls(sql) {
  const calls = { skip: 0, todo: 0 };
  const re = /\b(skip|todo|todo_start|todo_end|in_todo)\s*\(/gi;
  let m;
  while ((m = re.exec(sql)) !== null) {
    if (m[1].toLowerCase() === 'skip') calls.skip += 1;
    else calls.todo += 1;
  }
  return calls;
}
function sqlFiles(dir) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...sqlFiles(p));
    else if (e.isFile() && e.name.endsWith('.sql')) out.push(p);
  }
  return out;
}
export function scanPgtapSkips(dirs) {
  const total = { skip: 0, todo: 0, files: [] };
  for (const d of dirs) {
    for (const f of sqlFiles(d)) {
      const c = pgtapSkipCalls(readFileSync(f, 'utf8'));
      if (c.skip + c.todo > 0) {
        total.skip += c.skip;
        total.todo += c.todo;
        total.files.push(f.replace(`${ROOT}`, '.'));
      }
    }
  }
  return total;
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------
function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...opts });
  return { status: r.status, out: `${r.stdout || ''}${r.stderr || ''}`, stdout: r.stdout || '', error: r.error };
}

const SUPABASE_JS = join(ROOT, 'node_modules', 'supabase', 'dist', 'supabase.js');
function supabase(args, opts) {
  return run(process.execPath, [SUPABASE_JS, ...args], opts);
}

function findPython() {
  // A git-ignored .venv at the repository root is tried first, then the
  // interpreters on PATH (section 6.1: python, or py -3.12).
  const venv = process.platform === 'win32'
    ? join(ROOT, '.venv', 'Scripts', 'python.exe')
    : join(ROOT, '.venv', 'bin', 'python');
  const candidates = [
    ...(existsSync(venv) ? [[venv, []]] : []),
    ...(process.platform === 'win32'
      ? [['python', []], ['py', ['-3.12']], ['python3', []]]
      : [['python3', []], ['python', []], ['python3.12', []]]),
  ];
  for (const [cmd, pre] of candidates) {
    const r = run(cmd, [...pre, '-c', 'import pytest, sys; print(sys.version.split()[0])']);
    if (r.status === 0) return { cmd, pre, version: r.stdout.trim() };
  }
  return null;
}

function gitCommit() {
  const r = run('git', ['rev-parse', '--short', 'HEAD']);
  if (r.status !== 0) return 'unknown';
  const dirty = run('git', ['status', '--porcelain']);
  return `${r.stdout.trim()}${dirty.status === 0 && dirty.stdout.trim() ? '-dirty' : ''}`;
}

function checkLocalEnv() {
  // Nothing here may point at a hosted project.
  const bad = [];
  for (const [k, v] of Object.entries(process.env)) {
    if (!v) continue;
    if (k === 'SUPABASE_URL' || /^N8N_.*URL$/.test(k) || /^FAO_.*_URL$/.test(k)) {
      try {
        if (!LOCAL_HOSTS.has(new URL(v).hostname)) bad.push(k);
      } catch {
        bad.push(k);
      }
    }
  }
  return bad;
}

// ---------------------------------------------------------------------------
// Preflight for the DB layers
// ---------------------------------------------------------------------------
function preflight(reset, log) {
  if (!existsSync(SUPABASE_JS)) return 'the Supabase CLI is not installed; run npm ci';
  const dk = run('docker', ['info', '--format', '{{.ServerVersion}}']);
  if (dk.error || dk.status !== 0) return 'Docker is not running (docker info failed); start Docker Desktop';
  log.push(`docker server ${dk.stdout.trim()}`);

  if (!existsSync(STAGED_CONFIG)) {
    const st = run(process.execPath, [join(ROOT, 'scripts', 'stage-local-supabase.mjs')]);
    log.push(st.out);
    if (st.status !== 0) return 'staging the local Supabase workdir failed';
  }

  let status = supabase(['status', '-o', 'json', '--workdir', WORKDIR_REL]);
  if (status.status !== 0) {
    log.push('local Supabase is not running; starting it');
    const start = supabase(['start', '--workdir', WORKDIR_REL]);
    log.push(start.out);
    if (start.status !== 0) return 'supabase start failed';
    status = supabase(['status', '-o', 'json', '--workdir', WORKDIR_REL]);
    if (status.status !== 0) return 'supabase status failed after start';
  }
  try {
    const s = status.stdout;
    const j = JSON.parse(s.slice(s.indexOf('{'), s.lastIndexOf('}') + 1));
    for (const k of ['API_URL', 'DB_URL']) {
      if (!j[k] || !LOCAL_HOSTS.has(new URL(j[k]).hostname)) return `supabase status ${k} is not local; refusing`;
    }
  } catch {
    return 'supabase status printed no usable JSON';
  }

  if (reset) {
    const r = supabase(['db', 'reset', '--workdir', WORKDIR_REL]);
    log.push(r.out);
    if (r.status !== 0) return 'supabase db reset failed (see preflight.log)';
    const ls = run(process.execPath, [join(ROOT, 'scripts', 'local-setup.mjs')]);
    log.push(ls.out);
    if (ls.status !== 0) return 'local-setup.mjs failed (see preflight.log)';
  } else if (!existsSync(join(ROOT, '.local', 'test-users.json'))) {
    return '.local/test-users.json is missing; run without --no-reset once';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------
function layerCommand(name, python) {
  switch (name) {
    case 'exports':
      return { cmd: process.execPath, args: [join('scripts', 'check-exports.mjs')], need: join(ROOT, 'scripts', 'check-exports.mjs') };
    case 'node':
      return { cmd: process.execPath, args: ['--test', '--test-reporter=tap', 'test/node/*.test.mjs'], need: join(ROOT, 'test', 'node') };
    case 'pytest':
      return python
        ? { cmd: python.cmd, args: [...python.pre, '-m', 'pytest', 'mcp/tests', '-q', '--junitxml=.local/reports/pytest.xml'], need: join(ROOT, 'mcp', 'tests') }
        : null;
    case 'pgtap':
      return { cmd: process.execPath, args: [SUPABASE_JS, 'test', 'db', '--workdir', WORKDIR_REL], need: STAGED_CONFIG };
    case 'api':
      return { cmd: process.execPath, args: ['--test', '--test-concurrency=1', '--test-reporter=tap', 'test/api/*.test.mjs'], need: join(ROOT, 'test', 'api') };
    case 'e2e':
      return { cmd: process.execPath, args: [join('scripts', 'e2e-n8n.mjs')], need: join(ROOT, 'test', 'e2e') };
    default:
      return null;
  }
}

export function judge(name, proc, counts) {
  if (!counts.found) return { result: 'ERROR', note: 'no test summary in the output' };
  const ran = counts.passed + counts.failed;
  if (proc.status !== 0) return { result: 'FAIL', note: `exit code ${proc.status}` };
  if (counts.failed > 0) return { result: 'FAIL', note: 'failures' };
  if (counts.skipped > 0 || counts.todo > 0 || counts.cancelled > 0) return { result: 'FAIL', note: 'skipped, todo or cancelled tests count as failures' };
  if (ran === 0) return { result: 'FAIL', note: 'no tests ran' };
  return { result: 'PASS', note: '' };
}

function runLayer(name, python) {
  const spec = layerCommand(name, python);
  const logPath = join(REPORTS, `${name}.log`);
  if (!spec) {
    const note = name === 'pytest' ? 'Python with pytest not found (tried .venv, python, py -3.12, python3)' : 'no command';
    writeFileSync(logPath, `${note}\n`);
    return { layer: name, result: 'ERROR', passed: 0, failed: 0, skipped: 0, note };
  }
  if (spec.need && !existsSync(spec.need)) {
    const note = `missing ${spec.need.replace(`${ROOT}`, '.')}`;
    writeFileSync(logPath, `${note}\n`);
    return { layer: name, result: 'ERROR', passed: 0, failed: 0, skipped: 0, note };
  }
  const started = Date.now();
  const proc = run(spec.cmd, spec.args);
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  writeFileSync(logPath, `$ ${[spec.cmd, ...spec.args].join(' ')}\n${proc.out}\n[exit ${proc.status}] ${seconds}s\n`);
  if (proc.error) {
    return { layer: name, result: 'ERROR', passed: 0, failed: 0, skipped: 0, note: `could not start: ${proc.error.code || proc.error.message}` };
  }
  let counts;
  if (name === 'pytest') {
    const xmlPath = join(REPORTS, 'pytest.xml');
    counts = existsSync(xmlPath) ? parseJunit(readFileSync(xmlPath, 'utf8')) : { found: false };
  } else if (name === 'pgtap') {
    counts = parsePgProve(proc.out);
    const calls = scanPgtapSkips([join(ROOT, WORKDIR_REL, 'supabase', 'tests'), join(ROOT, 'supabase', 'tests')]);
    if (calls.skip + calls.todo > 0) {
      counts = { ...counts, skipped: (counts.skipped || 0) + calls.skip, todo: (counts.todo || 0) + calls.todo };
      writeFileSync(logPath, `pgTAP skip or todo calls (R23) in: ${calls.files.join(', ')}\n`, { flag: 'a' });
    }
  } else {
    counts = parseTap(proc.out);
  }
  const verdict = judge(name, proc, { cancelled: 0, ...counts });
  return {
    layer: name,
    result: verdict.result,
    passed: counts.passed || 0,
    failed: counts.failed || 0,
    skipped: (counts.skipped || 0) + (counts.todo || 0) + (counts.cancelled || 0),
    note: verdict.note,
    seconds: Number(seconds),
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function pad(s, n, right = false) {
  const t = String(s);
  return right ? t.padStart(n) : t.padEnd(n);
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`test-all: ${err.message}`);
    process.exit(2);
  }
  mkdirSync(REPORTS, { recursive: true });

  const stamp = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  const commit = gitCommit();
  const results = [];
  const badEnv = checkLocalEnv();

  const python = opts.selected.includes('pytest') ? findPython() : null;
  const wantsDb = opts.selected.some((l) => DB_LAYERS.has(l));
  let dbProblem = null;
  if (badEnv.length) dbProblem = `non-local URL in environment: ${badEnv.join(', ')}`;
  if (wantsDb && !dbProblem) {
    const log = [];
    dbProblem = preflight(opts.reset, log);
    writeFileSync(join(REPORTS, 'preflight.log'), `${log.join('\n')}\n${dbProblem ? `PREFLIGHT ERROR: ${dbProblem}\n` : 'preflight ok\n'}`);
  }

  for (const layer of opts.selected) {
    if (badEnv.length) {
      results.push({ layer, result: 'ERROR', passed: 0, failed: 0, skipped: 0, note: `non-local URL in environment: ${badEnv.join(', ')}` });
      continue;
    }
    if (DB_LAYERS.has(layer) && dbProblem) {
      writeFileSync(join(REPORTS, `${layer}.log`), `not run: ${dbProblem}\n`);
      results.push({ layer, result: 'ERROR', passed: 0, failed: 0, skipped: 0, note: dbProblem });
      continue;
    }
    process.stdout.write(`running ${layer} ...\n`);
    results.push(runLayer(layer, python));
  }

  const overall = {
    result: results.every((r) => r.result === 'PASS') ? 'PASS' : 'FAIL',
    passed: results.reduce((a, r) => a + r.passed, 0),
    failed: results.reduce((a, r) => a + r.failed, 0),
    skipped: results.reduce((a, r) => a + r.skipped, 0),
  };

  const lines = [];
  lines.push(`FinAgent OS test run ${stamp}  commit ${commit}`);
  lines.push(`${pad('Layer', 10)}${pad('Result', 6)}${pad('Passed', 8, true)}${pad('Failed', 8, true)}${pad('Skipped', 9, true)}`);
  for (const r of results) {
    lines.push(`${pad(r.layer, 10)}${pad(r.result, 6)}${pad(r.passed, 8, true)}${pad(r.failed, 8, true)}${pad(r.skipped, 9, true)}${r.note ? `  (${r.note})` : ''}`);
  }
  lines.push(`${pad('OVERALL', 10)}${pad(overall.result, 6)}${pad(overall.passed, 8, true)}${pad(overall.failed, 8, true)}${pad(overall.skipped, 9, true)}`);
  lines.push('Logs: .local/reports/');
  console.log(lines.join('\n'));

  writeFileSync(join(REPORTS, 'summary.json'), `${JSON.stringify({
    started_at: stamp,
    commit,
    flags: { offline: opts.offline, reset: opts.reset, layers: opts.selected },
    python: python ? { command: [python.cmd, ...python.pre].join(' '), version: python.version } : null,
    layers: results,
    overall,
  }, null, 2)}\n`);

  process.exit(overall.result === 'PASS' ? 0 : 1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
