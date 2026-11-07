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
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { cfg, signIn, rpc, q, one, closeAll, uid, REPO_ROOT } from '../api/lib.mjs';
import { assertLocalTargets, assertLocalEnv, N8N_CONTAINER } from './guard.mjs';

export { cfg, signIn, rpc, q, one, closeAll, uid };

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

export const FLAGSHIP = 'fao_reserve_recon_v1';
export const MARKUP_AGENT = 'fao_e2e_markup_v1';
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

// The test clock is shared by everything on the local stack: set it, run the
// callback, and always clear it again.
export async function withTestClock(offsetSeconds, fn) {
  await ownerTx(async (c) => {
    await c.query("SELECT set_config('fao.change_reason', 'e2e n8n: test clock for the sweeper expiry scenario', true)");
    await c.query(
      `INSERT INTO fao_private.test_clock (id, offset_seconds, reason) VALUES (1, $1, 'e2e n8n sweeper expiry')
       ON CONFLICT (id) DO UPDATE SET offset_seconds = EXCLUDED.offset_seconds, set_at = now(), reason = EXCLUDED.reason`,
      [offsetSeconds],
    );
  });
  try {
    return await fn();
  } finally {
    await ownerTx(async (c) => {
      await c.query("SELECT set_config('fao.change_reason', 'e2e n8n: clear the test clock', true)");
      await c.query('DELETE FROM fao_private.test_clock WHERE id = 1');
    });
  }
}

// Decide as a signed-in user through PostgREST, exactly as the approval page does.
export async function decide(user, hitlId, decision, notes) {
  const token = await signIn(user);
  return rpc('fao_hitl_decide', { p_hitl_id: String(hitlId), p_decision: decision, p_notes: notes === undefined ? null : notes }, { token });
}
