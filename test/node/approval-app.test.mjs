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
  UNKNOWN_EXECUTION: 'No run matches this execution.',
  ALREADY_TERMINAL: 'The run has already finished.',
  NOT_PENDING: 'Nothing to send.',
  ALREADY_SENT: 'Already sent.',
  // Dual approval (DUAL-APPROVAL.md 4.2).
  AWAITING_FURTHER_APPROVAL: 'Approval recorded. This request needs more approvals before it is decided.',
  ALREADY_APPROVED: 'You have already approved this request.',
};
const HTTP = {
  OK: 200, NO_SESSION: 401, INVALID_INPUT: 400, NOT_AN_OWNER: 403, NOT_AUTHORISED: 403, SOD_SELF_APPROVAL: 403,
  SELF_CHANGE: 403, NOT_FOUND: 404, UNKNOWN_AGENT: 404, AGENT_NOT_ACTIVE: 409, INVOKER_NOT_ACTIVE: 409, BUSY: 409, NO_RUN_RECORD: 409,
  ALREADY_CLAIMED: 409, ALREADY_DECIDED: 410, EXPIRED: 410, TOKEN_EXPIRED: 410, INVALID_TOKEN: 401, RATE_LIMITED: 429,
  AUDIT_CHAIN_MISMATCH: 200, UNKNOWN_EXECUTION: 200, ALREADY_TERMINAL: 200, NOT_PENDING: 200, ALREADY_SENT: 200,
  AWAITING_FURTHER_APPROVAL: 200, ALREADY_APPROVED: 409,
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

// --- Fix round 2 (B2, B3, B4, B8) ---------------------------------------------------
test('noteLength counts code points against NOTES_MAX like the database (B3)', () => {
  assert.equal(app.NOTES_MAX, 2000);
  assert.equal(app.noteLength(''), 0);
  assert.equal(app.noteLength('abc'), 3);
  const emoji = '\u{1F600}';
  assert.equal(emoji.length, 2, 'one emoji is two UTF-16 units');
  assert.equal(app.noteLength(emoji), 1);
  assert.equal(app.noteLength(emoji.repeat(2000)), 2000, '2000 emoji are within the limit');
  assert.ok(app.noteLength(emoji.repeat(2000)) <= app.NOTES_MAX);
  assert.ok(app.noteLength('a'.repeat(2001)) > app.NOTES_MAX, '2001 characters are over the limit');
  assert.equal(app.noteLength(null), 0);
  assert.equal(app.noteLength(undefined), 0);
});

test('buildViewModel keeps the form for retryable refusals and only those (B2)', () => {
  const env = (code, http_status) => ({ ok: false, code, http_status, message: code, ref: 7 });
  assert.equal(app.buildViewModel(env('INVALID_INPUT', 400)).retry, true, 'INVALID_INPUT');
  assert.equal(app.buildViewModel(env('BUSY', 409)).retry, true, 'BUSY');
  assert.equal(app.buildViewModel({ http_status: 0 }).retry, true, 'network failure');
  assert.equal(app.buildViewModel(null).retry, true, 'no response at all');
  for (const s of [500, 502, 503]) assert.equal(app.buildViewModel({ http_status: s }).retry, true, `status ${s}`);
  for (const [code, s] of [['NOT_AUTHORISED', 403], ['SOD_SELF_APPROVAL', 403], ['NOT_FOUND', 404], ['NO_SESSION', 401]]) {
    assert.equal(app.buildViewModel(env(code, s)).retry, false, code);
  }
  assert.equal(app.buildViewModel({ http_status: 401 }).retry, false, 'plain 401');
});

test('buildViewModel drops empty fields and states the invoker text once (B4)', () => {
  const r = getResult();
  r.request.decided_at = null;
  r.request.sub_tier = '';
  r.request.escalated_assets = [];
  r.request.viewer_is_invoker = true;
  r.request.viewer_can_decide = false;
  const vm = app.buildViewModel(r);
  const labels = vm.fields.map((f) => (f && typeof f === 'object' ? (f.label ?? f[0]) : f));
  const flat = JSON.stringify(vm.fields);
  assert.ok(!flat.includes('Decided at'), `no empty Decided at row: ${JSON.stringify(labels)}`);
  assert.ok(!flat.includes('Review sub-tier'), 'no empty sub-tier row');
  assert.deepEqual(vm.assets, [], 'no assets');
  const strings = leaves(vm).filter((x) => typeof x === 'string');
  const self = 'You cannot decide a run you started.';
  assert.equal(strings.filter((s) => s.includes(self)).length, 1, 'invoker text appears once');

  const closed = app.buildViewModel({
    ok: false, code: 'EXPIRED', http_status: 410, message: 'EXPIRED', ref: 3,
    request: { hitl_id: 5, decision: 'EXPIRED', decided_at: null },
  });
  assert.equal(closed.kind, 'closed');
  assert.ok(!JSON.stringify(closed.fields).includes('Decided at'), 'closed view has no empty Decided at row');
  assert.deepEqual(closed.assets, []);
});

test('serve.json redirects every docs and config file away from the page (B8)', () => {
  const sv = JSON.parse(read('serve.json'));
  const sources = (sv.redirects || []).map((r) => r.source);
  for (const f of ['/README.md', '/serve.json', '/config.example.js', '/vendor/SHA256SUMS', '/.gitattributes', '/_headers']) {
    assert.ok(sources.includes(`${f}*`), `serve.json redirects ${f} (trailing * also catches ${f}::$DATA)`);
  }
  for (const r of sv.redirects) assert.equal(r.destination, '/', `${r.source} goes to /`);
  assert.equal(sv.directoryListing, false);
});

// --- Round 4 (P2, KNOWN-LIMITS U16 (a)) ---------------------------------------------
// fao_hitl_decide APPROVED when the agent is no longer ACTIVE: the decision
// stands, the run is COMMIT_BLOCKED and FAILED, and the envelope is the
// journaled AGENT_NOT_ACTIVE refusal carrying the decision fields.
function blockedResult() {
  return {
    ok: false, code: 'AGENT_NOT_ACTIVE', http_status: 409, message: 'server text <b>x</b>', ref: 41,
    hitl_id: 12, decision: 'APPROVED', decided_at: '2026-11-07T11:22:33Z',
    committed: false, committed_ledger_id: null,
  };
}
const BLOCKED_TEXT = 'Decision recorded. The run was not committed because the agent is no longer active.';

test('buildViewModel shows the recorded decision when the commit was blocked (P2)', () => {
  assert.equal(app.PAGE_TEXT.decidedNotCommitted, BLOCKED_TEXT, 'fixed text in the page text list');
  const vm = app.buildViewModel(blockedResult());
  assert.equal(vm.kind, 'decided', 'result view, not a generic error');
  assert.equal(vm.ok, false);
  assert.equal(vm.code, 'AGENT_NOT_ACTIVE');
  assert.equal(vm.message, BLOCKED_TEXT);
  assert.equal(vm.retry, false, 'no retry: the decision is final');
  assert.equal(vm.needsSignIn, false);
  assert.equal(vm.title, 'Request 12');
  assert.equal(vm.reference, 'Reference id: 41', 'journal reference shown');
  assert.deepEqual(vm.fields, [
    { label: 'Request id', value: '12' },
    { label: 'Decision', value: 'APPROVED' },
    { label: 'Decided at', value: '2026-11-07T11:22:33Z' },
    { label: 'Committed', value: 'No' },
  ]);
  const strings = leaves(vm).filter((x) => typeof x === 'string');
  assert.ok(!strings.some((s) => s.includes('server text')), 'server message text is never shown');
});

test('buildViewModel keeps a missing decided_at out of the blocked view (P2, B4)', () => {
  const r = blockedResult();
  r.decided_at = null;
  const vm = app.buildViewModel(r);
  assert.equal(vm.kind, 'decided');
  assert.ok(!JSON.stringify(vm.fields).includes('Decided at'));
});

test('AGENT_NOT_ACTIVE without the decision fields stays a plain refusal (P2)', () => {
  const plain = { ok: false, code: 'AGENT_NOT_ACTIVE', http_status: 409, message: 'x', ref: 9 };
  const vm = app.buildViewModel(plain);
  assert.equal(vm.kind, 'message');
  assert.equal(vm.message, 'The agent is not active.');
  assert.equal(vm.reference, 'Reference id: 9');
  for (const variant of [
    { ...blockedResult(), committed: true },
    { ...blockedResult(), committed: undefined },
    { ...blockedResult(), decision: '' },
    { ...blockedResult(), decision: null },
    { ...blockedResult(), code: 'NOT_AUTHORISED', http_status: 403 },
  ]) {
    assert.notEqual(app.buildViewModel(variant).message, BLOCKED_TEXT, JSON.stringify(variant));
  }
});

test('the blocked view carries markup in decision fields unchanged as plain text (P2)', () => {
  const r = blockedResult();
  r.decision = `APPROVED${M}`;
  r.decided_at = `t${M}`;
  const vm = app.buildViewModel(r);
  const values = vm.fields.map((f) => f.value);
  assert.ok(values.includes(`APPROVED${M}`) && values.includes(`t${M}`));
  for (const x of leaves(vm)) assert.ok(!(x && typeof x === 'object' && (x.fn || x.dom)));
});

// --- Round 5 (K2, K3; red team round 4 item 3) -------------------------------------
// K2: fao_hitl_decide APPROVED when the run's invoker is no longer active or
// no longer holds the invoker grant: the same key set as AGENT_NOT_ACTIVE.
const INVOKER_TEXT =
  'Decision recorded. The run was not committed because the invoker is no longer authorised for this agent.';

function invokerBlocked() {
  return {
    ok: false, code: 'INVOKER_NOT_ACTIVE', http_status: 409, message: 'server text <b>x</b>', ref: 77,
    hitl_id: 12, decision: 'APPROVED', decided_at: '2026-11-07T12:00:00Z',
    committed: false, committed_ledger_id: null,
  };
}

test('INVOKER_NOT_ACTIVE decide envelope shows the recorded decision and the fixed text (K2)', () => {
  assert.equal(app.PAGE_TEXT.decidedNotCommittedInvoker, INVOKER_TEXT, 'fixed text in PAGE_TEXT');
  const vm = app.buildViewModel(invokerBlocked());
  assert.equal(vm.kind, 'decided');
  assert.equal(vm.code, 'INVOKER_NOT_ACTIVE');
  assert.equal(vm.message, INVOKER_TEXT);
  assert.equal(vm.retry, false);
  assert.equal(vm.reference, 'Reference id: 77');
  assert.deepEqual(vm.fields, [
    { label: 'Request id', value: '12' },
    { label: 'Decision', value: 'APPROVED' },
    { label: 'Decided at', value: '2026-11-07T12:00:00Z' },
    { label: 'Committed', value: 'No' },
  ]);
  const strings = leaves(vm).filter((x) => typeof x === 'string');
  assert.ok(!strings.some((x) => x.includes('server text')), 'server message text is never shown');
  // The agent gate keeps its own text.
  assert.equal(app.buildViewModel(blockedResult()).message, BLOCKED_TEXT);
});

test('INVOKER_NOT_ACTIVE without the decision fields stays a plain refusal (K2)', () => {
  const vm = app.buildViewModel({ ok: false, code: 'INVOKER_NOT_ACTIVE', http_status: 409, message: 'x', ref: 5 });
  assert.equal(vm.kind, 'message');
  assert.equal(vm.message, 'The invoker is no longer authorised for this agent.');
  for (const variant of [
    { ...invokerBlocked(), committed: true },
    { ...invokerBlocked(), committed: undefined },
    { ...invokerBlocked(), decision: '' },
  ]) {
    assert.notEqual(app.buildViewModel(variant).message, INVOKER_TEXT, JSON.stringify(variant));
  }
});

// K3: fao_hitl_get carries committed and commit_blocked_reason at the top
// level of the ALREADY_DECIDED and EXPIRED envelopes; request keeps exactly
// hitl_id, decision and decided_at.
function decidedGet(over = {}) {
  return {
    ok: false, code: 'ALREADY_DECIDED', http_status: 410, message: 'server text', ref: null,
    request: { hitl_id: 12, decision: 'APPROVED', decided_at: '2026-11-07T12:00:00Z' },
    committed: false, commit_blocked_reason: null,
    ...over,
  };
}

test('reloading a decided request that was blocked shows the not-committed text and reason (K3)', () => {
  for (const [reason, text] of [['AGENT_NOT_ACTIVE', BLOCKED_TEXT], ['INVOKER_NOT_ACTIVE', INVOKER_TEXT]]) {
    const vm = app.buildViewModel(decidedGet({ commit_blocked_reason: reason }));
    assert.equal(vm.kind, 'closed', reason);
    assert.equal(vm.message, text, reason);
    assert.equal(vm.title, 'Request 12');
    assert.deepEqual(vm.fields, [
      { label: 'Request id', value: '12' },
      { label: 'Decision', value: 'APPROVED' },
      { label: 'Decided at', value: '2026-11-07T12:00:00Z' },
      { label: 'Committed', value: 'No' },
    ], reason);
  }
});

test('reloading a decided request: committed, rejected and unnamed reasons (K3)', () => {
  const committed = app.buildViewModel(decidedGet({ committed: true }));
  assert.equal(committed.message, 'This request has already been decided.');
  assert.ok(committed.fields.some((f) => f.label === 'Committed' && f.value === 'Yes'));

  const rejected = app.buildViewModel(decidedGet({ request: { hitl_id: 12, decision: 'REJECTED', decided_at: 't' } }));
  assert.equal(rejected.message, 'This request has already been decided.', 'a rejection is not a blocked commit');
  assert.ok(rejected.fields.some((f) => f.label === 'Committed' && f.value === 'No'));
  for (const reason of ['AGENT_NOT_ACTIVE', 'INVOKER_NOT_ACTIVE']) {
    const r = app.buildViewModel(decidedGet({
      request: { hitl_id: 12, decision: 'REJECTED', decided_at: 't' }, commit_blocked_reason: reason }));
    assert.equal(r.message, 'This request has already been decided.', reason);
  }

  const unnamed = app.buildViewModel(decidedGet());
  assert.equal(unnamed.message, 'Decision recorded. The run was not committed.');
  assert.equal(app.PAGE_TEXT.approvedNotCommitted, 'Decision recorded. The run was not committed.');

  // A reason outside the closed set is never shown or echoed.
  const odd = app.buildViewModel(decidedGet({ commit_blocked_reason: 'APPROVE_ALL<b>' }));
  assert.equal(odd.message, 'Decision recorded. The run was not committed.');
  assert.ok(!JSON.stringify(odd).includes('APPROVE_ALL'));

  // committed not a boolean: no Committed row, and the plain decided text.
  const noFlag = app.buildViewModel(decidedGet({ committed: 'false', commit_blocked_reason: 'AGENT_NOT_ACTIVE' }));
  assert.equal(noFlag.message, 'This request has already been decided.');
  assert.ok(!JSON.stringify(noFlag.fields).includes('Committed'));
  const legacy = app.buildViewModel({ ok: false, code: 'ALREADY_DECIDED', http_status: 410, request: { hitl_id: 3, decision: 'APPROVED', decided_at: 't' } });
  assert.equal(legacy.message, 'This request has already been decided.');
});

test('reloading an expired request keeps the expired text with Committed No (K3)', () => {
  const vm = app.buildViewModel({
    ok: false, code: 'EXPIRED', http_status: 410, message: 'x', ref: null,
    request: { hitl_id: 5, decision: 'EXPIRED', decided_at: null },
    committed: false, commit_blocked_reason: null,
  });
  assert.equal(vm.kind, 'closed');
  assert.equal(vm.message, 'This request has expired.');
  assert.deepEqual(vm.fields, [
    { label: 'Request id', value: '5' },
    { label: 'Decision', value: 'EXPIRED' },
    { label: 'Committed', value: 'No' },
  ]);
});

test('the page text list holds every not-committed text and app.js renders by textContent only (K2, K3)', () => {
  const src = read('app.js');
  for (const t of [BLOCKED_TEXT, INVOKER_TEXT, 'Decision recorded. The run was not committed.']) {
    assert.ok(Object.values(app.PAGE_TEXT).includes(t), t);
  }
  assert.ok(!/\binnerHTML\b/.test(src));
});

// --- Dual approval (DUAL-APPROVAL.md 8.3, 9.3) ---------------------------------------
// fao_hitl_get full form gains approvals_received (counted) and
// viewer_has_approved (raw); fao_hitl_decide returns AWAITING_FURTHER_APPROVAL
// for an approval that does not decide the request, and ALREADY_APPROVED for a
// repeat approval while the counted approvals are short.
const AWAITING_TEXT = 'Approval recorded. This request needs more approvals before it is decided.';
const APPROVED_AWAITING_TEXT =
  'You have approved this request. It needs more approvals before it is decided. You can still reject it.';
const REVIEW_TEXT = 'Review this request, then approve or reject it.';
const VIEW_ONLY_TEXT = 'You can view this request but not decide it.';

function dualGet(over = {}) {
  const r = getResult();
  r.request.enforced_approvals = 2;
  r.request.approvals_received = 0;
  r.request.viewer_has_approved = false;
  Object.assign(r.request, over);
  return r;
}
const labelsOf = (vm) => vm.fields.map((f) => f.label);
const fieldValue = (vm, label) => (vm.fields.find((f) => f.label === label) || {}).value;

test('the page text list and code texts carry the dual-approval texts', () => {
  assert.equal(app.CODE_MESSAGES.AWAITING_FURTHER_APPROVAL, AWAITING_TEXT);
  assert.equal(app.CODE_MESSAGES.ALREADY_APPROVED, 'You have already approved this request.');
  assert.equal(app.PAGE_TEXT.approvedAwaiting, APPROVED_AWAITING_TEXT);
  assert.equal(app.PAGE_TEXT.approvalsOf, ' of ');
  assert.equal(app.statusMessage(200, 'AWAITING_FURTHER_APPROVAL'), AWAITING_TEXT);
  assert.equal(app.statusMessage(409, 'ALREADY_APPROVED'), 'You have already approved this request.');
});

test('approvalsText gives "<n> of <e>" for valid counts and an empty string otherwise', () => {
  assert.equal(app.approvalsText(1, 2), '1 of 2');
  assert.equal(app.approvalsText(0, 2), '0 of 2');
  assert.equal(app.approvalsText(3, 3), '3 of 3');
  for (const [n, e] of [
    [-1, 2], [1, -2], [1.5, 2], [1, 2.5], ['1', 2], [1, '2'], [undefined, 2], [1, undefined], [null, 2], [1, null],
    [NaN, 2], [1, Infinity], [1, 0], [2 ** 53, 2], [true, 2],
  ]) {
    assert.equal(app.approvalsText(n, e), '', `approvalsText(${String(n)}, ${String(e)})`);
  }
  assert.equal(app.approvalsText(), '');
});

test('approvalsComplete is true only for valid counts with received at least enforced', () => {
  assert.equal(app.approvalsComplete(2, 2), true);
  assert.equal(app.approvalsComplete(3, 2), true);
  assert.equal(app.approvalsComplete(1, 2), false);
  assert.equal(app.approvalsComplete(0, 2), false);
  for (const [n, e] of [
    [2, 0], [0, 0], [-1, 2], [2, -1], [2.5, 2], [2, 1.5], ['2', 2], [2, '2'], [undefined, 2], [2, undefined],
    [null, 1], [2, null], [NaN, 1], [Infinity, 1], [true, 1],
  ]) {
    assert.equal(app.approvalsComplete(n, e), false, `approvalsComplete(${String(n)}, ${String(e)})`);
  }
  assert.equal(app.approvalsComplete(), false);
});

test('full form, may decide, not yet approved: Approve and Reject, review text, Approvals received after Enforced approvals', () => {
  const vm = app.buildViewModel(dualGet());
  assert.equal(vm.kind, 'request');
  assert.equal(vm.canDecide, true);
  assert.equal(vm.canApprove, true);
  assert.equal(vm.message, REVIEW_TEXT);
  const labels = labelsOf(vm);
  const i = labels.indexOf('Enforced approvals');
  assert.ok(i >= 0, `Enforced approvals shown: ${JSON.stringify(labels)}`);
  assert.equal(labels[i + 1], 'Approvals received', 'Approvals received right after Enforced approvals');
  assert.equal(fieldValue(vm, 'Approvals received'), '0 of 2');
  assert.equal(labels.filter((l) => l === 'Approvals received').length, 1);
});

test('full form, may decide, already approved and short of the count: Reject only, the approved-awaiting text', () => {
  const vm = app.buildViewModel(dualGet({ viewer_has_approved: true, approvals_received: 1 }));
  assert.equal(vm.kind, 'request');
  assert.equal(vm.canDecide, true);
  assert.equal(vm.canApprove, false);
  assert.equal(vm.message, APPROVED_AWAITING_TEXT);
  assert.equal(vm.message, app.PAGE_TEXT.approvedAwaiting);
  assert.equal(fieldValue(vm, 'Approvals received'), '1 of 2');
});

test('restore case (W23): already approved and every approval needed counts: Approve shown again, review text', () => {
  const vm = app.buildViewModel(dualGet({ viewer_has_approved: true, approvals_received: 2 }));
  assert.equal(vm.canDecide, true);
  assert.equal(vm.canApprove, true);
  assert.equal(vm.message, REVIEW_TEXT);
  assert.equal(fieldValue(vm, 'Approvals received'), '2 of 2');
});

test('invoker and view-only full forms: canApprove false and the core texts', () => {
  const inv = app.buildViewModel(dualGet({ viewer_is_invoker: true, viewer_can_decide: false }));
  assert.equal(inv.canDecide, false);
  assert.equal(inv.canApprove, false);
  assert.equal(inv.message, MESSAGES.SOD_SELF_APPROVAL);
  const ro = app.buildViewModel(dualGet({ viewer_can_decide: false }));
  assert.equal(ro.canDecide, false);
  assert.equal(ro.canApprove, false);
  assert.equal(ro.message, VIEW_ONLY_TEXT);
  // A viewer who approved and then lost the right to decide (DA-4, W31) is view-only.
  const lost = app.buildViewModel(dualGet({ viewer_can_decide: false, viewer_has_approved: true, approvals_received: 1 }));
  assert.equal(lost.canApprove, false);
  assert.equal(lost.message, VIEW_ONLY_TEXT);
  // canDecide must be exactly true.
  for (const v of ['true', 1, null, undefined]) {
    const vm = app.buildViewModel(dualGet({ viewer_can_decide: v }));
    assert.equal(vm.canDecide, false, `viewer_can_decide ${JSON.stringify(v)}`);
    assert.equal(vm.canApprove, false, `viewer_can_decide ${JSON.stringify(v)}`);
  }
});

test('every model that is not a decidable request carries canApprove false', () => {
  for (const r of [null, { http_status: 0 }, { ok: false, code: 'NOT_FOUND', http_status: 404, message: 'x', ref: 1 }]) {
    const vm = app.buildViewModel(r);
    assert.equal(vm.canApprove, false, JSON.stringify(r));
  }
});

function awaitingResult(over = {}) {
  return {
    ok: true, code: 'AWAITING_FURTHER_APPROVAL', http_status: 200, message: 'server text <b>x</b>', ref: null,
    hitl_id: 12, decision: 'PENDING', decided_at: null, committed: false, committed_ledger_id: null,
    approvals_received: 1, enforced_approvals: 2, approved_at: '2026-11-08T09:10:11.123456+00:00',
    ...over,
  };
}

test('an AWAITING_FURTHER_APPROVAL envelope: kind decided, its code text, the five fields', () => {
  const vm = app.buildViewModel(awaitingResult());
  assert.equal(vm.kind, 'decided');
  assert.equal(vm.ok, true);
  assert.equal(vm.code, 'AWAITING_FURTHER_APPROVAL');
  assert.equal(vm.message, AWAITING_TEXT);
  assert.equal(vm.title, 'Request 12');
  assert.equal(vm.retry, false);
  assert.equal(vm.needsSignIn, false);
  assert.equal(vm.canDecide, false);
  assert.equal(vm.canApprove, false);
  assert.deepEqual(vm.fields, [
    { label: 'Request id', value: '12' },
    { label: 'Decision', value: 'PENDING' },
    { label: 'Approvals received', value: '1 of 2' },
    { label: 'Approved at', value: '2026-11-08T09:10:11.123456+00:00' },
    { label: 'Committed', value: 'No' },
  ]);
  const strings = leaves(vm).filter((x) => typeof x === 'string');
  assert.ok(!strings.some((s) => s.includes('server text')), 'server message text is never shown');
});

test('ALREADY_APPROVED: a plain message with its code text, no retry', () => {
  const vm = app.buildViewModel({ ok: false, code: 'ALREADY_APPROVED', http_status: 409, message: 'server <b>x</b>', ref: 31 });
  assert.equal(vm.kind, 'message');
  assert.equal(vm.code, 'ALREADY_APPROVED');
  assert.equal(vm.message, 'You have already approved this request.');
  assert.equal(vm.retry, false);
  assert.equal(vm.needsSignIn, false);
  assert.equal(vm.reference, 'Reference id: 31');
  assert.equal(vm.canApprove, false);
});

test('counts missing or not integers: no Approvals received field; markup in approved_at stays a plain string', () => {
  for (const over of [
    { approvals_received: undefined }, { approvals_received: '1' }, { approvals_received: 1.5 }, { approvals_received: -1 },
    { enforced_approvals: undefined }, { enforced_approvals: '2' }, { enforced_approvals: 0 }, { approvals_received: null },
  ]) {
    const vm = app.buildViewModel(dualGet(over));
    assert.ok(!labelsOf(vm).includes('Approvals received'), `full form ${JSON.stringify(over)}`);
    const res = app.buildViewModel(awaitingResult(over));
    assert.equal(res.kind, 'decided', JSON.stringify(over));
    assert.ok(!labelsOf(res).includes('Approvals received'), `awaiting ${JSON.stringify(over)}`);
  }
  const marked = app.buildViewModel(awaitingResult({ approved_at: `t${M}` }));
  assert.equal(fieldValue(marked, 'Approved at'), `t${M}`, 'markup copied unchanged');
  for (const x of leaves(marked)) assert.ok(!(x && typeof x === 'object' && (x.fn || x.dom)), 'plain values only');
  const noTime = app.buildViewModel(awaitingResult({ approved_at: null }));
  assert.ok(!labelsOf(noTime).includes('Approved at'), 'no empty Approved at row');
});

test('the bootstrap shows Approve only when canApprove and Reject whenever the form is shown', () => {
  const src = read('app.js');
  assert.match(src, /ui\.show\(\s*['"]approve['"]\s*,\s*model\.canApprove\s*\)/);
  assert.match(src, /ui\.show\(\s*['"]reject['"]\s*,\s*true\s*\)/);
});
