#!/usr/bin/env node
// FinAgent OS: vendor the pinned supabase-js UMD build for the approval page.
//
// FAO-GOV-004 approval page supply chain: the page loads supabase-js from its
// own origin (CSP script-src 'self'), never from a CDN. This script copies
// node_modules/@supabase/supabase-js/dist/umd/supabase.js from the exactly
// pinned devDependency to approval-app/vendor/supabase.js and records its
// SHA-256 in approval-app/vendor/SHA256SUMS (sha256sum format).
//
// Usage:
//   node scripts/vendor-supabase-js.mjs           copy and write SHA256SUMS
//   node scripts/vendor-supabase-js.mjs --check   verify the vendored copy only
//
// Exits non-zero when the pin is not exact, the installed version differs
// from the pin, the build is missing, or (with --check) the vendored file
// does not match its recorded hash or the installed build.

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PKG = '@supabase/supabase-js';
const SOURCE = join(ROOT, 'node_modules', '@supabase', 'supabase-js', 'dist', 'umd', 'supabase.js');
const VENDOR_DIR = join(ROOT, 'approval-app', 'vendor');
const TARGET = join(VENDOR_DIR, 'supabase.js');
const SUMS = join(VENDOR_DIR, 'SHA256SUMS');

function fail(message) {
  console.error(`vendor-supabase-js: ${message}`);
  process.exit(1);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return fail(`cannot read ${path.slice(ROOT.length + 1)}`);
  }
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function parseSums(text) {
  const entries = new Map();
  for (const line of text.split(/\r?\n/)) {
    const m = /^([0-9a-f]{64}) [ *](.+)$/.exec(line.trim());
    if (m) entries.set(m[2], m[1]);
  }
  return entries;
}

function pinnedVersion() {
  const pkg = readJson(join(ROOT, 'package.json'));
  const pin = pkg.devDependencies && pkg.devDependencies[PKG];
  if (typeof pin !== 'string' || !/^\d+\.\d+\.\d+$/.test(pin)) {
    fail(`${PKG} must be an exact devDependency version in package.json`);
  }
  const installedPath = join(ROOT, 'node_modules', '@supabase', 'supabase-js', 'package.json');
  if (!existsSync(installedPath)) fail(`${PKG} is not installed; run npm ci`);
  const installed = readJson(installedPath).version;
  if (installed !== pin) fail(`installed ${PKG} ${installed} differs from the pin ${pin}; run npm ci`);
  if (!existsSync(SOURCE)) fail(`${PKG} ${pin} has no dist/umd/supabase.js`);
  return pin;
}

function check(version) {
  if (!existsSync(TARGET) || !existsSync(SUMS)) fail('vendored copy or SHA256SUMS is missing');
  const recorded = parseSums(readFileSync(SUMS, 'utf8')).get('supabase.js');
  const vendored = sha256(readFileSync(TARGET));
  const source = sha256(readFileSync(SOURCE));
  if (recorded !== vendored) fail('approval-app/vendor/supabase.js does not match SHA256SUMS');
  if (vendored !== source) fail(`vendored copy differs from the installed ${PKG} ${version} build`);
  console.log(`vendor-supabase-js: OK ${PKG} ${version} sha256 ${vendored}`);
}

function write(version) {
  const bytes = readFileSync(SOURCE);
  const hash = sha256(bytes);
  mkdirSync(VENDOR_DIR, { recursive: true });
  writeFileSync(TARGET, bytes);
  writeFileSync(SUMS, `${hash}  supabase.js\n`);
  console.log(`vendor-supabase-js: wrote ${PKG} ${version} (${bytes.length} bytes) sha256 ${hash}`);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === join(process.argv[1]);
if (isMain) {
  const version = pinnedVersion();
  if (process.argv.includes('--check')) check(version);
  else write(version);
}
