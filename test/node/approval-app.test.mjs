// ============================================================================
// FinAgent OS - approval page pure functions and static rules (approval-app/)
// Controls: FAO-GOV-004 (decision page shows only fixed messages, renders
// text without markup, ships a pinned client and a strict page policy).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { REPO_ROOT } from './harness.mjs';

const APP = join(REPO_ROOT, 'approval-app');
const read = (f) => readFileSync(join(APP, f), 'utf8');
const app = await import(pathToFileURL(join(APP, 'app.js')).href);

// Section 2.6 of the build spec.
const MESSAGES = {
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
  BUSY: 'Someone else is deciding this request. Try again.',
  NO_RUN_RECORD: 'This request has no run record.',
  ALREADY_CLAIMED: 'This run has already started.',
  ALREADY_DECIDED: 'This request has already been decided.',
  EXPIRED: 'This request has expired.',
  TOKEN_EXPIRED: 'The run token has expired.',
  INVALID_TOKEN: 'The run token is not valid.',
  RATE_LIMITED: 'Too many runs in the last hour.',
  AUDIT_CHAIN_MISMATCH: "Recorded, but the run's ledger chain is incomplete, so it was not committed.",
  UNKNOWN_EXECUTION: 'No run matches this execution.',
  ALREADY_TERMINAL: 'The run has already finished.',
  NOT_PENDING: 'Nothing to send.',
  ALREADY_SENT: 'Already sent.',
};
const HTTP = {
  OK: 200, NO_SESSION: 401, INVALID_INPUT: 400, NOT_AN_OWNER: 403, NOT_AUTHORISED: 403, SOD_SELF_APPROVAL: 403,
  SELF_CHANGE: 403, NOT_FOUND: 404, UNKNOWN_AGENT: 404, AGENT_NOT_ACTIVE: 409, BUSY: 409, NO_RUN_RECORD: 409,
  ALREADY_CLAIMED: 409, ALREADY_DECIDED: 410, EXPIRED: 410, TOKEN_EXPIRED: 410, INVALID_TOKEN: 401, RATE_LIMITED: 429,
  AUDIT_CHAIN_MISMATCH: 200, UNKNOWN_EXECUTION: 200, ALREADY_TERMINAL: 200, NOT_PENDING: 200, ALREADY_SENT: 200,
};

// --- parseHitlId ---------------------------------------------------------------

test('parseHitlId accepts 1 to 12 digits with a value of at least 1', () => {
  for (const [search, id] of [['?hitl_id=1', '1'], ['?hitl_id=42', '42'], ['?hitl_id=999999999999', '999999999999']]) {
    const v = app.parseHitlId(search);
    assert.ok(v !== null && v !== undefined, `accepts ${search}`);
    assert.equal(String(v), id);
  }
  assert.ok(app.parseHitlId('?hitl_id=000000000007') != null, 'accepts 12 digits with leading zeros');
});

test('parseHitlId refuses everything else', () => {
  const bad = [
    '', '?', '?hitl_id=', '?hitl_id=0', '?hitl_id=000', '?hitl_id=-1', '?hitl_id=1.5', '?hitl_id=1e3',
    '?hitl_id=abc', '?hitl_id=12abc', '?hitl_id=%201', '?hitl_id=1%20', '?hitl_id=1234567890123',
    '?hitl_id=0x10', '?hitl_id=١', '?other=1', '?hitl_id=+1', '?hitl_id=1;2',
  ];
  for (const s of bad) {
    const v = app.parseHitlId(s);
    assert.ok(v === null, `refuses ${JSON.stringify(s)} (got ${JSON.stringify(v)})`);
  }
});

// --- statusMessage ---------------------------------------------------------------

test('statusMessage returns the 2.6 text for every code', () => {
  for (const [code, msg] of Object.entries(MESSAGES)) {
    assert.equal(app.statusMessage(HTTP[code], code), msg, code);
  }
});

test('statusMessage falls back by status when the response is not in the envelope', () => {
  assert.equal(app.statusMessage(401), 'Sign in to continue.');
  assert.equal(app.statusMessage(403), 'You are not authorised for this action.');
  assert.equal(app.statusMessage(404), 'Not found.');
  assert.equal(app.statusMessage(500), 'Something went wrong. Try again later.');
  assert.equal(app.statusMessage(503), 'Something went wrong. Try again later.');
  assert.equal(app.statusMessage(418), 'The request could not be completed.');
  assert.equal(app.statusMessage(401, 'PGRST301'), 'Sign in to continue.');
  assert.equal(app.statusMessage(500, 'relation "x" does not exist'), 'Something went wrong. Try again later.');
});

// --- buildViewModel ---------------------------------------------------------------

const M = '<img src=x onerror=alert(1)>&amp;<b>';
function getResult() {
  return {
    ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null,
    request: {
      hitl_id: 12,
      agent_id: 'fao_reserve_recon_v1',
      agent_name: `Agent ${M}`,
      risk_tier: 'RED',
      sub_tier: 'CRITICAL',
      policy_rationale: `Rationale ${M}`,
      escalated_assets: [{ asset: `SOL${M}`, policy_outcome: 'REQUIRE_HUMAN', policy_sub_tier: 'CRITICAL', band_status: `BELOW_FLOOR${M}` }],
      configured_approvals: 2,
      enforced_approvals: 1,
      created_at: '2026-11-07T10:00:00Z',
      timeout_at: '2026-11-08T10:00:00Z',
      decision: 'PENDING',
      decided_at: null,
      invoker_name: `Invoker ${M}`,
      viewer_is_invoker: false,
      viewer_can_decide: true,
    },
  };
}
const MARKED = ['agent_name', 'policy_rationale', 'invoker_name'].map((k) => getResult().request[k]);

function leaves(v, out = []) {
  if (v === null || v === undefined) return out;
  if (typeof v === 'function') { out.push({ fn: true }); return out; }
  if (Array.isArray(v)) { v.forEach((x) => leaves(x, out)); return out; }
  if (typeof v === 'object') {
    if (typeof v.nodeType === 'number') out.push({ dom: true });
    Object.values(v).forEach((x) => leaves(x, out));
    return out;
  }
  out.push(v);
  return out;
}

test('buildViewModel returns the same plain strings for markup in every field', () => {
  let vm = app.buildViewModel(getResult());
  let strings = leaves(vm).filter((x) => typeof x === 'string');
  if (!MARKED.every((m) => strings.some((s) => s.includes(m)))) {
    vm = app.buildViewModel({ data: getResult(), error: null });
    strings = leaves(vm).filter((x) => typeof x === 'string');
  }
  for (const m of MARKED) assert.ok(strings.some((s) => s.includes(m)), `view model carries ${JSON.stringify(m)} unchanged`);
  assert.ok(strings.some((s) => s.includes(`SOL${M}`)), 'escalated asset symbol unchanged');
  for (const s of strings) assert.ok(!s.includes('&lt;') && !s.includes('&amp;amp;'), `no HTML escaping in ${JSON.stringify(s)}`);
  for (const x of leaves(vm)) {
    assert.ok(!(x && typeof x === 'object' && (x.fn || x.dom)), 'view model holds only plain values');
  }
});

// --- Static rules ------------------------------------------------------------------

test('app.js uses no HTML-writing or eval APIs', () => {
  const src = read('app.js');
  for (const re of [/\binnerHTML\b/, /\bouterHTML\b/, /\binsertAdjacentHTML\b/, /document\.write/, /\beval\b/]) {
    assert.ok(!re.test(src), `app.js matches ${re}`);
  }
});

test('index.html has no inline script or style', () => {
  const html = read('index.html');
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  assert.ok(scripts.length >= 3, 'loads config.js, vendor/supabase.js and app.js');
  for (const [, attrs, body] of scripts) {
    assert.match(attrs, /\bsrc\s*=/i, 'every script has src');
    assert.equal(body.trim(), '', 'no inline script body');
  }
  const srcs = scripts.map(([, a]) => (a.match(/\bsrc\s*=\s*["']([^"']+)["']/i) || [])[1]);
  assert.deepEqual(srcs.slice(0, 3), ['config.js', 'vendor/supabase.js', 'app.js']);
  assert.match(scripts[2][1], /type\s*=\s*["']module["']/i, 'app.js is a module');
  assert.ok(!/<style\b/i.test(html), 'no <style> element');
  assert.ok(!/\sstyle\s*=/i.test(html), 'no style attribute');
  assert.ok(!/\son[a-z]+\s*=/i.test(html), 'no inline event handler attribute');
  assert.ok(!/javascript:/i.test(html), 'no javascript: URL');
});

test('vendor/supabase.js matches SHA256SUMS', () => {
  const sums = read('vendor/SHA256SUMS');
  const line = sums.split(/\r?\n/).map((l) => l.trim()).find((l) => /supabase\.js$/.test(l));
  assert.ok(line, 'SHA256SUMS lists supabase.js');
  const expected = line.split(/\s+/)[0].toLowerCase();
  assert.match(expected, /^[0-9a-f]{64}$/);
  const actual = createHash('sha256').update(readFileSync(join(APP, 'vendor', 'supabase.js'))).digest('hex');
  assert.equal(actual, expected);
});

function parseHeadersFile(text) {
  const map = new Map();
  for (const raw of text.split(/\r?\n/)) {
    if (!/^\s+\S/.test(raw)) continue;
    const m = raw.trim().match(/^([A-Za-z0-9-]+):\s*(.*)$/);
    if (m) map.set(m[1].toLowerCase(), m[2].trim());
  }
  return map;
}

function parseServeJson(text) {
  const j = JSON.parse(text);
  const map = new Map();
  for (const rule of j.headers || []) {
    for (const h of rule.headers || []) map.set(String(h.key).toLowerCase(), String(h.value).trim());
  }
  return map;
}

function cspDirectives(v) {
  const out = new Map();
  for (const part of String(v || '').split(';').map((p) => p.trim()).filter(Boolean)) {
    const [name, ...rest] = part.split(/\s+/);
    out.set(name.toLowerCase(), rest.join(' '));
  }
  return out;
}

test('_headers and serve.json carry the same directives apart from connect-src', () => {
  assert.ok(existsSync(join(APP, '_headers')) && existsSync(join(APP, 'serve.json')));
  const cf = parseHeadersFile(read('_headers'));
  const sv = parseServeJson(read('serve.json'));
  const required = ['content-security-policy', 'x-frame-options', 'referrer-policy', 'cache-control', 'x-content-type-options'];
  for (const h of required) {
    assert.ok(cf.has(h), `_headers sets ${h}`);
    assert.ok(sv.has(h), `serve.json sets ${h}`);
  }
  assert.deepEqual([...cf.keys()].sort(), [...sv.keys()].sort(), 'same header names');
  for (const h of cf.keys()) {
    if (h === 'content-security-policy') continue;
    assert.equal(sv.get(h), cf.get(h), `same value for ${h}`);
  }
  const a = cspDirectives(cf.get('content-security-policy'));
  const b = cspDirectives(sv.get('content-security-policy'));
  const expected = {
    'default-src': "'none'", 'script-src': "'self'", 'style-src': "'self'", 'img-src': "'self'",
    'base-uri': "'none'", 'form-action': "'none'", 'frame-ancestors': "'none'",
  };
  for (const [d, v] of Object.entries(expected)) {
    assert.equal(a.get(d), v, `_headers ${d}`);
    assert.equal(b.get(d), v, `serve.json ${d}`);
  }
  assert.deepEqual([...a.keys()].filter((k) => k !== 'connect-src').sort(), [...b.keys()].filter((k) => k !== 'connect-src').sort());
  assert.equal(a.get('connect-src'), 'https://*.supabase.co');
  assert.equal(b.get('connect-src'), 'http://127.0.0.1:54321');
  assert.equal(cf.get('x-frame-options'), 'DENY');
  assert.equal(cf.get('referrer-policy'), 'no-referrer');
  assert.equal(cf.get('cache-control'), 'no-store');
  assert.equal(cf.get('x-content-type-options'), 'nosniff');
});
