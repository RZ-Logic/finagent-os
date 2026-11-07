#!/usr/bin/env node
// ============================================================================
// FinAgent OS: local setup after `supabase db reset` (local only, never live)
// ============================================================================
// Control IDs supported:
//   FAO-GOV-004  creates the demo and test users through the local Auth admin
//                API (never by SQL inserts into the Auth schema) and grants
//                their application roles through seed 0007
//   FAO-GOV-008  gives the fao_workflow role LOGIN and a fresh random password
//                (never set by a migration)
//   FAO-GOV-002  runs the configuration seeds, each with a change reason
//
// Steps:
//   1. Reads `supabase status -o json` for the staged workdir and refuses
//      unless the API and DB URLs point at 127.0.0.1 or localhost.
//   2. Creates or updates Aisha, Sarah, Marcus, the MCP reader, Outsider and
//      the rate-limit user with fresh random passwords (email confirmed).
//   3. Connects as postgres and runs seeds 0002, 0003, 0006, 0007, 0008 and
//      local/0099 in order, each file as one query (one transaction). Seeds
//      are skipped when the database is already seeded (run db:reset first
//      for a clean state).
//   4. Lets postgres switch to fao_workflow (SET only, no inherit) and gives
//      fao_workflow LOGIN with a fresh password.
//   5. Installs the pgTAP helpers from supabase/tests/_helpers/install.sql
//      when that file exists.
//   6. Writes .local/test-users.json, approval-app/config.js and
//      .local/mcp.env (all git-ignored) and prints a summary without
//      passwords.
// ============================================================================

import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const WORKDIR = join(ROOT, '.local', 'supabase');
const LOCAL_DIR = join(ROOT, '.local');
const SEEDS_DIR = join(ROOT, 'supabase', 'seeds');
const HELPERS_SQL = join(ROOT, 'supabase', 'tests', '_helpers', 'install.sql');
const DB_CONTAINER = 'supabase_db_finagent-os-local';
const LOCAL_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

// Section 2.13 users. Roles come from seeds 0007 and local/0099, not from here.
export const USERS = [
  { key: 'aisha', email: 'aisha.okonkwo@finagent-os.demo', note: 'invoker, approver' },
  { key: 'sarah', email: 'sarah.chen@finagent-os.demo', note: 'invoker, approver' },
  { key: 'marcus', email: 'marcus.patel@finagent-os.demo', note: 'approver, admin' },
  { key: 'reader', email: 'mcp.reader@finagent-os.demo', note: 'reader (MCP service user)' },
  { key: 'outsider', email: 'outsider@local.test', note: 'no owner row, no role' },
  { key: 'ratelimit', email: 'ratelimit@local.test', note: 'invoker on fao_ratelimit_test_v1 only' },
];

const SEEDS = [
  '0002_process_owners_seed.sql',
  '0003_agent_registry_seed.sql',
  '0006_materiality_thresholds_seed.sql',
  '0007_user_roles_seed.sql',
  '0008_settings_seed.sql',
  'local/0099_local_settings.sql',
];

function fail(msg) {
  console.error(`local-setup: ${msg}`);
  process.exit(1);
}

function supabaseCli(args) {
  // Run the pinned CLI through node directly (no shell on any platform).
  const cli = join(ROOT, 'node_modules', 'supabase', 'dist', 'supabase.js');
  if (!existsSync(cli)) fail('the Supabase CLI is not installed; run npm ci first');
  return spawnSync(process.execPath, [cli, ...args], { cwd: ROOT, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
}

export function parseStatus(stdout) {
  // The CLI may print warnings around the JSON; take the outermost object.
  const start = stdout.indexOf('{');
  const end = stdout.lastIndexOf('}');
  if (start < 0 || end < start) throw new Error('supabase status printed no JSON');
  const s = JSON.parse(stdout.slice(start, end + 1));
  const pick = (...names) => names.map((n) => s[n]).find((v) => typeof v === 'string' && v.length > 0) || null;
  return {
    apiUrl: pick('API_URL', 'api_url'),
    dbUrl: pick('DB_URL', 'db_url'),
    // New key names first, legacy JWT keys as the fallback.
    publicKey: pick('PUBLISHABLE_KEY', 'publishable_key', 'ANON_KEY', 'anon_key'),
    anonJwt: pick('ANON_KEY', 'anon_key'),
    serviceKey: pick('SECRET_KEY', 'secret_key', 'SERVICE_ROLE_KEY', 'service_role_key'),
    serviceJwt: pick('SERVICE_ROLE_KEY', 'service_role_key'),
    jwtSecret: pick('JWT_SECRET', 'jwt_secret'),
  };
}

export function assertLocal(urlText, label) {
  let u;
  try {
    u = new URL(urlText);
  } catch {
    throw new Error(`${label} is not a URL`);
  }
  if (!LOCAL_HOSTS.has(u.hostname)) {
    throw new Error(`${label} host ${u.hostname} is not 127.0.0.1 or localhost; refusing to touch a non-local project`);
  }
  return u;
}

function newPassword() {
  // 32 random bytes, URL-safe: no quoting problems anywhere it is written.
  return randomBytes(32).toString('base64url');
}

async function authAdmin(status, method, path, body) {
  // The legacy service JWT works as both apikey and bearer; with only the new
  // secret key, the gateway accepts it in both headers locally.
  const key = status.serviceJwt || status.serviceKey;
  const res = await fetch(`${status.apiUrl}/auth/v1${path}`, {
    method,
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  if (!res.ok) {
    const detail = json && (json.msg || json.message || json.error_description || json.error);
    throw new Error(`Auth admin ${method} ${path.split('?')[0]} returned ${res.status}${detail ? `: ${detail}` : ''}`);
  }
  return json;
}

async function listAuthUsers(status) {
  const out = [];
  for (let page = 1; page <= 50; page += 1) {
    const json = await authAdmin(status, 'GET', `/admin/users?page=${page}&per_page=200`);
    const users = (json && json.users) || [];
    out.push(...users);
    if (users.length < 200) break;
  }
  return out;
}

async function upsertUsers(status) {
  const existing = await listAuthUsers(status);
  const byEmail = new Map(existing.map((u) => [String(u.email || '').toLowerCase(), u]));
  const result = {};
  for (const spec of USERS) {
    const password = newPassword();
    const found = byEmail.get(spec.email.toLowerCase());
    let user;
    if (found) {
      user = await authAdmin(status, 'PUT', `/admin/users/${found.id}`, { password, email_confirm: true });
    } else {
      user = await authAdmin(status, 'POST', '/admin/users', { email: spec.email, password, email_confirm: true });
    }
    const id = (user && (user.id || (user.user && user.user.id))) || (found && found.id);
    if (!id) throw new Error(`no user id returned for ${spec.email}`);
    result[spec.key] = { id, email: spec.email, password, created: !found };
  }
  return result;
}

async function runSeeds(client) {
  const { rows } = await client.query('SELECT count(*)::int AS n FROM public.process_owners');
  if (rows[0].n > 0) {
    console.log('Seeds: skipped, the database is already seeded (run npm run db:reset for a clean state)');
    return [];
  }
  const ran = [];
  for (const seed of SEEDS) {
    const p = join(SEEDS_DIR, ...seed.split('/'));
    if (!existsSync(p)) throw new Error(`seed file missing: supabase/seeds/${seed}`);
    let sql = readFileSync(p, 'utf8');
    if (sql.charCodeAt(0) === 0xfeff) sql = sql.slice(1); // strip a byte order mark
    try {
      await client.query(sql); // one query: the whole file is one implicit transaction
    } catch (err) {
      throw new Error(`seed ${seed} failed: ${err.message}`);
    }
    ran.push(seed);
  }
  return ran;
}

async function grantWorkflowToPostgres(client) {
  const { rows } = await client.query("SELECT current_setting('server_version_num')::int AS v");
  const stmt = rows[0].v >= 160000
    ? 'GRANT fao_workflow TO postgres WITH INHERIT FALSE, SET TRUE'
    : 'GRANT fao_workflow TO postgres';
  try {
    await client.query(stmt);
    return `${stmt} (as postgres)`;
  } catch (err) {
    if (err.code !== '42501' && err.code !== '0LP01') throw err;
  }
  // The local postgres role may not grant it; supabase_admin can. Local
  // container only.
  const r = spawnSync('docker', ['exec', DB_CONTAINER, 'psql', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-X', '-q', '-c', stmt], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`could not grant fao_workflow to postgres: ${(r.stderr || r.stdout || '').trim()}`);
  return `${stmt} (through docker exec as supabase_admin)`;
}

async function verifyWorkflowSwitch(client) {
  // postgres must be able to SET ROLE fao_workflow (tests use it) without
  // inheriting its privileges.
  await client.query('BEGIN');
  try {
    await client.query('SET LOCAL ROLE fao_workflow');
    const { rows } = await client.query('SELECT current_user AS u');
    if (rows[0].u !== 'fao_workflow') throw new Error('SET ROLE fao_workflow did not take effect');
  } finally {
    await client.query('ROLLBACK');
  }
}

function writeFiles(status, users, workflowPassword, dbUrl) {
  mkdirSync(LOCAL_DIR, { recursive: true });
  const api = status.apiUrl.replace(/\/+$/, '');
  const wf = new URL(dbUrl);
  wf.username = 'fao_workflow';
  wf.password = workflowPassword;

  const testUsers = {
    generated_at: new Date().toISOString(),
    api_url: api,
    rest_url: `${api}/rest/v1`,
    auth_url: `${api}/auth/v1`,
    db_url: dbUrl,
    public_key: status.publicKey,
    anon_jwt: status.anonJwt,
    service_key: status.serviceKey,
    service_jwt: status.serviceJwt,
    jwt_secret: status.jwtSecret,
    workflow: { role: 'fao_workflow', password: workflowPassword, db_url: wf.toString() },
    users: Object.fromEntries(Object.entries(users).map(([k, u]) => [k, { id: u.id, email: u.email, password: u.password }])),
  };
  writeFileSync(join(LOCAL_DIR, 'test-users.json'), `${JSON.stringify(testUsers, null, 2)}\n`);

  const appDir = join(ROOT, 'approval-app');
  mkdirSync(appDir, { recursive: true });
  writeFileSync(join(appDir, 'config.js'),
    '// Generated by scripts/local-setup.mjs for the local stack. Git-ignored; never commit.\n'
    + `window.FAO_CONFIG = ${JSON.stringify({ supabaseUrl: api, supabasePublicKey: status.publicKey }, null, 2)};\n`);

  const mcpEnv = [
    '# Generated by scripts/local-setup.mjs for the local stack. Git-ignored; never commit.',
    '# Copy to mcp/.env to run the MCP server against local Supabase.',
    `SUPABASE_URL=${api}`,
    `SUPABASE_PUBLIC_KEY=${status.publicKey}`,
    `FAO_READER_EMAIL=${users.reader.email}`,
    `FAO_READER_PASSWORD=${users.reader.password}`,
    `FAO_INVOKER_EMAIL=${users.aisha.email}`,
    `FAO_INVOKER_PASSWORD=${users.aisha.password}`,
    'N8N_INVOKE_WEBHOOK_URL=http://127.0.0.1:5678/webhook/fao-recon-invoke',
    `N8N_INVOKE_KEY=${randomBytes(24).toString('base64url')}`,
    '',
  ].join('\n');
  writeFileSync(join(LOCAL_DIR, 'mcp.env'), mcpEnv);
}

async function main() {
  if (!existsSync(join(WORKDIR, 'supabase', 'config.toml'))) {
    fail('the staged workdir is missing; run npm run stage first');
  }
  const st = supabaseCli(['status', '-o', 'json', '--workdir', '.local/supabase']);
  if (st.status !== 0) fail(`supabase status failed (is the stack running? npm run sb:start): ${(st.stderr || '').trim()}`);
  let status;
  try {
    status = parseStatus(st.stdout);
  } catch (err) {
    fail(err.message);
  }
  if (!status.apiUrl || !status.dbUrl || !status.publicKey || !status.serviceKey) {
    fail('supabase status is missing the API URL, DB URL, public key or service key');
  }
  try {
    assertLocal(status.apiUrl, 'API URL');
    assertLocal(status.dbUrl, 'DB URL');
  } catch (err) {
    fail(err.message);
  }

  const users = await upsertUsers(status);

  const client = new pg.Client({ connectionString: status.dbUrl });
  await client.connect();
  let seeds;
  let grantNote;
  const workflowPassword = newPassword();
  let helpers = 'not present (supabase/tests/_helpers/install.sql missing)';
  try {
    const { rows } = await client.query('SELECT current_user AS u');
    if (rows[0].u !== 'postgres') throw new Error(`connected as ${rows[0].u}, expected postgres`);

    seeds = await runSeeds(client);
    grantNote = await grantWorkflowToPostgres(client);
    await client.query(`ALTER ROLE fao_workflow LOGIN PASSWORD ${client.escapeLiteral(workflowPassword)}`);
    await verifyWorkflowSwitch(client);

    if (existsSync(HELPERS_SQL)) {
      let sql = readFileSync(HELPERS_SQL, 'utf8');
      if (sql.charCodeAt(0) === 0xfeff) sql = sql.slice(1);
      await client.query(sql);
      helpers = 'installed from supabase/tests/_helpers/install.sql';
    }
  } finally {
    await client.end();
  }

  writeFiles(status, users, workflowPassword, status.dbUrl);

  console.log('FinAgent OS local setup complete');
  console.log(`  API URL      ${status.apiUrl}`);
  console.log(`  DB URL host  ${new URL(status.dbUrl).host}`);
  console.log('  Users (passwords are only in .local/test-users.json):');
  for (const spec of USERS) {
    const u = users[spec.key];
    console.log(`    ${spec.email.padEnd(32)} ${u.created ? 'created' : 'updated'}  ${u.id}  (${spec.note})`);
  }
  console.log(`  Seeds        ${seeds.length ? seeds.join(', ') : 'none run'}`);
  console.log(`  Workflow     ${grantNote}; fao_workflow LOGIN with a fresh password`);
  console.log(`  pgTAP        ${helpers}`);
  console.log('  Wrote        .local/test-users.json, approval-app/config.js, .local/mcp.env');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => fail(err.message));
}
