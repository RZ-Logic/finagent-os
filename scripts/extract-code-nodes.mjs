#!/usr/bin/env node
// ============================================================================
// FinAgent OS - extract n8n Code nodes into importable ES modules
// ----------------------------------------------------------------------------
// Controls supported:
//   FAO-GOV-001  the Writer's batch validation is tested as exported
//   FAO-REC-001  Per-Asset Reconcile branches are tested as exported
//   FAO-GOV-007  notifier composition is tested as exported
//
// The workflow JSON is the only copy of every Code node. This script writes
// each node's jsCode, unchanged, into
//   .local/code-nodes/<workflow-stem>/<node-slug>.mjs
// wrapped as `export default async function run({...})`, so the Node unit
// tests run exactly what n8n imports. Usable as a CLI (writes every node and
// prints a summary) or as a module (extractAll, extractNode, listCodeNodes).
// ============================================================================

import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from 'node:fs';
import { join, resolve, basename, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, '..');
export const WORKFLOWS_DIR = join(REPO_ROOT, 'workflows');
export const OUT_DIR = join(REPO_ROOT, '.local', 'code-nodes');
export const CODE_NODE_TYPE = 'n8n-nodes-base.code';

// Node name to file slug: lower case, every run of non-alphanumerics becomes
// one hyphen, no leading or trailing hyphen.
export function slugify(name) {
  return String(name)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'node';
}

export function workflowStem(workflowFile) {
  return basename(workflowFile).replace(/\.json$/i, '');
}

export function resolveWorkflowPath(workflowFile) {
  if (existsSync(workflowFile)) return resolve(workflowFile);
  const inDir = join(WORKFLOWS_DIR, basename(workflowFile));
  if (existsSync(inDir)) return inDir;
  const withExt = join(WORKFLOWS_DIR, `${basename(workflowFile)}.json`);
  if (existsSync(withExt)) return withExt;
  throw new Error(`extract-code-nodes: workflow not found: ${workflowFile}`);
}

export function readWorkflow(workflowFile) {
  const path = resolveWorkflowPath(workflowFile);
  return { path, json: JSON.parse(readFileSync(path, 'utf8')) };
}

// Every Code node of one workflow: { name, slug, mode, jsCode }.
export function listCodeNodes(workflowFile) {
  const { json } = readWorkflow(workflowFile);
  return (json.nodes || [])
    .filter((n) => n && n.type === CODE_NODE_TYPE)
    .map((n) => ({
      name: n.name,
      slug: slugify(n.name),
      mode: (n.parameters && n.parameters.mode) || null,
      jsCode: (n.parameters && typeof n.parameters.jsCode === 'string') ? n.parameters.jsCode : '',
    }));
}

export function renderModule(workflowFile, node) {
  const file = basename(resolveWorkflowPath(workflowFile));
  const header = `// generated from ${file} node ${JSON.stringify(node.name)} (mode: ${node.mode || 'unset'}); do not edit`;
  return `${header}\nexport default async function run({ $input, $, $execution, $env, $json, $now }) {\n${node.jsCode}\n}\n`;
}

// Writes one node's module and returns its absolute path.
export function extractNode(workflowFile, nodeName, outDir = OUT_DIR) {
  const node = listCodeNodes(workflowFile).find((n) => n.name === nodeName);
  if (!node) {
    throw new Error(`extract-code-nodes: no Code node named ${JSON.stringify(nodeName)} in ${basename(workflowFile)}`);
  }
  const dir = join(outDir, workflowStem(resolveWorkflowPath(workflowFile)));
  mkdirSync(dir, { recursive: true });
  const target = join(dir, `${node.slug}.mjs`);
  writeFileSync(target, renderModule(workflowFile, node), 'utf8');
  return { path: target, url: pathToFileURL(target).href, mode: node.mode, name: node.name };
}

// Writes every Code node of every workflow; returns the list of written files.
export function extractAll({ workflowsDir = WORKFLOWS_DIR, outDir = OUT_DIR } = {}) {
  const written = [];
  const files = readdirSync(workflowsDir).filter((f) => f.endsWith('.json')).sort();
  for (const f of files) {
    const full = join(workflowsDir, f);
    for (const node of listCodeNodes(full)) {
      written.push({ workflow: f, ...extractNode(full, node.name, outDir) });
    }
  }
  return written;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  try {
    const written = extractAll();
    for (const w of written) {
      console.log(`${w.workflow}  ${w.name}  (mode: ${w.mode || 'unset'})`);
    }
    console.log(`extract-code-nodes: wrote ${written.length} module(s) to .local/code-nodes/`);
  } catch (err) {
    console.error(String(err && err.message ? err.message : err));
    process.exit(1);
  }
}
