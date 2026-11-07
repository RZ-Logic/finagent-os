// ============================================================================
// FinAgent OS - offline harness for exported n8n Code nodes
// ----------------------------------------------------------------------------
// Controls supported: FAO-GOV-001, FAO-GOV-007, FAO-GOV-008, FAO-REC-001.
//
// runCodeNode(workflowFile, nodeName, { items, upstream, executionId, env })
//   items       input items for the node, as plain JSON objects
//   upstream    { '<node name>': [json, ...] } served by $('<node name>')
//   executionId value of $execution.id
//   env         object served as $env
// Extracts the node (scripts/extract-code-nodes.mjs), imports the generated
// module and runs it the way n8n does for the node's mode. Returns the output
// as an array of plain JSON objects (n8n's { json } wrapper removed).
// The node body runs exactly as exported.
// ============================================================================

import { readFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractNode, listCodeNodes, readWorkflow } from '../../scripts/extract-code-nodes.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, '..', '..');
export const WORKFLOWS = join(REPO_ROOT, 'workflows');

let importCounter = 0;

const wrap = (j) => ({ json: j === undefined ? {} : j, pairedItem: { item: 0 } });

function itemList(arr) {
  const items = (arr || []).map(wrap);
  return {
    all: () => items,
    first: () => items[0],
    last: () => items[items.length - 1],
    get item() { return items[0]; },
    items,
  };
}

function nowObject() {
  const d = new Date();
  return {
    toISO: () => d.toISOString(),
    toISOString: () => d.toISOString(),
    toMillis: () => d.getTime(),
    toJSDate: () => d,
    valueOf: () => d.getTime(),
    toString: () => d.toISOString(),
  };
}

function normalise(result) {
  if (result === undefined || result === null) return [];
  const arr = Array.isArray(result) ? result : [result];
  return arr.map((r) => (r && typeof r === 'object' && 'json' in r ? r.json : r));
}

export function workflowPath(workflowFile) {
  return workflowFile.includes('/') || workflowFile.includes('\\')
    ? workflowFile
    : join(WORKFLOWS, workflowFile.endsWith('.json') ? workflowFile : `${workflowFile}.json`);
}

export function codeOf(workflowFile, nodeName) {
  const node = listCodeNodes(workflowPath(workflowFile)).find((n) => n.name === nodeName);
  if (!node) throw new Error(`harness: no Code node named ${JSON.stringify(nodeName)} in ${workflowFile}`);
  return node.jsCode;
}

export function nodeOf(workflowFile, nodeName) {
  const { json } = readWorkflow(workflowPath(workflowFile));
  return (json.nodes || []).find((n) => n.name === nodeName) || null;
}

export async function runCodeNode(workflowFile, nodeName, { items = [], upstream = {}, executionId = 'test-exec-1', env = {} } = {}) {
  const extracted = extractNode(workflowPath(workflowFile), nodeName);
  importCounter += 1;
  const mod = await import(`${extracted.url}?v=${Date.now()}-${importCounter}`);
  const run = mod.default;

  const $ = (name) => {
    if (!Object.prototype.hasOwnProperty.call(upstream, name)) {
      throw new Error(`harness: node ${JSON.stringify(nodeName)} referenced $(${JSON.stringify(name)}) but the test supplied no upstream data for it`);
    }
    return itemList(upstream[name]);
  };
  const $execution = { id: executionId, mode: 'webhook', resumeUrl: '' };
  const $env = { ...env };

  if (extracted.mode === 'runOnceForEachItem') {
    const out = [];
    const list = itemList(items);
    for (let i = 0; i < list.items.length; i += 1) {
      const current = list.items[i];
      const $input = { ...list, item: current, all: list.all, first: list.first, last: list.last };
      const r = await run({ $input, $, $execution, $env, $json: current.json, $now: nowObject() });
      out.push(...normalise(r));
    }
    return out;
  }

  const $input = itemList(items);
  const r = await run({ $input, $, $execution, $env, $json: $input.first() ? $input.first().json : {}, $now: nowObject() });
  return normalise(r);
}

// Decodes the {"$special": ...} values used in fixtures/policy_branches.json.
export function decodeSpecial(value) {
  if (value && typeof value === 'object' && !Array.isArray(value) && '$special' in value) {
    switch (value.$special) {
      case 'undefined': return undefined;
      case 'NaN': return NaN;
      case 'Infinity': return Infinity;
      case '-Infinity': return -Infinity;
      default: throw new Error(`harness: unknown special value ${value.$special}`);
    }
  }
  return value;
}

export function decodeBalances(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj || {})) out[k] = decodeSpecial(v);
  return out;
}

export function readJson(relPath) {
  return JSON.parse(readFileSync(join(REPO_ROOT, relPath), 'utf8'));
}
