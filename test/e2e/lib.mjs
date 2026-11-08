// ============================================================================
// FinAgent OS e2e: helpers for the n8n end-to-end tests (local only)
// ----------------------------------------------------------------------------
// Runs start exactly as the MCP invoke tool starts them: fao_run_start as the
// signed-in invoker through PostgREST, then the token alone is POSTed to the
// n8n production webhook with the invoke header key. Assertions read the
// database as the owner (postgres) and the fake Slack's record. Reuses the
// API test library for sign-in, RPC calls and the owner pool.
// ============================================================================

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import {
  cfg, signIn, rpc, q, one, closeAll, uid, REPO_ROOT, claim, append, finalize, startedEvent, assetEvent,
} from '../api/lib.mjs';
import { assertLocalTargets, assertLocalEnv, N8N_CONTAINER, KONG_CONTAINER } from './guard.mjs';
import { FLAGSHIP_AGENT, MARKUP_AGENT, FLAGSHIP_PATH } from './variants.mjs';

export { cfg, signIn, rpc, q, one, closeAll, uid, claim, append, finalize, startedEvent, assetEvent, REPO_ROOT };

const E2E_DIR = join(REPO_ROOT, '.local', 'e2e');
function readJson(p, what) {
  if (!existsSync(p)) throw new Error(`test/e2e: ${what} missing; run node scripts/e2e-n8n.mjs up first`);
  return JSON.parse(readFileSync(p, 'utf8'));
}
export const state = readJson(join(E2E_DIR, 'state.json'), '.local/e2e/state.json');
const secrets = readJson(join(E2E_DIR, 'secrets.json'), '.local/e2e/secrets.json');
export const SLACK_TOKEN = secrets.slack_token;

assertLocalEnv();
assertLocalTargets([
  ['n8n url', state.n8n_url],
  ['fake Slack control url', state.slack_control_url],
  ['Supabase api url', cfg.apiUrl],
  ['Supabase db url', cfg.dbUrl],
]);

export const FLAGSHIP = FLAGSHIP_AGENT;
export { MARKUP_AGENT };
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const newKey = () => `e2e_${randomUUID().replace(/-/g, '')}`;

// --- HTTP -------------------------------------------------------------------

async function call(url, { method = 'POST', headers = {}, body } = {}) {
  const res = await fetch(url, { method, headers, body });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

export function webhook(path, body, { key = secrets.invoke_key, header = 'X-FAO-Invoke-Key', raw = false } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (key !== null) headers[header] = key;
  return call(`${state.n8n_url}/webhook/${path}`, { headers, body: raw ? body : JSON.stringify(body) });
}

export const sweep = () => webhook(state.sweep_path, {});

export const slack = {
  reset: () => call(`${state.slack_control_url}/_e2e/reset`, { body: '{}' }),
  mode: (mode) => call(`${state.slack_control_url}/_e2e/mode`, { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode }) }),
  requests: async () => (await call(`${state.slack_control_url}/_e2e/requests`, { method: 'GET' })).json.requests,
  // Requests whose text links to this request id.
  forHitl: async (hitlId) => (await slack.requests()).filter((r) => r.json && typeof r.json.text === 'string'
    && r.json.text.includes(`?hitl_id=${hitlId}|`)),
};

// --- Runs -------------------------------------------------------------------

export async function startRun(invoker, { agent = FLAGSHIP, reason = 'e2e n8n run', idem = newKey() } = {}) {
  const token = await signIn(invoker);
  const r = await rpc('fao_run_start', { p_agent_id: agent, p_reason: reason, p_idempotency_key: idem, p_invoked_via: 'test' }, { token });
  if (r.status !== 200 || !r.body || !r.body.run_token) {
    throw new Error(`test/e2e: fao_run_start as ${invoker} failed: ${r.status} ${r.body && r.body.code}`);
  }
  return { corr: r.body.correlation_id, token: r.body.run_token };
}

export const run = (corr) => one('SELECT * FROM public.run_invocations WHERE correlation_id = $1', [corr]);
export const ledger = (corr) => q(
  `SELECT ledger_id, inputs->>'event_type' AS t, inputs, policy_outcome::text AS outcome, policy_sub_tier::text AS sub_tier,
          status::text AS status, hitl_status::text AS hitl_status, error_details, policy_rationale
     FROM public.shadow_ledger WHERE correlation_id = $1 ORDER BY ledger_id`, [corr],
);
export const types = async (corr) => (await ledger(corr)).map((r) => r.t);
export const requests = (corr) => q('SELECT * FROM public.hitl_queue WHERE correlation_id = $1 ORDER BY hitl_id', [corr]);
// Dual approval (S02, S24 to S27): the request's approval rows, in order.
export const approvals = (hitlId) => q(
  'SELECT approval_id, hitl_id, approver_id, approved_at, decision_notes FROM public.hitl_approvals WHERE hitl_id = $1 ORDER BY approval_id',
  [hitlId],
);
// Refusals of fao_hitl_decide journaled for one user, request and code.
export const decideRefusals = async (user, hitlId, code) => Number((await one(
  `SELECT count(*)::int AS n FROM public.fao_refusal_journal
    WHERE entry_point = 'rpc:fao_hitl_decide' AND actor_uid = $1 AND target_key = $2 AND code = $3`,
  [uid(user), String(hitlId), code],
)).n);
export const notifications = (hitlId) => q('SELECT * FROM public.fao_notifications WHERE hitl_id = $1 ORDER BY notification_id', [hitlId]);

export async function waitUntil(label, fn, { timeoutMs = 60000, everyMs = 500 } = {}) {
  const until = Date.now() + timeoutMs;
  let last;
  while (Date.now() < until) {
    last = await fn();
    if (last) return last;
    await sleep(everyMs);
  }
  throw new Error(`test/e2e: timed out waiting for ${label}`);
}

// A run leaves RUNNING: COMMITTED, FAILED, EXPIRED or AWAITING_HITL.
export const waitSettled = (corr, opts) => waitUntil(`run ${corr} to settle`, async () => {
  const r = await run(corr);
  return r && !['REQUESTED', 'RUNNING'].includes(r.state) ? r : null;
}, opts);

// At least n notification attempts recorded for the request.
export const waitNotifications = (hitlId, n = 1, opts) => waitUntil(`${n} notification(s) for ${hitlId}`, async () => {
  const rows = await notifications(hitlId);
  return rows.length >= n ? rows : null;
}, opts);

// --- n8n executions (read from n8n's own SQLite inside the container) -------

export function executions(after = 0) {
  const r = spawnSync('docker', ['exec', N8N_CONTAINER, 'node', '/e2e/n8n-executions.cjs', String(after)], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`test/e2e: reading n8n executions failed: ${r.stderr}`);
  return JSON.parse(r.stdout || '[]');
}
export const lastExecutionId = () => {
  const all = executions(0);
  return all.length ? Number(all[all.length - 1].id) : 0;
};
// Wait until every execution after `after` has stopped, and at least `min` exist.
export const waitExecutions = (after, min = 1, opts) => waitUntil(`${min} n8n execution(s) after ${after}`, async () => {
  const ex = executions(after);
  return ex.length >= min && ex.every((e) => e.stoppedAt) ? ex : null;
}, { timeoutMs: 60000, everyMs: 750, ...opts });

// Round 5 (S16): the id n8n will give its next execution.
export function nextExecutionId() {
  const r = spawnSync('docker', ['exec', N8N_CONTAINER, 'node', '/e2e/n8n-executions.cjs', '--next'], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`test/e2e: reading the next n8n execution id failed: ${r.stderr}`);
  return Number(JSON.parse(r.stdout).next);
}

// Patch round 6 (P4, S23): each imported workflow's stored settings, by id,
// and one environment variable of the e2e n8n container (null when unset).
export function workflowSettings() {
  const r = spawnSync('docker', ['exec', N8N_CONTAINER, 'node', '/e2e/n8n-executions.cjs', '--workflow-settings'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`test/e2e: reading n8n workflow settings failed: ${r.stderr}`);
  return JSON.parse(r.stdout || '{}');
}
export function containerEnv(name) {
  if (!/^[A-Z][A-Z0-9_]{0,63}$/.test(name)) throw new Error(`test/e2e: bad env name ${name}`);
  const r = spawnSync('docker', ['exec', N8N_CONTAINER, 'printenv', name], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
}

// The database clock, so "rows since" never depends on the host clock.
export const dbNow = async () => (await one('SELECT clock_timestamp() AS t')).t;

// Round 5 (K1): workflow_failures rows for one n8n execution id, recorded at
// or after `since` (a fresh instance reuses execution ids, R09).
export const workflowFailures = (executionId, since) => q(
  `SELECT id, recorded_at, source, n8n_execution_id, failed_node, message, outcome, correlation_id
     FROM public.workflow_failures WHERE n8n_execution_id = $1 AND recorded_at >= $2 ORDER BY id`,
  [String(executionId), since],
);

// The error handler cleans node names and messages the same way the database
// does (control characters to spaces, then cut).
export const cleanText = (v, max) => String(v === undefined || v === null ? '' : v).replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, max);

// --- Harnesses (round 5, F-32) ---------------------------------------------
// The harness exports run with `n8n execute` inside the e2e container, the
// way a Manual Trigger workflow runs outside the editor. Only that one
// process gets environment access (N8N_BLOCK_ENV_ACCESS_IN_NODE=false, as
// KNOWN-LIMITS U1 says harnesses need) and the FAO_TEST_* values; the server
// keeps its own settings. The process gets its own task broker port and
// event log name so it shares nothing with the running server but the
// database file. Values go through a 0600 env file under .local/e2e that is
// removed afterwards, never on the command line.
export const HARNESS_TARGETS = {
  supabase: `http://${KONG_CONTAINER}:8000`,
  invoke: `http://127.0.0.1:5678/webhook/${FLAGSHIP_PATH}`,
};

export function harnessEnv(invoker, overrides = {}) {
  const u = cfg.users[invoker];
  const env = {
    FAO_ENV: 'test',
    FAO_TEST_SUPABASE_URL: HARNESS_TARGETS.supabase,
    FAO_TEST_PUBLIC_KEY: cfg.publicKey,
    FAO_TEST_INVOKER_EMAIL: u.email,
    FAO_TEST_INVOKER_PASSWORD: u.password,
    FAO_TEST_INVOKE_URL: HARNESS_TARGETS.invoke,
    FAO_TEST_INVOKE_KEY: secrets.invoke_key,
    ...overrides,
  };
  return env;
}

export function runHarness(workflowId, env, { timeoutMs = 170000 } = {}) {
  const lines = {
    ...env,
    N8N_BLOCK_ENV_ACCESS_IN_NODE: 'false',
    N8N_RUNNERS_BROKER_PORT: '5690',
    N8N_EVENTBUS_LOGWRITER_LOGBASENAME: 'n8nEventLog-harness',
  };
  for (const [k, v] of Object.entries(lines)) {
    if (!/^[A-Z][A-Z0-9_]*$/.test(k) || /[\r\n]/.test(String(v))) throw new Error(`test/e2e: harness env ${k} is not a single line`);
  }
  mkdirSync(E2E_DIR, { recursive: true });
  const file = join(E2E_DIR, `harness-${randomUUID()}.env`);
  writeFileSync(file, `${Object.entries(lines).map(([k, v]) => `${k}=${v}`).join('\n')}\n`, { mode: 0o600 });
  try {
    const r = spawnSync('docker', ['exec', '--env-file', file, N8N_CONTAINER, 'n8n', 'execute', `--id=${workflowId}`, '--rawOutput'], {
      encoding: 'utf8', timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024,
    });
    // The output holds execution data (a session token among it): only the
    // exit status and whether it timed out are returned.
    return { status: r.status, timedOut: !!(r.error && r.error.code === 'ETIMEDOUT') };
  } finally {
    rmSync(file, { force: true });
  }
}

export const brief = (ex) => ex.map((e) => `${e.id}:${e.workflowId}:${e.mode}:${e.status}${e.error ? `(${e.error.node}: ${e.error.message})` : ''}`).join(' ');

// --- Evidence ---------------------------------------------------------------

const EVIDENCE = join(E2E_DIR, 'evidence.json');
export function evidence(scenario, data) {
  mkdirSync(E2E_DIR, { recursive: true });
  let all = {};
  try { all = JSON.parse(readFileSync(EVIDENCE, 'utf8')); } catch { all = {}; }
  all[scenario] = { at: new Date().toISOString(), ...data };
  writeFileSync(EVIDENCE, `${JSON.stringify(all, null, 2)}\n`);
}

// --- Owner-only helpers -----------------------------------------------------

export async function ownerTx(fn) {
  const { owner } = await import('../api/lib.mjs');
  const c = await owner().connect();
  try {
    await c.query('BEGIN');
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// The test clock is shared by everything on the local stack (FAO-GOV-008
// sweep timing; S08). The layer only sets a clock it owns: it refuses to
// start when any clock row is already set (someone else's), inserts its own
// row, and in the finally deletes only that row (matched by its reason), so
// it never overwrites or clears a clock it did not set. While the row is set,
// any sweep on the stack sees the moved clock; S08's own sweep expires every
// overdue request and fails every stale run on the stack (test/e2e/README.md).
const CLOCK_REASON = 'e2e n8n sweeper expiry';
export async function withTestClock(offsetSeconds, fn) {
  await ownerTx(async (c) => {
    const held = await c.query('SELECT reason FROM fao_private.test_clock FOR UPDATE');
    if (held.rows.length > 0) {
      throw new Error(`e2e: the shared test clock is already set (reason "${held.rows[0].reason}"); not overwriting it`);
    }
    await c.query("SELECT set_config('fao.change_reason', 'e2e n8n: test clock for the sweeper expiry scenario', true)");
    await c.query('INSERT INTO fao_private.test_clock (id, offset_seconds, reason) VALUES (1, $1, $2)', [offsetSeconds, CLOCK_REASON]);
  });
  try {
    return await fn();
  } finally {
    await ownerTx(async (c) => {
      await c.query("SELECT set_config('fao.change_reason', 'e2e n8n: clear the test clock', true)");
      await c.query('DELETE FROM fao_private.test_clock WHERE id = 1 AND reason = $1', [CLOCK_REASON]);
    });
  }
}

// Decide as a signed-in user through PostgREST, exactly as the approval page does.
export async function decide(user, hitlId, decision, notes) {
  const token = await signIn(user);
  return rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: decision, p_notes: notes === undefined ? null : notes }, { token });
}
