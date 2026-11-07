#!/usr/bin/env node
// ============================================================================
// FinAgent OS: n8n end-to-end layer (local only, never live)
// ----------------------------------------------------------------------------
// Builds a fresh n8n 2.x instance in Docker, imports the workflow exports (the
// two harnesses too, never published) and three credentials that point only
// at local services, publishes them, starts
// a fake Slack beside it, then runs test/e2e/*.test.mjs (TAP on stdout).
//
//   node scripts/e2e-n8n.mjs          up, then test (what test-all runs)
//   node scripts/e2e-n8n.mjs up       rebuild and start the e2e instance only
//   node scripts/e2e-n8n.mjs test     run the tests against a running instance
//   node scripts/e2e-n8n.mjs down     remove the containers and the volume
//
// Every run of `up` generates a new N8N_ENCRYPTION_KEY and invoke header key
// (kept in .local/e2e/secrets.json, git-ignored) and starts from an empty
// n8n volume. The containers are left running after the tests.
//
// Containers: finagent-e2e-n8n (n8nio/n8n at test/env/versions.json "n8n",
// attached to the local Supabase docker network, ports bound to 127.0.0.1)
// and finagent-e2e-slack (test/e2e/fake-slack.mjs, sharing n8n's network
// namespace so slack_api_base_url = http://127.0.0.1:8099/api reaches it).
// The guard refuses to start if any URL or host is not local.
// ============================================================================

import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import {
  NETWORK, DB_CONTAINER, N8N_CONTAINER, SLACK_CONTAINER, assertLocalTargets, assertLocalEnv,
} from '../test/e2e/guard.mjs';
import {
  buildWorkflowSet, publishIds, VARIANTS, FLAGSHIP_PATH, SWEEP_PATH, GATEWAY_CALLER_PATH, HARNESSES,
} from '../test/e2e/variants.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const E2E_DIR = join(ROOT, '.local', 'e2e');
const IMPORT_DIR = join(E2E_DIR, 'import');
const SECRETS = join(E2E_DIR, 'secrets.json');
const STATE = join(E2E_DIR, 'state.json');
const USERS_FILE = join(ROOT, '.local', 'test-users.json');
const ENV_FILE = join(ROOT, 'docker', 'n8n', 'e2e.env');
const TEST_DIR = join(ROOT, 'test', 'e2e');
const VOLUME = 'finagent-e2e-n8n-data';
const N8N_PORT = 5679;
const SLACK_PORT = 58099;
const N8N_URL = `http://127.0.0.1:${N8N_PORT}`;
const SLACK_URL = `http://127.0.0.1:${SLACK_PORT}`;

const log = (m) => process.stderr.write(`e2e-n8n: ${m}\n`);

function docker(args, { allowFail = false, timeout = 300000 } = {}) {
  const r = spawnSync('docker', args, { encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024 });
  const out = `${r.stdout || ''}${r.stderr || ''}`;
  if (!allowFail && (r.error || r.status !== 0)) {
    throw new Error(`docker ${args.slice(0, 2).join(' ')} failed (exit ${r.status}): ${out.trim().slice(-2000)}`);
  }
  return { status: r.status, out, stdout: r.stdout || '' };
}

function n8nImage() {
  const v = JSON.parse(readFileSync(join(ROOT, 'test', 'env', 'versions.json'), 'utf8')).n8n;
  if (!/^\d+\.\d+\.\d+$/.test(String(v))) throw new Error(`test/env/versions.json n8n is not an exact version: ${v}`);
  return { version: v, image: `n8nio/n8n:${v}` };
}

function loadUsers() {
  if (!existsSync(USERS_FILE)) throw new Error('.local/test-users.json is missing; run npm run db:reset once');
  return JSON.parse(readFileSync(USERS_FILE, 'utf8'));
}

// FAO-GOV-008 (fix round 2 R09): the highest numeric n8n execution id any run
// on the stack was claimed with. Recorded only. A fresh instance numbers its
// executions from 1 again, so a rerun without a reset reuses ids that earlier
// runs hold, which the database allows since R09 (an id is unique only among
// RUNNING runs). The earlier n8n-exec-seq.cjs workaround that started each
// instance above this value is gone, so every rerun exercises the R09 fix.
async function claimedExecutionMax(users) {
  const client = new pg.Client({ connectionString: users.db_url });
  await client.connect();
  try {
    const { rows } = await client.query(
      "SELECT coalesce(max(n8n_execution_id::bigint), 0) AS m FROM public.run_invocations WHERE n8n_execution_id ~ '^[0-9]{1,15}$'",
    );
    return Number(rows[0].m);
  } finally {
    await client.end();
  }
}

async function guard(users) {
  assertLocalEnv();
  assertLocalTargets([
    ['api_url', users.api_url],
    ['rest_url', users.rest_url],
    ['auth_url', users.auth_url],
    ['db_url', users.db_url],
    ['workflow db_url', users.workflow.db_url],
    ['n8n url', N8N_URL],
    ['fake Slack control url', SLACK_URL],
    ['Postgres credential host', DB_CONTAINER],
  ]);
  // Hosts the workflows will call come from the database: check them too.
  const client = new pg.Client({ connectionString: users.db_url });
  await client.connect();
  try {
    const { rows } = await client.query(
      "SELECT key, value FROM public.fao_settings WHERE key IN ('slack_api_base_url', 'approval_app_base_url') ORDER BY key",
    );
    if (rows.length !== 2) throw new Error('e2e guard: fao_settings is missing slack_api_base_url or approval_app_base_url');
    assertLocalTargets(rows.map((r) => [`fao_settings.${r.key}`, r.value]));
    const slack = rows.find((r) => r.key === 'slack_api_base_url').value;
    if (new URL(slack).port !== '8099') throw new Error(`e2e guard: slack_api_base_url ${slack} does not use port 8099 of the fake Slack`);
  } finally {
    await client.end();
  }
}

function writeImport(users, secrets) {
  rmSync(IMPORT_DIR, { recursive: true, force: true });
  mkdirSync(join(IMPORT_DIR, 'workflows'), { recursive: true });
  const credentials = [
    {
      id: 'FaoPgWorkflow001',
      name: 'FAO Postgres (fao_workflow)',
      type: 'postgres',
      data: {
        host: DB_CONTAINER,
        port: 5432,
        database: 'postgres',
        user: 'fao_workflow',
        password: users.workflow.password,
        ssl: 'disable',
        allowUnauthorizedCerts: false,
        sshTunnel: false,
        maxConnections: 10,
      },
    },
    {
      id: 'FaoInvokeHdr0001',
      name: 'FAO Invoke Header Auth',
      type: 'httpHeaderAuth',
      data: { name: 'X-FAO-Invoke-Key', value: secrets.invoke_key },
    },
    {
      id: 'FaoSlackBot00001',
      name: 'FAO Slack Bot',
      type: 'slackApi',
      data: { accessToken: secrets.slack_token },
    },
  ];
  writeFileSync(join(IMPORT_DIR, 'credentials.json'), JSON.stringify(credentials, null, 2), { mode: 0o600 });
  const set = buildWorkflowSet(ROOT);
  for (const [file, wf] of Object.entries(set)) {
    writeFileSync(join(IMPORT_DIR, 'workflows', file), `${JSON.stringify(wf, null, 2)}\n`);
  }
  return Object.keys(set).length;
}

async function waitFor(label, fn, { timeoutMs = 120000, everyMs = 1000 } = {}) {
  const until = Date.now() + timeoutMs;
  let last;
  while (Date.now() < until) {
    try {
      last = await fn();
      if (last && last.ok) return last;
    } catch (e) {
      last = { error: e.message };
    }
    await new Promise((r) => setTimeout(r, everyMs));
  }
  throw new Error(`timed out waiting for ${label}: ${JSON.stringify(last)}`);
}

async function up() {
  const started = Date.now();
  const users = loadUsers();
  await guard(users);
  const { version, image } = n8nImage();

  const net = docker(['network', 'inspect', NETWORK, '--format', '{{range .Containers}}{{.Name}} {{end}}']);
  if (!net.stdout.split(/\s+/).includes(DB_CONTAINER)) throw new Error(`${DB_CONTAINER} is not on ${NETWORK}`);
  if (docker(['image', 'inspect', image], { allowFail: true }).status !== 0) {
    log(`pulling ${image}`);
    docker(['pull', image], { timeout: 900000 });
  }

  mkdirSync(E2E_DIR, { recursive: true });
  const secrets = {
    generated_at: new Date().toISOString(),
    encryption_key: randomBytes(32).toString('hex'),
    invoke_key: randomBytes(32).toString('base64url'),
    slack_token: `xoxb-e2e-local-${randomBytes(8).toString('hex')}`,
  };
  writeFileSync(SECRETS, `${JSON.stringify(secrets, null, 2)}\n`, { mode: 0o600 });
  const files = writeImport(users, secrets);
  log(`import set written: 3 credentials, ${files} workflows`);

  docker(['rm', '-f', SLACK_CONTAINER, N8N_CONTAINER], { allowFail: true });
  docker(['volume', 'rm', '-f', VOLUME], { allowFail: true });
  docker(['volume', 'create', VOLUME]);

  const common = [
    '--env-file', ENV_FILE,
    '-e', `N8N_ENCRYPTION_KEY=${secrets.encryption_key}`,
    '-v', `${VOLUME}:/home/node/.n8n`,
  ];
  const ids = publishIds();
  const reusedUpTo = await claimedExecutionMax(users);
  const script = [
    'set -e',
    'n8n import:credentials --input=/import/credentials.json',
    'n8n import:workflow --separate --input=/import/workflows',
    ...ids.map((id) => `n8n publish:workflow --id=${id}`),
  ].join('\n');
  const t0 = Date.now();
  const imp = docker([
    'run', '--rm', '--network', 'none', ...common,
    '--mount', `type=bind,source=${IMPORT_DIR},target=/import,readonly`,
    '--entrypoint', 'sh', image, '-c', script,
  ], { allowFail: true, timeout: 600000 });
  writeFileSync(join(E2E_DIR, 'import.log'), imp.out);
  const importProblems = [];
  if (imp.status !== 0) importProblems.push(`import container exit ${imp.status}`);
  if (!/Successfully imported 3 credentials/.test(imp.out)) importProblems.push('credentials not all imported');
  if (!new RegExp(`Successfully imported ${files} workflows`).test(imp.out)) importProblems.push('workflows not all imported');
  if (/Skipped workflow|Skipping credential|could not be imported/i.test(imp.out)) importProblems.push('import skipped items');
  const published = (imp.out.match(/Publishing workflow with ID: /g) || []).length;
  if (published !== ids.length) importProblems.push(`published ${published} of ${ids.length}`);
  if (/An error occurred|Error updating database|^Error/im.test(imp.out)) importProblems.push('error text in the import log');
  if (importProblems.length) throw new Error(`n8n import/publish problems: ${importProblems.join('; ')} (see .local/e2e/import.log)`);
  log(`import and publish done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

  docker([
    'run', '-d', '--name', N8N_CONTAINER, '--network', NETWORK, ...common,
    '-p', `127.0.0.1:${N8N_PORT}:5678`,
    '-p', `127.0.0.1:${SLACK_PORT}:8099`,
    '--mount', `type=bind,source=${TEST_DIR},target=/e2e,readonly`,
    '--label', 'finagent.e2e=1',
    image,
  ]);
  docker([
    'run', '-d', '--name', SLACK_CONTAINER, '--network', `container:${N8N_CONTAINER}`,
    '--mount', `type=bind,source=${TEST_DIR},target=/e2e,readonly`,
    '--label', 'finagent.e2e=1',
    '--entrypoint', 'node', image, '/e2e/fake-slack.mjs',
  ]);

  await waitFor('fake Slack', async () => ({ ok: (await fetch(`${SLACK_URL}/_e2e/health`)).status === 200 }), { timeoutMs: 30000 });
  await waitFor('n8n /healthz', async () => ({ ok: (await fetch(`${N8N_URL}/healthz`)).status === 200 }), { timeoutMs: 180000 });
  const paths = [FLAGSHIP_PATH, SWEEP_PATH, GATEWAY_CALLER_PATH, ...Object.values(VARIANTS).map((v) => v.path)];
  for (const p of paths) {
    // Registered production webhooks answer 403 without the header key.
    await waitFor(`webhook ${p}`, async () => {
      const r = await fetch(`${N8N_URL}/webhook/${p}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
      return { ok: r.status === 403, status: r.status };
    }, { timeoutMs: 120000 });
  }

  const state = {
    started_at: new Date().toISOString(),
    n8n_version: version,
    image,
    n8n_container: N8N_CONTAINER,
    slack_container: SLACK_CONTAINER,
    n8n_url: N8N_URL,
    slack_control_url: SLACK_URL,
    flagship_path: FLAGSHIP_PATH,
    sweep_path: SWEEP_PATH,
    variant_paths: Object.fromEntries(Object.entries(VARIANTS).map(([k, v]) => [k, v.path])),
    gateway_caller_path: GATEWAY_CALLER_PATH,
    // Imported, never published; run with n8n execute (test/e2e S17 to S19).
    harness_ids: Object.fromEntries(Object.entries(HARNESSES).map(([k, v]) => [k, v.id])),
    execution_ids_already_claimed_up_to: reusedUpTo,
    setup_seconds: Number(((Date.now() - started) / 1000).toFixed(1)),
  };
  writeFileSync(STATE, `${JSON.stringify(state, null, 2)}\n`);
  log(`n8n ${version} ready at ${N8N_URL} (container ${N8N_CONTAINER}) in ${state.setup_seconds}s`);
}

function test() {
  const r = spawnSync(process.execPath, ['--test', '--test-concurrency=1', '--test-reporter=tap', 'test/e2e/*.test.mjs'], {
    cwd: ROOT, stdio: 'inherit',
  });
  return r.status === null ? 1 : r.status;
}

function down() {
  docker(['rm', '-f', SLACK_CONTAINER, N8N_CONTAINER], { allowFail: true });
  docker(['volume', 'rm', '-f', VOLUME], { allowFail: true });
  log('removed the e2e containers and volume');
}

async function main() {
  const cmd = process.argv[2] || 'run';
  try {
    if (cmd === 'up') await up();
    else if (cmd === 'test') process.exit(test());
    else if (cmd === 'down') down();
    else if (cmd === 'run') {
      await up();
      process.exit(test());
    } else throw new Error(`unknown command ${cmd}; use up, test, down or run`);
  } catch (e) {
    log(`ERROR ${e.message}`);
    process.exit(1);
  }
}

main();
