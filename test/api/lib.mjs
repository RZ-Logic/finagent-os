// ============================================================================
// FinAgent OS - API test library (local Supabase only)
// ----------------------------------------------------------------------------
// Controls supported: FAO-GOV-001, FAO-GOV-004, FAO-GOV-008, FAO-GOV-015.
//
// Reads .local/test-users.json (written by scripts/local-setup.mjs), refuses
// any URL whose host is not 127.0.0.1 or localhost, signs users in through
// /auth/v1/token?grant_type=password with the public key, calls
// /rest/v1/rpc/* and /rest/v1/<table> with each user's own token, and opens
// pg connections as postgres (assertions, journal reads) and as fao_workflow
// with the generated password (claim, append, finalize, sweep), exactly as
// n8n would. Never contacts a hosted project.
// ============================================================================

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHmac, randomUUID } from 'node:crypto';
import pg from 'pg';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, '..', '..');
const USERS_FILE = join(REPO_ROOT, '.local', 'test-users.json');
const LOCAL_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

export const FLAGSHIP = 'fao_reserve_recon_v1';
export const EMAIL = {
  aisha: 'aisha.okonkwo@finagent-os.demo',
  sarah: 'sarah.chen@finagent-os.demo',
  marcus: 'marcus.patel@finagent-os.demo',
  reader: 'mcp.reader@finagent-os.demo',
  outsider: 'outsider@local.test',
  ratelimit: 'ratelimit@local.test',
};

// Section 2.6 messages.
export const MESSAGES = {
  OK: 'OK',
  NO_SESSION: 'Sign in to continue.',
  INVALID_INPUT: 'The request is not valid.',
  NOT_AN_OWNER: 'Your account is not an active process owner.',
  NOT_AUTHORISED: 'You are not authorised for this action.',
  SOD_SELF_APPROVAL: 'You cannot decide a run you started.',
  SELF_CHANGE: 'You cannot change your own access.',
  NOT_FOUND: 'Not found.',
  UNKNOWN_AGENT: 'The agent does not exist.',
  AGENT_NOT_ACTIVE: 'The agent is not active.',
  INVOKER_NOT_ACTIVE: 'The invoker is no longer authorised for this agent.',
  BUSY: 'Someone else is deciding this request. Try again.',
  NO_RUN_RECORD: 'This request has no run record.',
  ALREADY_CLAIMED: 'This run has already started.',
  ALREADY_DECIDED: 'This request has already been decided.',
  EXPIRED: 'This request has expired.',
  TOKEN_EXPIRED: 'The run token has expired.',
  INVALID_TOKEN: 'The run token is not valid.',
  RATE_LIMITED: 'Too many runs in the last hour.',
  AUDIT_CHAIN_MISMATCH: "Recorded, but the run's ledger chain is incomplete, so it was not committed.",
};

function assertLocal(urlText, label) {
  const u = new URL(urlText);
  if (!LOCAL_HOSTS.has(u.hostname)) {
    throw new Error(`test/api: ${label} host ${u.hostname} is not local; refusing to run against a non-local project`);
  }
  return u;
}

function pick(obj, ...names) {
  for (const n of names) {
    const v = n.split('.').reduce((o, k) => (o && o[k] !== undefined ? o[k] : undefined), obj);
    if (v !== undefined && v !== null && v !== '') return v;
  }
  return undefined;
}

function loadConfig() {
  if (!existsSync(USERS_FILE)) {
    throw new Error('test/api: .local/test-users.json is missing; run npm run db:reset first');
  }
  const j = JSON.parse(readFileSync(USERS_FILE, 'utf8'));
  const apiUrl = String(pick(j, 'api_url', 'apiUrl', 'API_URL', 'supabaseUrl')).replace(/\/+$/, '');
  const dbUrl = pick(j, 'db_url', 'dbUrl', 'DB_URL');
  assertLocal(apiUrl, 'API URL');
  assertLocal(dbUrl, 'DB URL');
  const workflowPassword = pick(j, 'workflow.password', 'workflowPassword', 'workflow_password', 'fao_workflow_password');
  let workflowDbUrl = pick(j, 'workflow.db_url');
  if (!workflowDbUrl) {
    const u = new URL(dbUrl);
    u.username = 'fao_workflow';
    u.password = workflowPassword;
    workflowDbUrl = u.toString();
  }
  assertLocal(workflowDbUrl, 'workflow DB URL');
  const rawUsers = j.users || {};
  const users = {};
  const list = Array.isArray(rawUsers) ? rawUsers : Object.entries(rawUsers).map(([k, u]) => ({ key: k, ...u }));
  for (const u of list) {
    const key = Object.keys(EMAIL).find((k) => EMAIL[k] === String(u.email).toLowerCase()) || u.key;
    users[key] = { id: u.id, email: u.email, password: u.password };
  }
  for (const k of Object.keys(EMAIL)) {
    if (!users[k]) throw new Error(`test/api: test-users.json has no user ${EMAIL[k]}`);
  }
  return {
    apiUrl,
    dbUrl,
    workflowDbUrl,
    publicKey: pick(j, 'public_key', 'publicKey', 'anon_key', 'anonKey'),
    anonJwt: pick(j, 'anon_jwt'),
    serviceKey: pick(j, 'service_key', 'serviceKey', 'serviceRoleKey'),
    serviceJwt: pick(j, 'service_jwt'),
    jwtSecret: pick(j, 'jwt_secret', 'jwtSecret'),
    users,
  };
}

export const cfg = loadConfig();
export const uid = (key) => cfg.users[key].id;

// --- HTTP -------------------------------------------------------------------

export async function http(method, path, { token, apikey = cfg.publicKey, body, headers = {}, noAuthHeader = false } = {}) {
  const h = { apikey, 'Content-Type': 'application/json', Accept: 'application/json', ...headers };
  if (token && !noAuthHeader) h.Authorization = `Bearer ${token}`;
  const res = await fetch(`${cfg.apiUrl}${path}`, {
    method,
    headers: h,
    body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, body: json, text, headers: res.headers };
}

export const rpc = (name, args = {}, opts = {}) => http('POST', `/rest/v1/rpc/${name}`, { ...opts, body: args });
export const rest = (method, table, opts = {}) => http(method, `/rest/v1/${table}${opts.query || ''}`, opts);

const tokenCache = new Map();
export async function signIn(key, { email } = {}) {
  const u = cfg.users[key];
  const em = email || u.email;
  const cacheKey = `${key}:${em}`;
  if (tokenCache.has(cacheKey)) return tokenCache.get(cacheKey);
  const res = await http('POST', '/auth/v1/token?grant_type=password', { body: { email: em, password: u.password } });
  if (res.status !== 200 || !res.body || !res.body.access_token) {
    throw new Error(`test/api: sign-in failed for ${key} (status ${res.status})`);
  }
  tokenCache.set(cacheKey, res.body.access_token);
  return res.body.access_token;
}

export function jwtPayload(token) {
  const part = String(token).split('.')[1] || '';
  return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
}

// HS256 token for negative tests (expired, other secret).
export function forgeJwt(payload, secret) {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const head = b64({ alg: 'HS256', typ: 'JWT' });
  const body = b64(payload);
  const sig = createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}

// --- Database -----------------------------------------------------------------

let ownerPool = null;
let workflowPool = null;
export function owner() {
  if (!ownerPool) ownerPool = new pg.Pool({ connectionString: cfg.dbUrl, max: 3 });
  return ownerPool;
}
export function workflow() {
  if (!workflowPool) workflowPool = new pg.Pool({ connectionString: cfg.workflowDbUrl, max: 2 });
  return workflowPool;
}
export async function closeAll() {
  const p = [];
  if (ownerPool) p.push(ownerPool.end());
  if (workflowPool) p.push(workflowPool.end());
  ownerPool = null;
  workflowPool = null;
  await Promise.all(p);
}

export async function q(sql, params = []) {
  const { rows } = await owner().query(sql, params);
  return rows;
}
export async function one(sql, params = []) {
  const rows = await q(sql, params);
  return rows[0];
}

async function wf(sql, params) {
  const { rows } = await workflow().query(sql, params);
  return rows[0].r;
}
// Fix round 2 R08: the claim names the agent the calling workflow serves.
export const claim = (token, execId = `api-${randomUUID().slice(0, 18)}`, agent = FLAGSHIP) => wf('SELECT public.fao_run_claim($1, $2, $3) AS r', [token, execId, agent]);
export const append = (events) => wf('SELECT public.fao_ledger_append_batch($1::jsonb) AS r', [JSON.stringify(events)]);
export const finalize = (corr) => wf('SELECT public.fao_run_finalize($1::uuid) AS r', [corr]);
export const sweep = () => wf('SELECT public.fao_maintenance_sweep() AS r', []);

export const maxRefusalId = async () => Number((await one('SELECT coalesce(max(refusal_id), 0) AS m FROM public.fao_refusal_journal')).m);
export const journalSince = (id) => q('SELECT * FROM public.fao_refusal_journal WHERE refusal_id > $1 ORDER BY refusal_id', [id]);
export const journalRow = async (ref) => one('SELECT * FROM public.fao_refusal_journal WHERE refusal_id = $1', [ref]);

// --- Runs ---------------------------------------------------------------------

export const newKey = () => `api_${randomUUID().replace(/-/g, '')}`;

export async function startRun(key, { agent = FLAGSHIP, reason = 'api test run', idem = newKey(), via = 'test' } = {}) {
  const token = await signIn(key);
  return rpc('fao_run_start', { p_agent_id: agent, p_reason: reason, p_idempotency_key: idem, p_invoked_via: via }, { token });
}

export function startedEvent(corr, assets) {
  return {
    correlation_id: corr,
    event_type: 'STARTED',
    inputs: { asset_scope: assets, asset_count: assets.length, wallet_source: 'fixtures/wallet_data.json', ledger_source: 'fixtures/ledger_data.json', fixture_provenance: {} },
    policy_outcome: 'ALLOW',
    policy_rationale: 'FAO-GOV-008 api test run started',
    status: 'SUCCESS',
  };
}

export function assetEvent(corr, asset, outcome = 'ALLOW', subTier = null, extra = {}) {
  const review = ['REQUIRE_HUMAN', 'DENY', 'BLOCKED'].includes(outcome);
  return {
    correlation_id: corr,
    event_type: 'ASSET_RECONCILED',
    inputs: { asset, wallet: 100, ledger: 100, ratio: review ? null : 1, discrepancy: 0, band_status: review ? 'BELOW_FLOOR' : 'IN_BAND', threshold: {}, input_problem: null, ...extra },
    policy_outcome: outcome,
    policy_sub_tier: subTier,
    policy_rationale: `api test ${asset} ${outcome}`,
    obligations: outcome === 'ALLOW_WITH_OBLIGATIONS' ? ['weekly_review_required'] : [],
    status: 'SUCCESS',
    hitl_status: review ? 'PENDING' : 'NOT_REQUIRED',
  };
}

// The seven flagship assets from fixtures/, with the documented outcomes.
// Patch round 7 (O1): the USDT surplus of $67,890.50 inside the stablecoin
// band ALLOWs (stablecoin USD materiality is a shortfall test only).
export function flagshipEvents(corr) {
  const wallet = JSON.parse(readFileSync(join(REPO_ROOT, 'fixtures', 'wallet_data.json'), 'utf8')).wallets;
  const ledger = JSON.parse(readFileSync(join(REPO_ROOT, 'fixtures', 'ledger_data.json'), 'utf8')).ledger;
  const outcome = {
    ADA: ['REQUIRE_HUMAN', 'CRITICAL'], BTC: ['ALLOW_WITH_OBLIGATIONS', null], ETH: ['ALLOW', null], SOL: ['REQUIRE_HUMAN', 'CRITICAL'],
    USDC: ['ALLOW', null], USDT: ['ALLOW', null], XRP: ['ALLOW', null],
  };
  const assets = wallet.map((w) => w.asset).sort();
  const events = assets.map((a) => {
    const w = wallet.find((x) => x.asset === a).wallet_balance;
    const l = ledger.find((x) => x.asset === a).client_liabilities;
    const [o, s] = outcome[a];
    const ratio = l > 0 ? w / l : null;
    return assetEvent(corr, a, o, s, { wallet: w, ledger: l, ratio: ['ALLOW', 'ALLOW_WITH_OBLIGATIONS'].includes(o) ? ratio : null, discrepancy: w - l });
  });
  return { assets, events };
}

// Start (as the invoker, through PostgREST), claim and STARTED (as fao_workflow).
export async function makeRun(invokerKey, assets) {
  const s = await startRun(invokerKey);
  if (s.status !== 200 || !s.body || !s.body.run_token) throw new Error(`test/api: run start failed (${s.status} ${s.body && s.body.code})`);
  const c = await claim(s.body.run_token);
  if (!c.ok) throw new Error(`test/api: claim failed (${c.code})`);
  await append([startedEvent(s.body.correlation_id, assets)]);
  return s.body.correlation_id;
}

// A run with one REQUIRE_HUMAN asset taken to AWAITING_HITL; returns { hitlId, corr, approvalUrl }.
export async function makeRequest(invokerKey = 'aisha') {
  const corr = await makeRun(invokerKey, ['USDT']);
  await append([assetEvent(corr, 'USDT', 'REQUIRE_HUMAN', 'STANDARD')]);
  const f = await finalize(corr);
  if (!f.hitl_required || !f.hitl_id) throw new Error('test/api: finalize did not open a request');
  return { hitlId: Number(f.hitl_id), corr, approvalUrl: f.approval_url };
}

export const ledgerTypes = async (corr) => (await q(
  "SELECT inputs->>'event_type' AS t FROM public.shadow_ledger WHERE correlation_id = $1 ORDER BY ledger_id", [corr],
)).map((r) => r.t);

export const FORBIDDEN_TEXT = /invalid input|syntax|violates|relation|function|column/i;
