// ============================================================================
// FinAgent OS e2e: workflow set imported into the e2e n8n instance
// ----------------------------------------------------------------------------
// The five production exports in workflows/ are imported byte for byte
// (Writer, notifier, error handler, sweeper, flagship). Two kinds of e2e-only
// copies are added next to them, built here at import time and never written
// back to workflows/:
//
// 1. Flagship fixture variants. The flagship holds its wallet, ledger and
//    provenance fixtures as literals inside the Init Execution Code node, so
//    a run with other balances needs another copy. Each variant replaces only
//    those three literal blocks (each must match exactly once), and gets its
//    own workflow id, name, webhook path and webhookId. Every other node,
//    connection and setting (errorWorkflow included) is the export's.
// 2. A sweeper copy whose Schedule Trigger is replaced by a header-auth
//    Webhook trigger (responseMode lastNode), so a test can run one sweep on
//    demand and wait for it. The production sweeper is imported but not
//    published: a five-minute schedule would sweep the shared local stack
//    under other test runs. All other sweeper nodes are the export's.
// 3. Fix round 3 (S13, FAO-GOV-007 / FAO-GOV-008): a notifier stand-in that
//    always throws, and a second on-demand sweeper copy whose HITL Gateway
//    calls it, so one sweep has a failed notifier call and sweep item_errors
//    together. That copy differs from the export only in its trigger (as in
//    2) and its HITL Gateway target; the stand-in keeps the notifier's
//    Execute Workflow Trigger node and adds one throwing Code node.
// 4. Patch P1 (S14, FAO-GOV-008 / FAO-GOV-002): the "deprecate" flagship
//    variant runs under the local-only agent fao_e2e_deprecate_v1 and has one
//    extra Code node, E2E Pause Before Finalize, between Check Writer Count
//    and Finalize Run. It only waits (setTimeout in the task runner) so the
//    test can deprecate the agent after the claim and the asset writes and
//    before fao_run_finalize. Every other node, Check Finalize Result
//    included, is the export's.
// 5. Round 5 (K1, F-20, F-32; FAO-GOV-008, FAO-GOV-001):
//    a. The error handler export gets one change: its Extract Failure map
//       (workflow id to p_source, one 'id': 'source' entry per line, round 5
//       D4) gains the e2e copies, flagship variants as 'flagship' and the
//       two on-demand sweeper copies as 'sweeper'. Each of the three export
//       entries must appear exactly once or the build fails, so a changed
//       map is never patched silently. Every other byte is the export's.
//    b. The "preclaim" flagship variant throws in Validate Invoke Body
//       (upstream of Claim Run), so S16 drives a pre-claim failure.
//    c. A gateway caller (header-auth webhook) whose Execute Workflow node is
//       the flagship's own HITL Gateway node, fed hitl_id 0, so the notifier
//       export itself fails at Validate Payload (S15). The caller has no
//       error workflow; the notifier's own settings.errorWorkflow runs.
//    d. The two harness exports (workflows/test_*.json) are imported
//       unchanged and never published; S17 to S19 run them with
//       `n8n execute` (lib.mjs runHarness).
// 6. Patch round 6 (P1, FAO-GOV-008): the "respondfail" flagship variant
//    has the in-band balances and one change more: the responseBody of
//    Respond 400 and of Respond Claim Refused is invalid JSON, so the
//    Respond to Webhook node itself fails ("Invalid JSON in 'Response Body'
//    field") on the bad-input and refused branches. Node names, types,
//    connections and settings stay the export's, so S21 and S22 drive a
//    flagship failure at those two pre-claim nodes.
// ============================================================================

import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export const EXPORTS = {
  writer: { file: 'writer.json', id: 'dQslIEVwF3WqMliT' },
  gateway: { file: 'fao_hitl_gateway_v1.json', id: 'mUAC9qIMkVzlV5qw' },
  errorHandler: { file: 'fao_error_handler_v1.json', id: 'FaoErrHandlerV01' },
  sweeper: { file: 'fao_hitl_sweeper_v1.json', id: 'FaoSweeperV1x001' },
  flagship: { file: 'fao_reserve_recon_v1.json', id: 'uhB2KjEaJDuviM4D' },
};

// Published in this order (sub-workflows and the error handler first; the
// gateway names the handler as its error workflow). The production sweeper is
// deliberately absent (see above).
export const PUBLISH_ORDER = ['writer', 'errorHandler', 'gateway', 'flagship'];

export const FLAGSHIP_PATH = 'fao-recon-invoke';
export const SWEEP_PATH = 'fao-e2e-sweep';
export const SWEEP_ID = 'FaoE2eSweepHook1';
// Fix round 3 (S13): the failing notifier stand-in and the sweeper copy that
// calls it.
export const FAILING_NOTIFIER_ID = 'FaoE2eNotifFail1';
export const FAILING_NOTIFIER_MESSAGE = 'FAO e2e: forced notifier failure';
export const SWEEP_NFAIL_PATH = 'fao-e2e-sweep-notifier-fails';
export const SWEEP_NFAIL_ID = 'FaoE2eSweepNfal1';
// The flagship agent and the local-only agent S10 runs under (lib.mjs
// re-exports both).
export const FLAGSHIP_AGENT = 'fao_reserve_recon_v1';
export const MARKUP_AGENT = 'fao_e2e_markup_v1';
// Patch P1 (S14): the local-only agent the deprecate variant claims for, and
// how long that variant waits before Finalize Run.
export const DEPRECATE_AGENT = 'fao_e2e_deprecate_v1';
export const PAUSE_NODE = 'E2E Pause Before Finalize';
export const PAUSE_BEFORE_FINALIZE_MS = 15000;
// Round 5: the harness exports, the gateway caller and the pre-claim message.
export const HARNESSES = {
  writer: { file: 'test_writer_harness_multi_item.json', id: 'OV7ukqcVKYfNXKHa' },
  gateway: { file: 'test_hitl_gateway_harness.json', id: 'V87nEh6HALqINIDz' },
};
export const GATEWAY_CALLER_ID = 'FaoE2eGwCaller01';
export const GATEWAY_CALLER_PATH = 'fao-e2e-gateway-bad-input';
export const PRECLAIM_MESSAGE = 'FAO e2e: forced failure before Claim Run';
// Patch round 6 (P1): the two Respond nodes the respondfail variant breaks,
// and the body it gives them (unterminated JSON, so the node throws).
export const RESPOND_FAIL_NODES = ['Respond 400', 'Respond Claim Refused'];
export const RESPOND_FAIL_BODY = '{"e2e": "patch round 6 P1: invalid JSON on purpose"';
// The error handler's map entries for the three exports (D4), exactly as the
// export writes them.
export const ERROR_MAP_ENTRIES = {
  flagship: "'uhB2KjEaJDuviM4D': 'flagship'",
  gateway: "'mUAC9qIMkVzlV5qw': 'gateway'",
  sweeper: "'FaoSweeperV1x001': 'sweeper'",
};

// JS source for each variant's three literal blocks. JS, not JSON, so NaN and
// markup survive exactly as a fixture author would write them.
export const MARKUP_NOTE = `<img src=x onerror="alert('e2e')"> & <!channel> <@U0E2E> '; DROP TABLE public.shadow_ledger; -- {{ $env.HOME }} \${process.env.HOME}`;
export const MARKUP_NOTE_2 = '<script>alert(1)</script> </b> &amp; |pipe| *bold* _it_ `code`';

// Patch round 6 (P9, IC-38): the in-band USDC ratio is 1.006, inside the
// stablecoin band [1.0000, 1.0500] the owner set (reserves held near 105%)
// and above the old 1.0050 upper, so S01 fails if the old band is still
// stored. Its $6,000 discrepancy stays under the $10,000 USDC materiality.
export const VARIANTS = {
  inband: {
    id: 'FaoE2eReconInbd1',
    path: 'fao-e2e-recon-inband',
    wallet: `{
  ADA:  1010,
  BTC:  1100,
  ETH:  1050,
  SOL:  1050,
  USDC: 1006000,
  USDT: 500000,
  XRP:  1020
}`,
    ledger: `{
  ADA:  1000,
  BTC:  1000,
  ETH:  1000,
  SOL:  1000,
  USDC: 1000000,
  USDT: 500000,
  XRP:  1000
}`,
    meta: `{
  ADA:  { source: 'e2e_inband', notes: 'ratio 1.01 in band [1.00, 1.10]' },
  BTC:  { source: 'e2e_inband', notes: 'ratio 1.10 in band [1.05, 1.25]' },
  ETH:  { source: 'e2e_inband', notes: 'ratio 1.05 in band [1.00, 1.10]' },
  SOL:  { source: 'e2e_inband', notes: 'ratio 1.05 in band [1.00, 1.15]' },
  USDC: { source: 'e2e_inband', notes: 'ratio 1.006 in band [1.00, 1.05], above the old 1.005 upper (IC-38); $6,000 under the $10,000 materiality' },
  USDT: { source: 'e2e_inband', notes: 'exact match' },
  XRP:  { source: 'e2e_inband', notes: 'ratio 1.02 in band [1.00, 1.10]' }
}`,
  },
  blocked: {
    id: 'FaoE2eReconBlck1',
    path: 'fao-e2e-recon-blocked',
    wallet: `{
  ADA:  1000,
  BTC:  1100,
  DOGE: 5000,
  SOL:  900
}`,
    ledger: `{
  ADA:  -50,
  BTC:  1000,
  SOL:  1000
}`,
    meta: `{
  ADA:  { source: 'e2e_blocked', notes: 'negative ledger, REQUIRE_HUMAN CRITICAL' },
  BTC:  { source: 'e2e_blocked', notes: 'in band, ALLOW' },
  DOGE: { source: 'e2e_blocked', notes: 'wallet only, BLOCKED ONE_SIDED' },
  SOL:  { source: 'e2e_blocked', notes: 'ratio 0.90 below floor, REQUIRE_HUMAN CRITICAL' }
}`,
  },
  badinput: {
    id: 'FaoE2eReconBadI1',
    path: 'fao-e2e-recon-badinput',
    wallet: `{
  BTC:  NaN,
  ETH:  1050,
  XRP:  1020
}`,
    ledger: `{
  BTC:  1000,
  XRP:  1000
}`,
    meta: `{
  BTC:  { source: 'e2e_badinput', notes: 'wallet NaN' },
  ETH:  { source: 'e2e_badinput', notes: 'ledger balance missing' },
  XRP:  { source: 'e2e_badinput', notes: 'in band, ALLOW' }
}`,
  },
  markup: {
    id: 'FaoE2eReconMrkp1',
    path: 'fao-e2e-recon-markup',
    // Fix round 2 R08: a claim names the agent its workflow serves, so this
    // copy's Claim Run names the markup agent its runs are started for.
    agent: MARKUP_AGENT,
    wallet: `{
  BTC:  1100,
  USDT: 1234567890.50
}`,
    ledger: `{
  BTC:  1000,
  USDT: 1234500000
}`,
    meta: `{
  BTC:  { source: 'e2e_markup', notes: ${JSON.stringify(MARKUP_NOTE)} },
  USDT: { source: 'e2e_markup', notes: ${JSON.stringify(MARKUP_NOTE_2)}, control: '<b>FAO-REC-002</b>' }
}`,
  },
  failnode: {
    id: 'FaoE2eReconFail1',
    path: 'fao-e2e-recon-failnode',
    // A lower-case symbol: Init Execution throws after the claim, so the run
    // fails inside the flagship and the error workflow records it.
    wallet: `{
  btc:  1
}`,
    ledger: `{
  btc:  1
}`,
    meta: `{
  btc:  { source: 'e2e_failnode', notes: 'invalid symbol, Init Execution throws' }
}`,
  },
};

// Patch P1 (S14): the in-band balances under the deprecate agent, with a
// pause before Finalize Run so S14 can deprecate the agent in between.
VARIANTS.deprecate = {
  id: 'FaoE2eReconDepr1',
  path: 'fao-e2e-recon-deprecate',
  agent: DEPRECATE_AGENT,
  wallet: VARIANTS.inband.wallet,
  ledger: VARIANTS.inband.ledger,
  meta: VARIANTS.inband.meta.replace(/e2e_inband/g, 'e2e_deprecate'),
  pauseBeforeFinalizeMs: PAUSE_BEFORE_FINALIZE_MS,
};

// Round 5 (S16): the in-band balances, and Validate Invoke Body throws before
// it reads the body, so the execution fails upstream of Claim Run.
VARIANTS.preclaim = {
  id: 'FaoE2eReconPreC1',
  path: 'fao-e2e-recon-preclaim',
  wallet: VARIANTS.inband.wallet,
  ledger: VARIANTS.inband.ledger,
  meta: VARIANTS.inband.meta.replace(/e2e_inband/g, 'e2e_preclaim'),
  throwBeforeClaim: true,
};

// Patch round 6 (P1, S21 and S22): the in-band balances; Respond 400 and
// Respond Claim Refused fail, so a bad body or a refused claim fails the
// execution at a pre-claim Respond node.
VARIANTS.respondfail = {
  id: 'FaoE2eReconRspF1',
  path: 'fao-e2e-recon-respondfail',
  wallet: VARIANTS.inband.wallet,
  ledger: VARIANTS.inband.ledger,
  meta: VARIANTS.inband.meta.replace(/e2e_inband/g, 'e2e_respondfail'),
  breakRespondNodes: RESPOND_FAIL_NODES,
};

function readExport(root, key) {
  return JSON.parse(readFileSync(join(root, 'workflows', EXPORTS[key].file), 'utf8'));
}

function readHarness(root, key) {
  return JSON.parse(readFileSync(join(root, 'workflows', HARNESSES[key].file), 'utf8'));
}

const reLiteral = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function replaceOnce(code, startText, replacement, label) {
  const re = new RegExp(`${startText.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} \\{[\\s\\S]*?\\n\\};`, 'g');
  const matches = code.match(re) || [];
  if (matches.length !== 1) throw new Error(`variants: ${label}: expected one "${startText}" block, found ${matches.length}`);
  return code.replace(re, `${startText} ${replacement};`);
}

export function flagshipVariant(root, name) {
  const v = VARIANTS[name];
  if (!v) throw new Error(`variants: unknown variant ${name}`);
  const wf = readExport(root, 'flagship');
  const init = wf.nodes.find((n) => n.name === 'Init Execution');
  const hook = wf.nodes.find((n) => n.type === 'n8n-nodes-base.webhook');
  if (!init || !hook) throw new Error('variants: flagship has no Init Execution or webhook node');
  let code = init.parameters.jsCode;
  code = replaceOnce(code, 'const wallet_data =', v.wallet, `${name} wallet`);
  code = replaceOnce(code, 'const ledger_data =', v.ledger, `${name} ledger`);
  code = replaceOnce(code, 'const fixture_metadata =', v.meta, `${name} metadata`);
  init.parameters.jsCode = `// E2E FIXTURE VARIANT "${name}": wallet_data, ledger_data and fixture_metadata\n// replaced by test/e2e/variants.mjs; everything else is the export.\n${code}`;
  hook.parameters.path = v.path;
  if (v.agent) {
    // FAO-GOV-008 (R08): exactly one flagship agent id in Claim Run, swapped
    // for the variant's agent; anything else fails the build loudly.
    const claim = wf.nodes.find((n) => n.name === 'Claim Run');
    const text = claim ? JSON.stringify(claim.parameters) : '';
    const hits = text.split(FLAGSHIP_AGENT).length - 1;
    if (hits !== 1) throw new Error(`variants: ${name}: expected Claim Run to name ${FLAGSHIP_AGENT} once (fao_run_claim agent argument), found ${hits}`);
    claim.parameters = JSON.parse(text.replace(FLAGSHIP_AGENT, v.agent));
  }
  if (v.pauseBeforeFinalizeMs) insertPauseBeforeFinalize(wf, v.pauseBeforeFinalizeMs, name);
  if (v.throwBeforeClaim) {
    const validate = wf.nodes.find((n) => n.name === 'Validate Invoke Body');
    const outs = ((((wf.connections || {})['Validate Invoke Body'] || {}).main || [])[0] || []).map((c) => c.node);
    if (!validate || validate.type !== 'n8n-nodes-base.code' || outs.join() !== 'Body Valid?') {
      throw new Error(`variants: ${name}: expected a Validate Invoke Body Code node leading only to Body Valid?`);
    }
    validate.parameters.jsCode = `// E2E ONLY (test/e2e/variants.mjs): fail before Claim Run.\nthrow new Error(${JSON.stringify(PRECLAIM_MESSAGE)});\n${validate.parameters.jsCode}`;
  }
  if (v.breakRespondNodes) breakRespondNodes(wf, v.breakRespondNodes, name);
  hook.webhookId = randomUUID();
  wf.id = v.id;
  wf.name = `fao_reserve_recon_v1 [e2e ${name}]`;
  wf.versionId = randomUUID();
  wf.tags = [];
  return wf;
}

// S21 and S22: each named node must be a Respond to Webhook node answering
// JSON with no node after it; its responseBody becomes RESPOND_FAIL_BODY.
// Anything else fails the build.
function breakRespondNodes(wf, names, name) {
  for (const n of names) {
    const node = wf.nodes.find((x) => x.name === n);
    const outs = (((wf.connections || {})[n] || {}).main || []).flat();
    if (!node || node.type !== 'n8n-nodes-base.respondToWebhook' || node.parameters.respondWith !== 'json'
        || typeof node.parameters.responseBody !== 'string' || outs.length !== 0) {
      throw new Error(`variants: ${name}: expected ${n} to be a JSON Respond to Webhook node with no node after it`);
    }
    node.parameters.responseBody = RESPOND_FAIL_BODY;
  }
}

// S14: Check Writer Count -> E2E Pause Before Finalize -> Finalize Run. The
// export must have exactly that one edge; anything else fails the build.
function insertPauseBeforeFinalize(wf, ms, name) {
  const from = 'Check Writer Count';
  const to = 'Finalize Run';
  const outs = (((wf.connections || {})[from] || {}).main || []);
  const fin = wf.nodes.find((n) => n.name === to);
  if (!fin || outs.length !== 1 || (outs[0] || []).length !== 1 || outs[0][0].node !== to) {
    throw new Error(`variants: ${name}: expected exactly one edge ${from} -> ${to}`);
  }
  if (!Number.isSafeInteger(ms) || ms < 1000 || ms > 60000) throw new Error(`variants: ${name}: pause ${ms} ms out of range`);
  wf.nodes.push({
    parameters: {
      mode: 'runOnceForAllItems',
      jsCode: `// E2E ONLY (test/e2e/variants.mjs): wait ${ms} ms, then pass the items on.
await new Promise((resolve) => setTimeout(resolve, ${ms}));
return $input.all();`,
    },
    type: 'n8n-nodes-base.code',
    typeVersion: 2,
    position: [fin.position[0], fin.position[1] + 200],
    id: randomUUID(),
    name: PAUSE_NODE,
  });
  wf.connections[from] = { main: [[{ node: PAUSE_NODE, type: 'main', index: 0 }]] };
  wf.connections[PAUSE_NODE] = { main: [[{ node: to, type: 'main', index: 0 }]] };
}

export function sweeperOnDemand(root, { id = SWEEP_ID, path = SWEEP_PATH, label = 'e2e on-demand trigger' } = {}) {
  const wf = readExport(root, 'sweeper');
  const idx = wf.nodes.findIndex((n) => n.type === 'n8n-nodes-base.scheduleTrigger');
  if (idx < 0) throw new Error('variants: sweeper has no Schedule Trigger');
  const old = wf.nodes[idx];
  const name = 'E2E Sweep Webhook';
  wf.nodes[idx] = {
    parameters: { httpMethod: 'POST', path, authentication: 'headerAuth', responseMode: 'lastNode', options: {} },
    id: randomUUID(),
    name,
    type: 'n8n-nodes-base.webhook',
    typeVersion: 2,
    position: old.position,
    webhookId: randomUUID(),
    credentials: { httpHeaderAuth: { id: 'FaoInvokeHdr0001', name: 'FAO Invoke Header Auth' } },
  };
  wf.connections[name] = wf.connections[old.name];
  delete wf.connections[old.name];
  wf.id = id;
  wf.name = `fao_hitl_sweeper_v1 [${label}]`;
  wf.versionId = randomUUID();
  wf.tags = [];
  return wf;
}

// S13: the notifier's own Execute Workflow Trigger (same inputs), then a Code
// node that always throws, so the sweeper's HITL Gateway call fails the way
// a broken or unpublished notifier does. No error workflow, no credentials.
export function failingNotifier(root) {
  const gw = readExport(root, 'gateway');
  const trigger = gw.nodes.find((n) => n.type === 'n8n-nodes-base.executeWorkflowTrigger');
  if (!trigger) throw new Error('variants: notifier has no Execute Workflow Trigger');
  const fail = 'E2E Forced Failure';
  return {
    name: 'fao_hitl_gateway_v1 [e2e always fails]',
    nodes: [
      { ...structuredClone(trigger), id: randomUUID() },
      {
        parameters: { mode: 'runOnceForAllItems', jsCode: `throw new Error(${JSON.stringify(FAILING_NOTIFIER_MESSAGE)});` },
        type: 'n8n-nodes-base.code',
        typeVersion: 2,
        position: [trigger.position[0] + 220, trigger.position[1]],
        id: randomUUID(),
        name: fail,
      },
    ],
    pinData: {},
    connections: { [trigger.name]: { main: [[{ node: fail, type: 'main', index: 0 }]] } },
    active: false,
    settings: { executionOrder: 'v1' },
    versionId: randomUUID(),
    id: FAILING_NOTIFIER_ID,
    tags: [],
  };
}

// S13: the on-demand sweeper with exactly one change more, HITL Gateway
// calling the failing stand-in instead of the notifier.
export function sweeperNotifierFails(root) {
  const wf = sweeperOnDemand(root, { id: SWEEP_NFAIL_ID, path: SWEEP_NFAIL_PATH, label: 'e2e notifier fails' });
  const calls = wf.nodes.filter((n) => n.type === 'n8n-nodes-base.executeWorkflow');
  const gw = calls.find((n) => n.name === 'HITL Gateway');
  if (calls.length !== 1 || !gw || !gw.parameters.workflowId || gw.parameters.workflowId.value !== EXPORTS.gateway.id) {
    throw new Error(`variants: expected one Execute Workflow node, HITL Gateway calling ${EXPORTS.gateway.id}`);
  }
  gw.parameters.workflowId = {
    ...gw.parameters.workflowId,
    value: FAILING_NOTIFIER_ID,
    cachedResultUrl: `/workflow/${FAILING_NOTIFIER_ID}`,
    cachedResultName: 'fao_hitl_gateway_v1 [e2e always fails]',
  };
  return wf;
}

// Round 5 (D4): the e2e ids the error handler must map. Flagship variants run
// with the flagship's settings.errorWorkflow and the on-demand sweeper copies
// with the sweeper's; the failing stand-in and the gateway caller have none.
export function e2eSourceIds() {
  return {
    flagship: Object.values(VARIANTS).map((v) => v.id),
    sweeper: [SWEEP_ID, SWEEP_NFAIL_ID],
  };
}

// Inserts one `'<id>': '<source>',` line per e2e copy before the export's own
// entry, with its indentation. Each export entry must occur exactly once, at
// the start of a line.
export function patchErrorHandlerMap(code) {
  const lineRe = (entry) => new RegExp(`^([ \\t]*)(${reLiteral(entry)})`, 'gm');
  for (const [source, entry] of Object.entries(ERROR_MAP_ENTRIES)) {
    const hits = code.split(entry).length - 1;
    const lines = (code.match(lineRe(entry)) || []).length;
    if (hits !== 1 || lines !== 1) {
      throw new Error(`variants: error handler map: expected ${entry} (${source}) exactly once at the start of a line, found ${hits} (${lines} at a line start)`);
    }
  }
  const ids = e2eSourceIds();
  let out = code;
  for (const source of Object.keys(ids)) {
    out = out.replace(lineRe(ERROR_MAP_ENTRIES[source]),
      (all, indent, e) => `${ids[source].map((id) => `${indent}'${id}': '${source}',\n`).join('')}${indent}${e}`);
  }
  for (const source of Object.keys(ids)) {
    for (const id of ids[source]) {
      if (out.split(`'${id}': '${source}'`).length - 1 !== 1) throw new Error(`variants: error handler map: ${id} not added exactly once`);
    }
  }
  return out;
}

export function errorHandlerForE2e(root) {
  const wf = readExport(root, 'errorHandler');
  const nodes = wf.nodes.filter((n) => n.name === 'Extract Failure');
  if (nodes.length !== 1 || nodes[0].type !== 'n8n-nodes-base.code') throw new Error('variants: error handler has no single Extract Failure Code node');
  nodes[0].parameters.jsCode = patchErrorHandlerMap(String(nodes[0].parameters.jsCode || ''));
  return wf;
}

// S15: header-auth webhook, a Code node with the bad notifier input, then a
// copy of the flagship's own HITL Gateway node (same target and mapping), so
// the notifier export fails at Validate Payload as a sub-workflow.
export function gatewayCaller(root) {
  const flag = readExport(root, 'flagship');
  const gw = flag.nodes.find((n) => n.name === 'HITL Gateway');
  if (!gw || gw.type !== 'n8n-nodes-base.executeWorkflow' || !gw.parameters.workflowId || gw.parameters.workflowId.value !== EXPORTS.gateway.id) {
    throw new Error(`variants: the flagship has no HITL Gateway node calling ${EXPORTS.gateway.id}`);
  }
  const hook = 'E2E Gateway Caller Webhook';
  const input = 'E2E Bad Notifier Input';
  return {
    name: 'fao_hitl_gateway_v1 [e2e caller, bad input]',
    nodes: [
      {
        parameters: { httpMethod: 'POST', path: GATEWAY_CALLER_PATH, authentication: 'headerAuth', responseMode: 'lastNode', options: {} },
        id: randomUUID(),
        name: hook,
        type: 'n8n-nodes-base.webhook',
        typeVersion: 2,
        position: [0, 0],
        webhookId: randomUUID(),
        credentials: { httpHeaderAuth: { id: 'FaoInvokeHdr0001', name: 'FAO Invoke Header Auth' } },
      },
      {
        parameters: { mode: 'runOnceForAllItems', jsCode: "// E2E ONLY: hitl_id 0 is outside the notifier's input contract.\nreturn [{ json: { hitl_id: 0, kind: 'REQUESTED', level: 0 } }];" },
        type: 'n8n-nodes-base.code',
        typeVersion: 2,
        position: [220, 0],
        id: randomUUID(),
        name: input,
      },
      { ...structuredClone(gw), id: randomUUID(), position: [440, 0] },
    ],
    pinData: {},
    connections: {
      [hook]: { main: [[{ node: input, type: 'main', index: 0 }]] },
      [input]: { main: [[{ node: gw.name, type: 'main', index: 0 }]] },
    },
    active: false,
    settings: { executionOrder: 'v1' },
    versionId: randomUUID(),
    id: GATEWAY_CALLER_ID,
    tags: [],
  };
}

// Every workflow file for import:workflow --separate, keyed by file name.
export function buildWorkflowSet(root) {
  const out = {};
  for (const key of Object.keys(EXPORTS)) out[EXPORTS[key].file] = readExport(root, key);
  out[EXPORTS.errorHandler.file] = errorHandlerForE2e(root);
  for (const key of Object.keys(HARNESSES)) out[HARNESSES[key].file] = readHarness(root, key);
  for (const name of Object.keys(VARIANTS)) out[`e2e_recon_${name}.json`] = flagshipVariant(root, name);
  out['e2e_sweeper_on_demand.json'] = sweeperOnDemand(root);
  out['e2e_notifier_always_fails.json'] = failingNotifier(root);
  out['e2e_sweeper_notifier_fails.json'] = sweeperNotifierFails(root);
  out['e2e_gateway_caller.json'] = gatewayCaller(root);
  return out;
}

// The failing stand-in is published before the sweeper copy that calls it.
// The harnesses are imported but never published (Manual Trigger); S17 to
// S19 run them with n8n execute.
export function publishIds() {
  return [
    ...PUBLISH_ORDER.map((k) => EXPORTS[k].id),
    ...Object.values(VARIANTS).map((v) => v.id),
    SWEEP_ID,
    FAILING_NOTIFIER_ID,
    SWEEP_NFAIL_ID,
    GATEWAY_CALLER_ID,
  ];
}
