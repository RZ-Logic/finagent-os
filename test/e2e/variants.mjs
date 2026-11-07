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

// Published in this order (sub-workflows first). The production sweeper is
// deliberately absent (see above).
export const PUBLISH_ORDER = ['writer', 'gateway', 'errorHandler', 'flagship'];

export const FLAGSHIP_PATH = 'fao-recon-invoke';
export const SWEEP_PATH = 'fao-e2e-sweep';
export const SWEEP_ID = 'FaoE2eSweepHook1';

// JS source for each variant's three literal blocks. JS, not JSON, so NaN and
// markup survive exactly as a fixture author would write them.
export const MARKUP_NOTE = `<img src=x onerror="alert('e2e')"> & <!channel> <@U0E2E> '; DROP TABLE public.shadow_ledger; -- {{ $env.HOME }} \${process.env.HOME}`;
export const MARKUP_NOTE_2 = '<script>alert(1)</script> </b> &amp; |pipe| *bold* _it_ `code`';

export const VARIANTS = {
  inband: {
    id: 'FaoE2eReconInbd1',
    path: 'fao-e2e-recon-inband',
    wallet: `{
  ADA:  1010,
  BTC:  1100,
  ETH:  1050,
  SOL:  1050,
  USDC: 1000000,
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
  USDC: { source: 'e2e_inband', notes: 'exact match' },
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

function readExport(root, key) {
  return JSON.parse(readFileSync(join(root, 'workflows', EXPORTS[key].file), 'utf8'));
}

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
  hook.webhookId = randomUUID();
  wf.id = v.id;
  wf.name = `fao_reserve_recon_v1 [e2e ${name}]`;
  wf.versionId = randomUUID();
  wf.tags = [];
  return wf;
}

export function sweeperOnDemand(root) {
  const wf = readExport(root, 'sweeper');
  const idx = wf.nodes.findIndex((n) => n.type === 'n8n-nodes-base.scheduleTrigger');
  if (idx < 0) throw new Error('variants: sweeper has no Schedule Trigger');
  const old = wf.nodes[idx];
  const name = 'E2E Sweep Webhook';
  wf.nodes[idx] = {
    parameters: { httpMethod: 'POST', path: SWEEP_PATH, authentication: 'headerAuth', responseMode: 'lastNode', options: {} },
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
  wf.id = SWEEP_ID;
  wf.name = 'fao_hitl_sweeper_v1 [e2e on-demand trigger]';
  wf.versionId = randomUUID();
  wf.tags = [];
  return wf;
}

// Every workflow file for import:workflow --separate, keyed by file name.
export function buildWorkflowSet(root) {
  const out = {};
  for (const key of Object.keys(EXPORTS)) out[EXPORTS[key].file] = readExport(root, key);
  for (const name of Object.keys(VARIANTS)) out[`e2e_recon_${name}.json`] = flagshipVariant(root, name);
  out['e2e_sweeper_on_demand.json'] = sweeperOnDemand(root);
  return out;
}

export function publishIds() {
  return [
    ...PUBLISH_ORDER.map((k) => EXPORTS[k].id),
    ...Object.values(VARIANTS).map((v) => v.id),
    SWEEP_ID,
  ];
}
