#!/usr/bin/env node
// ============================================================================
// FinAgent OS - static checks over the n8n workflow exports
// ----------------------------------------------------------------------------
// Controls supported:
//   FAO-GOV-001  ledger writes go only through fao_ledger_append_batch
//   FAO-GOV-004  no export calls the retired decision functions or handler
//   FAO-GOV-007  the notifier posts through the named Slack credential only
//   FAO-GOV-008  runs start only through the authenticated invoke webhook
//
// One check per rule per workflow, plus three global checks: the set of
// exported files, the n8n version the node typeVersion pins were checked
// against (test/env/versions.json), and the README publish order for n8n 2.x
// (workflows/README.md). Output is TAP (ok / not ok lines, then # tests, # pass, # fail,
// # skipped, # todo), so the test runner can count it like the Node layer.
// Exits 1 when any check fails. `--json` prints a JSON report instead.
// Usable as a module: checkExports({ workflowsDir }) returns the report.
// ============================================================================

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, '..');
export const WORKFLOWS_DIR = join(REPO_ROOT, 'workflows');

// --- Fixed facts from the build spec (sections 2.13, 4.0 to 4.7) -----------

export const CREDENTIALS = {
  postgres: { id: 'FaoPgWorkflow001', name: 'FAO Postgres (fao_workflow)' },
  httpHeaderAuth: { id: 'FaoInvokeHdr0001', name: 'FAO Invoke Header Auth' },
  slackApi: { id: 'FaoSlackBot00001', name: 'FAO Slack Bot' },
};
const CREDENTIAL_NAMES = new Set(Object.values(CREDENTIALS).map((c) => c.name));

export const WORKFLOWS = {
  'fao_reserve_recon_v1.json': { id: 'uhB2KjEaJDuviM4D', name: 'fao_reserve_recon_v1', role: 'flagship' },
  'fao_hitl_gateway_v1.json': { id: 'mUAC9qIMkVzlV5qw', name: 'fao_hitl_gateway_v1', role: 'notifier' },
  'writer.json': { id: 'dQslIEVwF3WqMliT', name: 'Writer', role: 'writer' },
  'fao_hitl_sweeper_v1.json': { id: 'FaoSweeperV1x001', name: 'fao_hitl_sweeper_v1', role: 'sweeper' },
  'fao_error_handler_v1.json': { id: 'FaoErrHandlerV01', name: 'fao_error_handler_v1', role: 'error_handler' },
  'test_writer_harness_multi_item.json': { id: 'OV7ukqcVKYfNXKHa', name: 'Test Writer Harness (Multi-Item)', role: 'harness' },
  'test_hitl_gateway_harness.json': { id: 'V87nEh6HALqINIDz', name: 'Test HITL Gateway Harness', role: 'harness' },
};
export const RETIRED_FILES = ['fao_hitl_approval_handler_v2.json'];
const HARNESS_FILES = new Set(['test_writer_harness_multi_item.json', 'test_hitl_gateway_harness.json']);
const FLAGSHIP_FILE = 'fao_reserve_recon_v1.json';
const ERROR_WORKFLOW_ID = 'FaoErrHandlerV01';
const WRITER_ID = 'dQslIEVwF3WqMliT';
const NOTIFIER_ID = 'mUAC9qIMkVzlV5qw';

const T = {
  code: 'n8n-nodes-base.code',
  postgres: 'n8n-nodes-base.postgres',
  webhook: 'n8n-nodes-base.webhook',
  respond: 'n8n-nodes-base.respondToWebhook',
  exec: 'n8n-nodes-base.executeWorkflow',
  execTrigger: 'n8n-nodes-base.executeWorkflowTrigger',
  manual: 'n8n-nodes-base.manualTrigger',
  schedule: 'n8n-nodes-base.scheduleTrigger',
  errorTrigger: 'n8n-nodes-base.errorTrigger',
  http: 'n8n-nodes-base.httpRequest',
  if: 'n8n-nodes-base.if',
  noop: 'n8n-nodes-base.noOp',
  sticky: 'n8n-nodes-base.stickyNote',
};
const ALL_ITEMS = 'runOnceForAllItems';

// FAO-GOV-001 / FAO-GOV-007: the node typeVersion of every node type the
// exports use. The offline mapping model (test/node/exports.test.mjs:
// Execute Workflow 1.3, Execute Workflow Trigger 1.1), the Code-node tests
// and the e2e layer were all run against these versions, and each one was
// checked to be a supported version of its node in the n8n-nodes-base
// package of n8n NODE_VERSIONS_N8N. A node re-added or re-saved in a newer
// editor lands at that node's newest version (in 2.46.6, for example,
// executeWorkflow 1.4, executeWorkflowTrigger 1.3, httpRequest 4.5), whose
// mapping or error-output behaviour may differ; this rule refuses it until
// the model and the e2e layer are re-checked and the pins moved on purpose.
// NODE_VERSIONS_N8N must equal the n8n version in test/env/versions.json.
export const NODE_VERSIONS_N8N = '2.46.6';
export const NODE_TYPE_VERSIONS = {
  [T.code]: 2,
  [T.postgres]: 2.6,
  [T.webhook]: 2,
  [T.respond]: 1.1,
  [T.exec]: 1.3,
  [T.execTrigger]: 1.1,
  [T.manual]: 1,
  [T.schedule]: 1.2,
  [T.errorTrigger]: 1,
  [T.http]: 4.2,
  [T.if]: 2.2,
  [T.noop]: 1,
  [T.sticky]: 1,
};
export const VERSIONS_FILE = join(REPO_ROOT, 'test', 'env', 'versions.json');

// FAO-GOV-007 / FAO-GOV-008: n8n 2.x runs only the published version of a
// sub-workflow or error workflow from a production (webhook or schedule)
// execution, `n8n import:workflow` imports every workflow unpublished, and
// publishing a parent is refused while a sub-workflow it calls is
// unpublished. The production workflows are therefore published one by one
// in this order, each after everything it calls or names as its error
// workflow. The harnesses are never published. workflows/README.md lists the
// same order as `n8n publish:workflow --id=<id>` lines, and each production
// workflow's sticky note says its step.
export const PUBLISH_ORDER = [
  'writer.json',
  'fao_hitl_gateway_v1.json',
  'fao_error_handler_v1.json',
  'fao_hitl_sweeper_v1.json',
  'fao_reserve_recon_v1.json',
];
export const README_FILE = join(WORKFLOWS_DIR, 'README.md');

// Section 4 node names per workflow. `type`, `mode`, `query` (whitespace-free
// substring of the SQL), `target`, `onError` are checked when given.
export const SECTION4 = {
  'fao_reserve_recon_v1.json': {
    present: [
      { name: 'Webhook: Invoke', type: T.webhook },
      { name: 'Validate Invoke Body', type: T.code, mode: ALL_ITEMS },
      { name: 'Body Valid?', type: T.if },
      { name: 'Respond 400', type: T.respond },
      { name: 'Claim Run', type: T.postgres, query: 'public.fao_run_claim($1,$2,$3)' },
      { name: 'Claim OK?', type: T.if },
      { name: 'Respond Claim Refused', type: T.respond },
      { name: 'Respond 202', type: T.respond },
      { name: 'Init Execution', type: T.code, mode: ALL_ITEMS },
      { name: 'Writer: STARTED', type: T.exec, mode: 'once', target: WRITER_ID },
      { name: 'Get Materiality Thresholds', type: T.postgres, query: '$1::public.attestation_scope', alwaysOutputData: true },
      { name: 'Check Thresholds', type: T.code, mode: ALL_ITEMS },
      { name: 'Per-Asset Reconcile', type: T.code, mode: ALL_ITEMS },
      { name: 'Writer: ASSET_RECONCILED', type: T.exec, mode: 'once', target: WRITER_ID },
      { name: 'Check Writer Count', type: T.code, mode: ALL_ITEMS },
      { name: 'Finalize Run', type: T.postgres, query: 'public.fao_run_finalize($1::uuid)' },
      { name: 'Human Review Required?', type: T.if },
      { name: 'Run Complete', type: T.noop },
      { name: 'Notify Input', type: T.code, mode: ALL_ITEMS },
      { name: 'HITL Gateway', type: T.exec, mode: 'once', target: NOTIFIER_ID },
      { name: 'Architecture Note', type: T.sticky },
    ],
    absent: ['Manual Trigger', 'Aggregate Rollup', 'Any HITL Required?', 'Writer: COMMITTED', 'Compose HITL Gateway Payload'],
  },
  'fao_hitl_gateway_v1.json': {
    present: [
      { name: 'Trigger input schema', type: T.execTrigger },
      { name: 'Validate Payload', type: T.code, mode: ALL_ITEMS },
      { name: 'Get Notification Context', type: T.postgres, query: 'public.fao_notification_context($1::bigint,$2,$3::int)' },
      { name: 'Should Send?', type: T.if },
      { name: 'Nothing To Send', type: T.noop },
      { name: 'Compose Slack Message', type: T.code, mode: ALL_ITEMS },
      { name: 'Compose OK?', type: T.if },
      { name: 'Slack: Post Message', type: T.http, onError: 'continueErrorOutput' },
      { name: 'Classify Slack Result', type: T.code, mode: ALL_ITEMS },
      { name: 'Record Notification', type: T.postgres, query: "public.fao_notification_record($1::bigint,$2,$3::int,$4,'slack',$5,$6)" },
    ],
    absent: ['Insert HITL Row', 'Validate Insert + Compose', 'Slack: HITL Notification', 'Compose Writer Payload', 'Writer: HITL_REQUESTED'],
    // FAO-GOV-007: every path after Compose ends in Record Notification, so
    // an unusable setting and every Slack outcome are recorded attempts.
    edges: [
      ['Compose Slack Message', 0, 'Compose OK?'],
      ['Compose OK?', 0, 'Slack: Post Message'],
      ['Compose OK?', 1, 'Classify Slack Result'],
      ['Slack: Post Message', 0, 'Classify Slack Result'],
      ['Slack: Post Message', 1, 'Classify Slack Result'],
      ['Classify Slack Result', 0, 'Record Notification'],
    ],
  },
  'writer.json': {
    present: [
      { name: 'Trigger input schema', type: T.execTrigger },
      { name: 'Validate Batch', type: T.code, mode: ALL_ITEMS },
      { name: 'Append Ledger Batch', type: T.postgres, query: 'public.fao_ledger_append_batch($1::jsonb)' },
      { name: 'Check Inserted', type: T.code, mode: ALL_ITEMS },
    ],
    absent: ['Validate Payload', 'Insert Ledger Row'],
  },
  'fao_hitl_sweeper_v1.json': {
    present: [
      { name: 'Schedule Trigger', type: T.schedule },
      { name: 'Run Sweep', type: T.postgres, query: 'public.fao_maintenance_sweep()' },
      { name: 'Expand Notifications', type: T.code, mode: ALL_ITEMS },
      { name: 'HITL Gateway', type: T.exec, mode: 'each', target: NOTIFIER_ID, onError: 'continueRegularOutput' },
      { name: 'Check Notifier Results', type: T.code, mode: ALL_ITEMS },
      { name: 'Check Sweep Errors', type: T.code, mode: ALL_ITEMS },
    ],
    absent: [],
    // FAO-GOV-007: the gateway's swallowed errors are read after every item
    // was attempted; FAO-GOV-008: sweep item errors on their own branch.
    edges: [
      ['Run Sweep', 0, 'Expand Notifications'],
      ['Run Sweep', 0, 'Check Sweep Errors'],
      ['Expand Notifications', 0, 'HITL Gateway'],
      ['HITL Gateway', 0, 'Check Notifier Results'],
    ],
  },
  'fao_error_handler_v1.json': {
    present: [
      { name: 'Error Trigger', type: T.errorTrigger },
      { name: 'Extract Failure', type: T.code, mode: ALL_ITEMS },
      { name: 'Record Run Failure', type: T.postgres, query: 'public.fao_run_fail($1,$2,$3)' },
    ],
    absent: [],
  },
  'test_writer_harness_multi_item.json': {
    present: [
      { name: 'Assert Test Environment', type: T.code },
      { name: 'Sign In', type: T.http },
      { name: 'Start Run', type: T.http },
      { name: 'Claim', type: T.postgres, query: 'public.fao_run_claim($1,$2,$3)' },
      { name: 'Assert Results', type: T.code },
      { name: 'Close Run', type: T.postgres, query: 'public.fao_run_fail(' },
    ],
    absent: [],
  },
  'test_hitl_gateway_harness.json': {
    present: [
      { name: 'Assert Test Environment', type: T.code },
      { name: 'Sign In', type: T.http },
      { name: 'Start Run', type: T.http },
      { name: 'Post Token', type: T.http },
      { name: 'Assert Accepted', type: T.code },
    ],
    absent: [],
  },
};

const RETIRED_STRINGS = ['fao_hitl_resolve', 'fao_hitl_create', 'fao_hitl_approval_handler', 'Vh67T849XENVGttf', 'Postgres account', 'Slack account'];

// Secret-shaped strings. Word boundaries keep ordinary words such as
// "risk-tier" from matching the `sk-` prefix.
const SECRET_PATTERNS = [
  { label: 'xox', re: /\bxox/i },
  { label: 'eyJ', re: /\beyJ/ },
  { label: 'sb_secret_', re: /sb_secret_/ },
  { label: 'sb_publishable_', re: /sb_publishable_/ },
  { label: 'sk-', re: /\bsk-/ },
  { label: 'password=', re: /password=/i },
];

// --- Helpers ----------------------------------------------------------------

const squash = (s) => String(s || '').replace(/\s+/g, '');
const nodesOf = (wf) => (Array.isArray(wf && wf.nodes) ? wf.nodes : []);
const params = (n) => (n && n.parameters) || {};

function targetId(node) {
  const w = params(node).workflowId;
  if (w && typeof w === 'object') return w.value != null ? String(w.value) : null;
  return w != null ? String(w) : null;
}

function credentialRefs(node) {
  const out = [];
  const creds = (node && node.credentials) || {};
  for (const [type, ref] of Object.entries(creds)) {
    out.push({ type, id: ref && ref.id, name: ref && ref.name });
  }
  return out;
}

function queryReplacement(node) {
  const o = params(node).options || {};
  return o.queryReplacement;
}

// --- Rules ------------------------------------------------------------------
// Each rule: (ctx) => array of violation strings (empty means pass).
// ctx = { file, wf (parsed or null), raw, parseError, exportedIds,
//         exportedById (workflow id -> parsed workflow) }.

export const RULES = [
  {
    id: 'parses',
    text: 'workflow parses as JSON with a nodes array',
    run: ({ wf, parseError }) => {
      if (parseError) return [`does not parse: ${parseError}`];
      if (!Array.isArray(wf.nodes)) return ['has no nodes array'];
      return [];
    },
  },
  {
    id: 'no_template_in_query',
    text: 'no {{ inside any Postgres query',
    run: ({ wf }) => nodesOf(wf)
      .filter((n) => n.type === T.postgres && String(params(n).query || '').includes('{{'))
      .map((n) => `node "${n.name}": query contains {{`),
  },
  {
    id: 'query_replacement',
    text: 'every Postgres query using $n has options.queryReplacement',
    run: ({ wf }) => nodesOf(wf)
      .filter((n) => n.type === T.postgres)
      .flatMap((n) => {
        const q = String(params(n).query || '');
        const v = [];
        if (params(n).operation !== 'executeQuery') v.push(`node "${n.name}": operation is not executeQuery`);
        if (/\$\d+/.test(q)) {
          const qr = queryReplacement(n);
          if (typeof qr !== 'string' || !qr.trim()) v.push(`node "${n.name}": uses $n parameters without queryReplacement`);
        }
        return v;
      }),
  },
  {
    id: 'postgres_credential',
    text: 'every Postgres node uses FAO Postgres (fao_workflow)',
    run: ({ wf }) => nodesOf(wf)
      .filter((n) => n.type === T.postgres)
      .flatMap((n) => {
        const ref = ((n.credentials || {}).postgres) || {};
        return (ref.name === CREDENTIALS.postgres.name && ref.id === CREDENTIALS.postgres.id)
          ? [] : [`node "${n.name}": Postgres credential is not ${CREDENTIALS.postgres.name} (${CREDENTIALS.postgres.id})`];
      }),
  },
  {
    id: 'webhook_auth',
    text: 'every webhook has authentication',
    run: ({ wf }) => nodesOf(wf)
      .filter((n) => n.type === T.webhook)
      .flatMap((n) => {
        const a = params(n).authentication;
        return (typeof a === 'string' && a && a !== 'none') ? [] : [`node "${n.name}": webhook has no authentication`];
      }),
  },
  {
    id: 'manual_trigger',
    text: 'no Manual Trigger outside the two harnesses',
    run: ({ file, wf }) => (HARNESS_FILES.has(file) ? [] : nodesOf(wf)
      .filter((n) => n.type === T.manual)
      .map((n) => `node "${n.name}": Manual Trigger outside a harness`)),
  },
  {
    id: 'harness_guard',
    text: 'harnesses start with Assert Test Environment',
    run: ({ file, wf }) => {
      if (!HARNESS_FILES.has(file)) return [];
      const v = [];
      const triggers = nodesOf(wf).filter((n) => n.type === T.manual);
      if (triggers.length !== 1) v.push(`expected exactly one Manual Trigger, found ${triggers.length}`);
      for (const t of triggers) {
        const first = (((wf.connections || {})[t.name] || {}).main || [[]])[0] || [];
        const names = first.map((c) => c.node);
        if (names.length !== 1 || names[0] !== 'Assert Test Environment') {
          v.push(`trigger "${t.name}" does not lead only to Assert Test Environment`);
        }
      }
      const guard = nodesOf(wf).find((n) => n.name === 'Assert Test Environment');
      const code = guard ? String(params(guard).jsCode || '') : '';
      if (!guard || guard.type !== T.code || !/FAO_ENV/.test(code) || !/['"`]test['"`]/.test(code) || !/throw/.test(code)) {
        v.push('Assert Test Environment is missing or does not throw unless $env.FAO_ENV is test');
      }
      return v;
    },
  },
  {
    id: 'execute_workflow_targets',
    text: 'every Execute Workflow target is an exported workflow and has mode',
    run: ({ wf, exportedIds }) => nodesOf(wf)
      .filter((n) => n.type === T.exec)
      .flatMap((n) => {
        const v = [];
        const id = targetId(n);
        if (!id || !exportedIds.has(id)) v.push(`node "${n.name}": target ${id || '(none)'} is not an exported workflow`);
        const m = params(n).mode;
        if (m !== 'once' && m !== 'each') v.push(`node "${n.name}": mode is not set to once or each`);
        return v;
      }),
  },
  {
    // FAO-GOV-001 / FAO-GOV-007: a sub-workflow call must not depend on
    // pass-through of the parent item. n8n merges the mapped values over the
    // parent item ({...json, ...value}), so a mapping the editor refills with
    // nulls or fixed values would overwrite every Writer event or notifier
    // input. Each field of the target trigger's jsonExample is mapped by the
    // expression ={{ $json.<field> }}, with a schema entry of the type n8n
    // infers from the example (no type for a null example value, which n8n
    // reads as "any"), and attemptToConvertTypes off so nothing is cast.
    id: 'execute_workflow_inputs',
    text: 'every Execute Workflow node maps each target trigger field explicitly',
    run: ({ wf, exportedById }) => nodesOf(wf)
      .filter((n) => n.type === T.exec)
      .flatMap((n) => checkWorkflowInputs(n, exportedById ? exportedById.get(targetId(n)) : null)),
  },
  {
    id: 'error_workflow',
    text: 'errorWorkflow set on the flagship and nothing else',
    run: ({ file, wf }) => {
      const ew = (wf.settings || {}).errorWorkflow;
      if (file === FLAGSHIP_FILE) {
        return ew === ERROR_WORKFLOW_ID ? [] : [`settings.errorWorkflow is ${ew || '(unset)'}, expected ${ERROR_WORKFLOW_ID}`];
      }
      return (ew === undefined || ew === null || ew === '') ? [] : [`settings.errorWorkflow is set (${ew}) outside the flagship`];
    },
  },
  {
    id: 'code_mode',
    text: 'every Code node has mode',
    run: ({ wf }) => nodesOf(wf)
      .filter((n) => n.type === T.code)
      .flatMap((n) => {
        const m = params(n).mode;
        return (m === 'runOnceForAllItems' || m === 'runOnceForEachItem') ? [] : [`node "${n.name}": Code node mode not set`];
      }),
  },
  {
    id: 'credential_names',
    text: 'only the three 2.13 credential names (with their placeholder ids) appear',
    run: ({ wf }) => nodesOf(wf).flatMap((n) => credentialRefs(n).flatMap((ref) => {
      const expected = CREDENTIALS[ref.type];
      if (!CREDENTIAL_NAMES.has(ref.name)) return [`node "${n.name}": credential name "${ref.name}" is not allowed`];
      if (!expected || expected.name !== ref.name || expected.id !== ref.id) {
        return [`node "${n.name}": credential ${ref.type} "${ref.name}" (${ref.id}) does not match the fixed placeholder`];
      }
      return [];
    })),
  },
  {
    id: 'retired_references',
    text: 'no reference to retired functions, the handler, the old credential id or names',
    run: ({ raw }) => RETIRED_STRINGS.filter((s) => raw.includes(s)).map((s) => `contains "${s}"`),
  },
  {
    id: 'no_secrets',
    text: 'no secret-shaped string',
    run: ({ raw }) => SECRET_PATTERNS.filter((p) => p.re.test(raw)).map((p) => `contains a ${p.label} shaped string`),
  },
  {
    id: 'section4_nodes',
    text: 'workflow id, name and the section 4 node names, types and modes',
    run: ({ file, wf }) => {
      const v = [];
      const meta = WORKFLOWS[file];
      if (!meta) return [`unexpected workflow file ${file}`];
      if (wf.id !== meta.id) v.push(`workflow id is ${wf.id}, expected ${meta.id}`);
      if (wf.name !== meta.name) v.push(`workflow name is ${JSON.stringify(wf.name)}, expected ${JSON.stringify(meta.name)}`);
      const spec = SECTION4[file] || { present: [], absent: [] };
      const byName = new Map(nodesOf(wf).map((n) => [n.name, n]));
      for (const s of spec.present) {
        const n = byName.get(s.name);
        if (!n) { v.push(`missing node "${s.name}"`); continue; }
        if (s.type && n.type !== s.type) v.push(`node "${s.name}": type ${n.type}, expected ${s.type}`);
        if (s.mode && params(n).mode !== s.mode) v.push(`node "${s.name}": mode ${params(n).mode || '(unset)'}, expected ${s.mode}`);
        if (s.query && !squash(params(n).query).includes(squash(s.query))) v.push(`node "${s.name}": query does not contain ${s.query}`);
        if (s.target && targetId(n) !== s.target) v.push(`node "${s.name}": target ${targetId(n)}, expected ${s.target}`);
        if (s.onError && n.onError !== s.onError) v.push(`node "${s.name}": onError ${n.onError || '(unset)'}, expected ${s.onError}`);
        if (s.alwaysOutputData && n.alwaysOutputData !== true) v.push(`node "${s.name}": alwaysOutputData is not true`);
      }
      for (const name of spec.absent) {
        if (byName.has(name)) v.push(`node "${name}" should have been removed`);
      }
      for (const [from, out, to] of spec.edges || []) {
        const targets = ((((wf.connections || {})[from] || {}).main || [])[out] || []).map((c) => c && c.node);
        if (!targets.includes(to)) v.push(`no connection "${from}" output ${out} -> "${to}"`);
      }
      if (file === FLAGSHIP_FILE) v.push(...checkInvokeWebhook(byName.get('Webhook: Invoke')));
      if (file === 'fao_hitl_gateway_v1.json') v.push(...checkSlackPost(byName.get('Slack: Post Message')));
      return v;
    },
  },
  {
    id: 'node_type_versions',
    text: `every node type and typeVersion is one pinned for n8n ${NODE_VERSIONS_N8N}`,
    run: ({ wf }) => nodesOf(wf).flatMap((n) => {
      if (!Object.prototype.hasOwnProperty.call(NODE_TYPE_VERSIONS, n.type)) {
        return [`node "${n.name}": type ${n.type} has no pinned typeVersion`];
      }
      const want = NODE_TYPE_VERSIONS[n.type];
      return n.typeVersion === want ? [] : [`node "${n.name}": ${n.type} typeVersion ${n.typeVersion}, pinned ${want}`];
    }),
  },
  {
    id: 'publish_order',
    text: 'each production workflow is published after everything it calls or names as its error workflow, and its note says its step',
    run: ({ file, wf, exportedById }) => {
      const pos = PUBLISH_ORDER.indexOf(file);
      if (pos < 0) {
        return HARNESS_FILES.has(file) || !WORKFLOWS[file] ? [] : [`production workflow ${file} is not in PUBLISH_ORDER`];
      }
      const v = [];
      const fileOfId = new Map(Object.entries(WORKFLOWS).map(([f, m]) => [m.id, f]));
      const deps = nodesOf(wf).filter((n) => n.type === T.exec).map((n) => ({ what: `node "${n.name}"`, id: targetId(n) }));
      const ew = (wf.settings || {}).errorWorkflow;
      if (ew) deps.push({ what: 'settings.errorWorkflow', id: String(ew) });
      for (const d of deps) {
        const depFile = fileOfId.get(d.id);
        const depPos = PUBLISH_ORDER.indexOf(depFile);
        if (depPos < 0 || depPos >= pos) {
          v.push(`${d.what}: ${d.id} (${depFile || 'not exported'}) is not published before ${file}`);
        }
      }
      const step = `**Publish (n8n 2.x):** step ${pos + 1} of ${PUBLISH_ORDER.length}`;
      const notes = nodesOf(wf).filter((n) => n.type === T.sticky).map((n) => String(params(n).content || ''));
      if (!notes.some((c) => c.includes(step))) v.push(`no sticky note says "${step}"`);
      return v;
    },
  },
];

// Global checks over files other than the exports themselves.
// node_versions_n8n: the pins above were checked against the n8n version the
// tests record. publish_docs: the README import steps publish exactly the
// PUBLISH_ORDER workflows, in that order, and never a harness.
function checkVersionsFile(versionsFile) {
  if (!existsSync(versionsFile)) return [`${versionsFile} not found`];
  let n8n;
  try { n8n = JSON.parse(readFileSync(versionsFile, 'utf8')).n8n; } catch (e) { return [`versions file does not parse: ${e.message}`]; }
  return n8n === NODE_VERSIONS_N8N ? [] : [`test/env/versions.json n8n is ${JSON.stringify(n8n)}, but the typeVersion pins were checked against ${NODE_VERSIONS_N8N}`];
}

export function checkPublishDocs(text) {
  const v = [];
  const ids = [...String(text).matchAll(/publish:workflow\s+--id=([A-Za-z0-9]+)/g)].map((m) => m[1]);
  const want = PUBLISH_ORDER.map((f) => WORKFLOWS[f].id);
  if (JSON.stringify(ids) !== JSON.stringify(want)) {
    v.push(`README publish:workflow ids are [${ids.join(', ')}], expected [${want.join(', ')}] in that order`);
  }
  if (/run only when called/i.test(String(text))) v.push('README still says sub-workflows "run only when called"');
  return v;
}

function checkReadme(readmeFile) {
  if (!existsSync(readmeFile)) return [`${readmeFile} not found`];
  return checkPublishDocs(readFileSync(readmeFile, 'utf8'));
}

// The fields a sub-workflow's Execute Workflow Trigger declares, in order,
// with the type n8n infers for each (null means "any": no schema type).
// Returns null when the trigger accepts all data (nothing to map).
export function triggerFields(targetWf) {
  const trig = nodesOf(targetWf).find((x) => x.type === T.execTrigger);
  if (!trig) return { error: 'target has no Execute Workflow Trigger' };
  const p = params(trig);
  if (p.inputSource === 'passthrough') return null;
  if (p.inputSource !== 'jsonExample') return { error: `target trigger inputSource ${p.inputSource || '(unset)'} is not jsonExample` };
  let ex;
  try { ex = JSON.parse(p.jsonExample); } catch (e) { return { error: `target trigger jsonExample does not parse: ${e.message}` }; }
  if (!ex || typeof ex !== 'object' || Array.isArray(ex)) return { error: 'target trigger jsonExample is not an object' };
  const typeOf = (v) => (v === null ? null : Array.isArray(v) ? 'array' : typeof v);
  return { fields: Object.entries(ex).map(([name, v]) => ({ name, type: typeOf(v) })) };
}

function checkWorkflowInputs(n, targetWf) {
  const label = `node "${n.name}"`;
  if (!targetWf) return [`${label}: target is not an exported workflow, inputs not checked`];
  const tf = triggerFields(targetWf);
  if (tf === null) return [];
  if (tf.error) return [`${label}: ${tf.error}`];
  const wi = params(n).workflowInputs;
  if (!wi || typeof wi !== 'object') return [`${label}: workflowInputs is missing`];
  const v = [];
  if (wi.mappingMode !== 'defineBelow') v.push(`${label}: workflowInputs.mappingMode is ${wi.mappingMode || '(unset)'}, expected defineBelow`);
  if (wi.attemptToConvertTypes !== false) v.push(`${label}: workflowInputs.attemptToConvertTypes is not false`);
  const value = wi.value && typeof wi.value === 'object' && !Array.isArray(wi.value) ? wi.value : null;
  if (!value) v.push(`${label}: workflowInputs.value is not an object`);
  const schema = Array.isArray(wi.schema) ? wi.schema : null;
  if (!schema) v.push(`${label}: workflowInputs.schema is not an array`);
  const want = new Map(tf.fields.map((f) => [f.name, f]));
  if (value) {
    for (const f of tf.fields) {
      if (!Object.prototype.hasOwnProperty.call(value, f.name)) { v.push(`${label}: field ${f.name} is not mapped`); continue; }
      const expr = value[f.name];
      if (typeof expr !== 'string' || squash(expr) !== `={{$json.${f.name}}}`) {
        v.push(`${label}: field ${f.name} is mapped to ${JSON.stringify(expr)}, expected "={{ $json.${f.name} }}"`);
      }
    }
    for (const k of Object.keys(value)) if (!want.has(k)) v.push(`${label}: mapped field ${k} is not in the target trigger`);
  }
  if (schema) {
    const seen = new Set();
    for (const e of schema) {
      const id = e && e.id;
      if (!want.has(id)) { v.push(`${label}: schema entry ${JSON.stringify(id)} is not in the target trigger`); continue; }
      if (seen.has(id)) v.push(`${label}: schema entry ${id} appears twice`);
      seen.add(id);
      const f = want.get(id);
      if (e.displayName !== id) v.push(`${label}: schema entry ${id} displayName is ${JSON.stringify(e.displayName)}`);
      if (e.removed === true) v.push(`${label}: schema entry ${id} is removed`);
      if (e.display !== true) v.push(`${label}: schema entry ${id} is not displayed`);
      if (f.type === null ? e.type !== undefined : e.type !== f.type) {
        v.push(`${label}: schema entry ${id} type is ${e.type === undefined ? '(none)' : e.type}, expected ${f.type === null ? '(none, any type)' : f.type}`);
      }
    }
    for (const f of tf.fields) if (!seen.has(f.name)) v.push(`${label}: schema has no entry for ${f.name}`);
  }
  return v;
}

function checkInvokeWebhook(n) {
  if (!n) return [];
  const p = params(n);
  const v = [];
  if (p.httpMethod !== 'POST') v.push('Webhook: Invoke is not POST');
  if (p.path !== 'fao-recon-invoke') v.push('Webhook: Invoke path is not fao-recon-invoke');
  if (p.authentication !== 'headerAuth') v.push('Webhook: Invoke authentication is not headerAuth');
  if (p.responseMode !== 'responseNode') v.push('Webhook: Invoke responseMode is not responseNode');
  if (!n.webhookId) v.push('Webhook: Invoke has no fixed webhookId');
  const ref = (n.credentials || {}).httpHeaderAuth || {};
  if (ref.name !== CREDENTIALS.httpHeaderAuth.name) v.push('Webhook: Invoke does not use FAO Invoke Header Auth');
  return v;
}

function checkSlackPost(n) {
  if (!n) return [];
  const p = params(n);
  const v = [];
  if (String(p.method || '').toUpperCase() !== 'POST') v.push('Slack: Post Message is not POST');
  if (p.authentication !== 'predefinedCredentialType') v.push('Slack: Post Message authentication is not predefinedCredentialType');
  if (p.nodeCredentialType !== 'slackApi') v.push('Slack: Post Message nodeCredentialType is not slackApi');
  const ref = (n.credentials || {}).slackApi || {};
  if (ref.name !== CREDENTIALS.slackApi.name) v.push('Slack: Post Message does not use FAO Slack Bot');
  return v;
}

// --- Runner -----------------------------------------------------------------

export function checkExports({ workflowsDir = WORKFLOWS_DIR, versionsFile = VERSIONS_FILE, readmeFile = README_FILE } = {}) {
  const files = existsSync(workflowsDir)
    ? readdirSync(workflowsDir).filter((f) => f.endsWith('.json')).sort()
    : [];
  const loaded = files.map((file) => {
    const raw = readFileSync(join(workflowsDir, file), 'utf8');
    let wf = null;
    let parseError = null;
    try { wf = JSON.parse(raw); } catch (e) { parseError = e.message; }
    return { file, raw, wf, parseError };
  });
  const exportedIds = new Set(loaded.filter((l) => l.wf && l.wf.id).map((l) => String(l.wf.id)));
  const exportedById = new Map(loaded.filter((l) => l.wf && l.wf.id).map((l) => [String(l.wf.id), l.wf]));

  const checks = [];
  // Global check: the exported set is exactly the section 4 set.
  const setViolations = [];
  for (const f of Object.keys(WORKFLOWS)) if (!files.includes(f)) setViolations.push(`missing workflow file ${f}`);
  for (const f of RETIRED_FILES) if (files.includes(f)) setViolations.push(`retired workflow file ${f} still present`);
  for (const f of files) if (!WORKFLOWS[f] && !RETIRED_FILES.includes(f)) setViolations.push(`unexpected workflow file ${f}`);
  checks.push({ rule: 'workflow_set', workflow: '(all)', ok: setViolations.length === 0, violations: setViolations });
  const versionViolations = checkVersionsFile(versionsFile);
  checks.push({ rule: 'node_versions_n8n', workflow: '(all)', ok: versionViolations.length === 0, violations: versionViolations });
  const docViolations = checkReadme(readmeFile);
  checks.push({ rule: 'publish_docs', workflow: '(all)', ok: docViolations.length === 0, violations: docViolations });

  for (const l of loaded) {
    for (const rule of RULES) {
      let violations;
      if (rule.id !== 'parses' && l.parseError) {
        violations = ['not checked: workflow does not parse'];
      } else {
        try {
          violations = rule.run({ ...l, exportedIds, exportedById });
        } catch (e) {
          violations = [`rule error: ${e.message}`];
        }
      }
      checks.push({ rule: rule.id, workflow: l.file, ok: violations.length === 0, violations });
    }
  }
  const failed = checks.filter((c) => !c.ok);
  return {
    checks,
    total: checks.length,
    passed: checks.length - failed.length,
    failed: failed.length,
    violations: failed.flatMap((c) => c.violations.map((v) => `${c.workflow} [${c.rule}] ${v}`)),
  };
}

export function toTap(report) {
  const lines = ['TAP version 13', `1..${report.total}`];
  report.checks.forEach((c, i) => {
    lines.push(`${c.ok ? 'ok' : 'not ok'} ${i + 1} - ${c.rule} ${c.workflow}`);
    for (const v of c.violations) lines.push(`  # ${v}`);
  });
  lines.push(`# tests ${report.total}`, `# pass ${report.passed}`, `# fail ${report.failed}`, '# skipped 0', '# todo 0');
  return lines.join('\n');
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const report = checkExports();
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(toTap(report));
    console.log(`check-exports: ${report.total} checks, ${report.passed} passed, ${report.failed} failed`);
  }
  process.exit(report.failed === 0 ? 0 : 1);
}
