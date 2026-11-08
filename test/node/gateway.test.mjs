// ============================================================================
// FinAgent OS - notifier Code nodes (fao_hitl_gateway_v1.json)
// Controls: FAO-GOV-007 (notification payload, escaping, one link, outcome
// classification), FAO-GOV-004 (the invoker is never offered as an approver).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { runCodeNode, nodeOf, WORKFLOWS } from './harness.mjs';

const WF = 'fao_hitl_gateway_v1.json';
const ERR = /FAO-GOV-007 notifier: \S+ invalid/;

// --- Validate Payload ----------------------------------------------------------

test('Validate Payload accepts (REQUESTED, 0) and (ESCALATED, 1) and reads nothing else', async () => {
  for (const [kind, level] of [['REQUESTED', 0], ['ESCALATED', 1]]) {
    const out = await runCodeNode(WF, 'Validate Payload', {
      items: [{ hitl_id: 17, kind, level, approval_url: 'https://evil.example/x', invoker_email: 'evil@example.com', text: 'evil-text' }],
    });
    assert.equal(out.length, 1);
    assert.equal(out[0].hitl_id, 17);
    assert.equal(out[0].kind, kind);
    assert.equal(out[0].level, level);
    const text = JSON.stringify(out);
    for (const s of ['evil.example', 'evil@example.com', 'evil-text']) assert.ok(!text.includes(s), `output carries ${s}`);
  }
});

test('Validate Payload refuses each malformed field and each wrong (kind, level) pair', async () => {
  const good = { hitl_id: 5, kind: 'REQUESTED', level: 0 };
  const cases = [
    { ...good, hitl_id: 0 },
    { ...good, hitl_id: -1 },
    { ...good, hitl_id: 1.5 },
    { ...good, hitl_id: '5' },
    { ...good, hitl_id: null },
    { kind: 'REQUESTED', level: 0 },
    { ...good, hitl_id: 2 ** 53 },
    { ...good, hitl_id: NaN },
    { ...good, hitl_id: Infinity },
    { ...good, kind: 'requested' },
    { ...good, kind: 'DECIDED' },
    { ...good, kind: null },
    { hitl_id: 5, level: 0 },
    { ...good, level: '0' },
    { ...good, level: 2 },
    { ...good, level: -1 },
    { hitl_id: 5, kind: 'REQUESTED' },
    { hitl_id: 5, kind: 'REQUESTED', level: 1 },
    { hitl_id: 5, kind: 'ESCALATED', level: 0 },
  ];
  for (const c of cases) {
    await assert.rejects(runCodeNode(WF, 'Validate Payload', { items: [c] }), ERR, `refuses ${JSON.stringify(c)}`);
  }
});

// --- Compose Slack Message ------------------------------------------------------

const MARK = {
  agent: '<b>Reserve & Recon</b>',
  approverA: '<@U123> & co',
  approverB: 'Zed <!here>',
  target: '<!channel> Marcus & Co',
  asset: '<SOL>',
  invoker: 'Aisha Invoker Name',
};

// Deadlines relative to the test's own clock, so the wording under test does
// not change with the date the suite runs.
const FUTURE = new Date(Date.now() + 86400000).toISOString();
const PAST = new Date(Date.now() - 3600000).toISOString();

function context(kind, level) {
  return {
    ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null,
    send: true, hitl_id: 77, kind, level,
    agent_id: 'fao_reserve_recon_v1',
    agent_name: MARK.agent,
    risk_tier: 'RED', sub_tier: 'CRITICAL',
    timeout_at: FUTURE,
    approval_url: 'http://localhost:4173/?hitl_id=77',
    escalated_assets: [{ asset: MARK.asset, policy_outcome: 'REQUIRE_HUMAN', policy_sub_tier: 'CRITICAL', band_status: 'BELOW_FLOOR' }],
    approver_candidates: [{ name: MARK.approverA }, { name: MARK.approverB }],
    target_name: kind === 'ESCALATED' ? MARK.target : null,
    slack_api_base_url: 'http://127.0.0.1:8099/api',
    slack_channel_id: 'C0TESTCHAN',
    invoker_name: MARK.invoker,
    agent_invoker_name: MARK.invoker,
  };
}

async function compose(kind, level, over = {}) {
  const r = { ...context(kind, level), ...over };
  const upstream = {
    'Trigger input schema': [{ hitl_id: 77, kind, level }],
    'Validate Payload': [{ hitl_id: 77, kind, level }],
    'Get Notification Context': [{ r }],
    'Should Send?': [{ r }],
  };
  const out = await runCodeNode(WF, 'Compose Slack Message', { items: [{ r }], upstream });
  assert.equal(out.length, 1);
  return { r, msg: out[0] };
}

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

for (const [kind, level] of [['REQUESTED', 0], ['ESCALATED', 1]]) {
  test(`Compose Slack Message (${kind}) escapes every dynamic field and has exactly one URL`, async () => {
    const { r, msg } = await compose(kind, level);
    assert.equal(msg.hitl_id, 77);
    assert.equal(msg.kind, kind);
    assert.equal(msg.level, level);
    assert.equal(msg.url, `${r.slack_api_base_url}/chat.postMessage`);
    assert.equal(msg.body.channel, 'C0TESTCHAN');
    assert.equal(msg.body.mrkdwn, true);
    assert.equal(msg.compose_ok, true);
    const text = msg.body.text;
    assert.ok(text.includes(`*Decide by:* ${r.timeout_at}`), 'shows the deadline');
    assert.ok(text.includes('approve or reject'), 'asks for a decision before the deadline');
    assert.equal(typeof text, 'string');
    for (const raw of [MARK.agent, MARK.approverA, MARK.approverB, MARK.target, MARK.asset]) {
      assert.ok(!text.includes(raw), `unescaped ${raw}`);
    }
    for (const bad of ['<b>', '<@U123>', '<!here>', '<!channel>', '<SOL>', 'Recon</b>']) {
      assert.ok(!text.includes(bad), `text contains ${bad}`);
    }
    assert.ok(text.includes(esc(MARK.agent)), 'agent name appears escaped');
    const urls = text.match(/https?:\/\/[^\s|>]+/g) || [];
    assert.equal(urls.length, 1, `exactly one URL, found ${JSON.stringify(urls)}`);
    assert.equal(urls[0], r.approval_url);
    assert.ok(!text.includes(MARK.invoker), 'never names the invoker');
    if (kind === 'REQUESTED') {
      assert.ok(text.includes(esc(MARK.approverA)), 'names approver A, escaped');
      assert.ok(text.includes(esc(MARK.approverB)), 'names approver B, escaped');
    } else {
      assert.ok(text.includes(esc(MARK.target)), 'names the escalation target, escaped');
    }
    assert.ok(!JSON.stringify(msg).includes(MARK.invoker), 'payload never names the invoker');
  });
}

test('Compose Slack Message builds the URL from slack_api_base_url', async () => {
  const r = { ...context('REQUESTED', 0), slack_api_base_url: 'https://slack.example.invalid/api' };
  const upstream = {
    'Trigger input schema': [{ hitl_id: 77, kind: 'REQUESTED', level: 0 }],
    'Validate Payload': [{ hitl_id: 77, kind: 'REQUESTED', level: 0 }],
    'Get Notification Context': [{ r }],
    'Should Send?': [{ r }],
  };
  const out = await runCodeNode(WF, 'Compose Slack Message', { items: [{ r }], upstream });
  assert.equal(out[0].url, 'https://slack.example.invalid/api/chat.postMessage');
});

// --- Classify Slack Result ---------------------------------------------------------

const httpNode = nodeOf(WF, 'Slack: Post Message');
const fullResponse = Boolean(httpNode && httpNode.parameters && httpNode.parameters.options
  && httpNode.parameters.options.response && httpNode.parameters.options.response.response
  && httpNode.parameters.options.response.response.fullResponse);

function successItem(body, statusCode = 200) {
  return fullResponse ? { statusCode, statusMessage: 'OK', headers: {}, body } : body;
}

async function classify(items, kind = 'REQUESTED', level = 0) {
  const upstream = {
    'Validate Payload': [{ hitl_id: 77, kind, level }],
    'Compose Slack Message': [{ hitl_id: 77, kind, level, url: 'http://127.0.0.1:8099/api/chat.postMessage', body: {} }],
  };
  const out = await runCodeNode(WF, 'Classify Slack Result', { items, upstream });
  assert.equal(out.length, 1);
  assert.equal(out[0].hitl_id, 77);
  assert.equal(out[0].kind, kind);
  assert.equal(out[0].level, level);
  return out[0];
}

test('Classify Slack Result: HTTP 200 with ok:true is SENT with the message ts', async () => {
  const o = await classify([successItem({ ok: true, ts: '1730900000.000100', channel: 'C0TESTCHAN' })], 'ESCALATED', 1);
  assert.equal(o.outcome, 'SENT');
  assert.equal(o.external_ref, '1730900000.000100');
  assert.ok(o.error == null, 'no error on SENT');
});

test('Classify Slack Result: ok:false is FAILED', async () => {
  const o = await classify([successItem({ ok: false, error: 'channel_not_found' })]);
  assert.equal(o.outcome, 'FAILED');
  assert.equal(typeof o.error, 'string');
  assert.ok(o.error.length > 0 && o.error.length <= 300);
});

test('Classify Slack Result: the HTTP error output is FAILED with the error cut to 300 characters', async () => {
  const long = 'x'.repeat(1000);
  for (const item of [
    { error: { message: `500 - ${long}`, name: 'NodeApiError', httpCode: '500' } },
    { error: `connect ECONNREFUSED 127.0.0.1:8099 ${long}` },
  ]) {
    const o = await classify([item]);
    assert.equal(o.outcome, 'FAILED');
    assert.equal(typeof o.error, 'string');
    assert.ok(o.error.length > 0 && o.error.length <= 300, `error length ${o.error.length}`);
    assert.equal(o.external_ref ?? null, null);
  }
});

if (fullResponse) {
  test('Classify Slack Result: a non-200 status with ok:true is FAILED', async () => {
    const o = await classify([successItem({ ok: true, ts: '1.2' }, 201)]);
    assert.equal(o.outcome, 'FAILED');
  });
}

// --- Compose Slack Message: expired escalation, empty target, bad settings ---

test('Compose Slack Message: an ESCALATED notice after the deadline says expired and asks for no decision', async () => {
  const { r, msg } = await compose('ESCALATED', 1, { timeout_at: PAST });
  assert.equal(msg.compose_ok, true);
  const text = msg.body.text;
  assert.match(text, /^\*Escalation: approval request 77 for .+ expired without a decision\*/);
  assert.ok(text.includes(`*Deadline passed:* ${PAST}`), 'shows the past deadline as passed');
  assert.ok(!text.includes('Decide by'), 'no "Decide by" for an expired request');
  assert.ok(!/approve or reject/i.test(text), 'no call to approve or reject');
  assert.ok(!text.includes('needs attention'), 'not the pending escalation header');
  assert.ok(text.includes('No decision can be recorded now'), 'says no decision can be recorded');
  assert.ok(text.includes('status FAILURE'), 'says the run was closed with FAILURE');
  assert.ok(text.includes(esc(MARK.target)), 'still names the target, escaped');
  for (const bad of ['<b>', '<!channel>', '<SOL>']) assert.ok(!text.includes(bad), `text contains ${bad}`);
  const urls = text.match(/https?:\/\/[^\s|>]+/g) || [];
  assert.deepEqual(urls, [r.approval_url], 'exactly one URL, the request page');
  assert.ok(!JSON.stringify(msg).includes(MARK.invoker), 'payload never names the invoker');
});

test('Compose Slack Message: a pending ESCALATED notice (NOTIFICATION_FAILED) keeps the decide-by wording', async () => {
  const { msg } = await compose('ESCALATED', 1, { timeout_at: FUTURE });
  assert.match(msg.body.text, /needs attention\*/);
  assert.ok(msg.body.text.includes(`*Decide by:* ${FUTURE}`));
  assert.ok(!msg.body.text.includes('Deadline passed'));
});

test('Compose Slack Message: a REQUESTED notice never uses the expired wording', async () => {
  const { msg } = await compose('REQUESTED', 0, { timeout_at: PAST });
  assert.match(msg.body.text, /^\*Approval required: request 77 for /);
  assert.ok(!msg.body.text.includes('expired'));
});

test('Compose Slack Message: no eligible escalation target says none eligible (operator alerted)', async () => {
  for (const target_name of [null, undefined, '', '   ']) {
    const { msg } = await compose('ESCALATED', 1, { target_name });
    assert.ok(msg.body.text.includes('*Escalation target:* none eligible (operator alerted)\n'), `target ${JSON.stringify(target_name)}`);
  }
  const { msg } = await compose('ESCALATED', 1, { target_name: 'Marcus Patel' });
  assert.ok(msg.body.text.includes('*Escalation target:* Marcus Patel\n'));
});

test('Compose Slack Message: an unusable setting gives compose_ok false and the problem, without a request', async () => {
  const cases = [
    [{ slack_channel_id: '' }, /slack_channel_id invalid/],
    [{ slack_channel_id: null }, /slack_channel_id invalid/],
    [{ slack_api_base_url: 'ftp://slack.example/api' }, /slack_api_base_url invalid/],
    [{ slack_api_base_url: null }, /slack_api_base_url invalid/],
    [{ approval_url: 'javascript:alert(1)' }, /approval_url invalid/],
    [{ approval_url: 'http://x/ |evil' }, /approval_url invalid/],
  ];
  for (const [kind, level] of [['REQUESTED', 0], ['ESCALATED', 1]]) {
    for (const [over, re] of cases) {
      const { msg } = await compose(kind, level, over);
      const label = `${kind} ${JSON.stringify(over)}`;
      assert.equal(msg.compose_ok, false, label);
      assert.match(msg.compose_error, /^FAO-GOV-007 notifier: /, label);
      assert.match(msg.compose_error, re, label);
      assert.equal(msg.hitl_id, 77, label);
      assert.equal(msg.kind, kind, label);
      assert.equal(msg.level, level, label);
      assert.equal(msg.url, undefined, `${label}: no url`);
      assert.equal(msg.body, undefined, `${label}: no body`);
    }
  }
  const { msg } = await compose('REQUESTED', 0, { slack_channel_id: '', approval_url: 'nope' });
  assert.match(msg.compose_error, /approval_url invalid; slack_channel_id invalid/, 'lists every problem');
});

test('Compose Slack Message still throws on a context that is not sendable or a bad kind', async () => {
  const run = (r) => runCodeNode(WF, 'Compose Slack Message', { items: [{ r }], upstream: { 'Validate Payload': [{ hitl_id: 77, kind: 'REQUESTED', level: 0 }] } });
  await assert.rejects(run({ ...context('REQUESTED', 0), send: false }), /not sendable/);
  await assert.rejects(run({ ...context('REQUESTED', 0), ok: false }), /not sendable/);
  await assert.rejects(run(null), /not sendable/);
  await assert.rejects(run({ ...context('REQUESTED', 0), kind: 'DECIDED' }), /kind invalid/);
});

test('Compose OK? sends compose_ok true to Slack and false straight to Classify Slack Result', () => {
  const n = nodeOf(WF, 'Compose OK?');
  assert.ok(n, 'node exists');
  assert.equal(n.type, 'n8n-nodes-base.if');
  const conds = n.parameters.conditions.conditions;
  assert.equal(conds.length, 1);
  assert.equal(conds[0].leftValue, '={{ $json.compose_ok === true }}');
  assert.deepEqual(conds[0].operator, { type: 'boolean', operation: 'true', singleValue: true });
  const wf = JSON.parse(readFileSync(join(WORKFLOWS, WF), 'utf8'));
  const outs = wf.connections['Compose OK?'].main.map((o) => o.map((c) => c.node));
  assert.deepEqual(outs, [['Slack: Post Message'], ['Classify Slack Result']]);
  assert.deepEqual(wf.connections['Compose Slack Message'].main.map((o) => o.map((c) => c.node)), [['Compose OK?']]);
});

test('Classify Slack Result: a compose failure is a FAILED attempt naming the setting', async () => {
  const o = await classify([{ hitl_id: 77, kind: 'REQUESTED', level: 0, compose_ok: false, compose_error: 'FAO-GOV-007 notifier: slack_channel_id invalid' }]);
  assert.equal(o.outcome, 'FAILED');
  assert.equal(o.error, 'compose error: FAO-GOV-007 notifier: slack_channel_id invalid');
  assert.equal(o.external_ref ?? null, null);
});

test('Classify Slack Result: the n8n 2.46 HTTP error item keeps the status and the Slack error code', async () => {
  // Shape stored by n8n 2.46.6 in the e2e run (S07, execution 3047): the
  // input fields merged with error {message, name, description, cause}, no
  // httpCode.
  const item = {
    hitl_id: 77, kind: 'REQUESTED', level: 0, compose_ok: true,
    url: 'http://127.0.0.1:8099/api/chat.postMessage', body: { channel: 'C0TESTCHAN', text: 't', mrkdwn: true },
    error: {
      message: 'The service was not able to process your request',
      timestamp: 1794073609313,
      name: 'NodeApiError',
      description: 'e2e_forced_failure',
      context: {},
      cause: { name: 'AxiosError', message: '500 - "{\\"ok\\":false,\\"error\\":\\"e2e_forced_failure\\"}"' },
    },
  };
  const o = await classify([item]);
  assert.equal(o.outcome, 'FAILED');
  assert.equal(o.error, 'http error 500: The service was not able to process your request (e2e_forced_failure)');
  // Without description the Slack error code is read from the cause body.
  const { description, ...noDesc } = item.error;
  const o2 = await classify([{ ...item, error: noDesc }]);
  assert.equal(o2.error, 'http error 500: The service was not able to process your request (e2e_forced_failure)');
  // A status on the cause object itself.
  const o3 = await classify([{ ...item, error: { message: 'Bad gateway', cause: { status: 502 } } }]);
  assert.equal(o3.error, 'http error 502: Bad gateway');
  // A network error has no status.
  const o4 = await classify([{ error: { message: 'connect ECONNREFUSED 127.0.0.1:8099', name: 'NodeApiError', cause: { message: 'connect ECONNREFUSED 127.0.0.1:8099' } } }]);
  assert.equal(o4.error, 'http error: connect ECONNREFUSED 127.0.0.1:8099');
});

// --- Compose Slack Message: dual approval (DUAL-APPROVAL.md 8.2, 9.3 N1 to N7) ---

const CORE_CLOSING = '_Sign in on the approval page to approve or reject. The person who started the run cannot decide it._';
const DUAL_CLOSING = '_Sign in on the approval page to approve or reject. The person who started the run cannot decide it. Each approver counts once; one rejection closes the request._';
const EXPIRED_CLOSING = '_No decision can be recorded now: the request expired unanswered and the run was closed with status FAILURE. Please review why it was not decided in time._';
const NEEDED_2 = '*Approvals needed:* 2 from different approvers';
const WARNING = '*Warning:* fewer eligible approvers than approvals needed; this request can only be rejected or expire';
const APPROVER_MARK = '<b>Sarah</b> & <!here>';

const linesOf = (msg) => msg.body.text.split('\n');
const indexOf = (lines, prefix) => lines.findIndex((l) => l.startsWith(prefix));

// N7 for every dual case: exactly one URL, the request page.
function oneUrl(r, msg, label) {
  const urls = msg.body.text.match(/https?:\/\/[^\s|>]+/g) || [];
  assert.deepEqual(urls, [r.approval_url], `${label}: exactly one URL, the request page`);
}

test('N1: enforced_approvals 1, absent, null or a string: no approval lines and the core closing line', async () => {
  for (const [kind, level] of [['REQUESTED', 0], ['ESCALATED', 1]]) {
    for (const over of [
      { enforced_approvals: 1, approvals_received: 1, approved_by: [{ name: 'Sarah Chen' }] },
      {},
      { enforced_approvals: null },
      { enforced_approvals: '2', approvals_received: 1, approved_by: [{ name: 'Sarah Chen' }] },
      { enforced_approvals: 2.5 },
      { enforced_approvals: 0 },
    ]) {
      const label = `${kind} ${JSON.stringify(over)}`;
      const { r, msg } = await compose(kind, level, over);
      assert.equal(msg.compose_ok, true, label);
      const lines = linesOf(msg);
      assert.ok(!lines.some((l) => l.startsWith('*Approvals') || l.startsWith('*Warning:*')), `${label}: no approval line`);
      assert.equal(lines.at(-1), CORE_CLOSING, `${label}: core closing line`);
      assert.ok(!msg.body.text.includes('Each approver counts once'), label);
      oneUrl(r, msg, `N1 ${label}`);
    }
  }
});

test('N2: REQUESTED with 2: one Approvals needed line right after Eligible approvers, and the dual closing line', async () => {
  const { r, msg } = await compose('REQUESTED', 0, { enforced_approvals: 2, approvals_received: 0, approved_by: [] });
  const lines = linesOf(msg);
  assert.equal(lines.filter((l) => l === NEEDED_2).length, 1, 'exactly one needed line');
  assert.equal(lines.filter((l) => l.startsWith('*Approvals needed:*')).length, 1);
  const i = indexOf(lines, '*Eligible approvers:*');
  assert.ok(i >= 0, 'eligible approvers line present');
  assert.equal(lines[i + 1], NEEDED_2, 'needed line right after the eligible approvers line');
  assert.ok(!lines.some((l) => l.startsWith('*Approvals received:*')), 'no received line with 0 received');
  assert.ok(!lines.some((l) => l.startsWith('*Warning:*')), 'two candidates: no warning');
  assert.equal(lines.at(-1), DUAL_CLOSING);
  oneUrl(r, msg, 'N2');
});

test('N3: REQUESTED with 2 and one approval received: the received line, names escaped, after the needed line', async () => {
  const { r, msg } = await compose('REQUESTED', 0, { enforced_approvals: 2, approvals_received: 1, approved_by: [{ name: APPROVER_MARK }] });
  const lines = linesOf(msg);
  const i = lines.indexOf(NEEDED_2);
  assert.ok(i >= 0, 'needed line present');
  assert.equal(lines[i + 1], `*Approvals received:* 1 of 2 (${esc(APPROVER_MARK)})`);
  assert.equal(lines[i + 1], '*Approvals received:* 1 of 2 (&lt;b&gt;Sarah&lt;/b&gt; &amp; &lt;!here&gt;)');
  for (const bad of ['<b>', '<!here>', 'Sarah</b>']) assert.ok(!msg.body.text.includes(bad), `text contains ${bad}`);
  assert.equal(lines.at(-1), DUAL_CLOSING);
  oneUrl(r, msg, 'N3');
});

test('N4: REQUESTED with 2 and one eligible candidate: the warning line, last of the approval lines', async () => {
  for (const [received, approved_by, expected] of [
    [0, [], [NEEDED_2, WARNING]],
    [1, [{ name: 'Sarah Chen' }], [NEEDED_2, '*Approvals received:* 1 of 2 (Sarah Chen)', WARNING]],
  ]) {
    const { r, msg } = await compose('REQUESTED', 0, {
      enforced_approvals: 2, approvals_received: received, approved_by, approver_candidates: [{ name: 'Sarah Chen' }],
    });
    const lines = linesOf(msg);
    const i = indexOf(lines, '*Eligible approvers:*');
    assert.equal(lines[i], '*Eligible approvers:* Sarah Chen');
    assert.deepEqual(lines.slice(i + 1, i + 1 + expected.length), expected, `received ${received}: lines in order`);
    assert.equal(lines.filter((l) => l === WARNING).length, 1, 'one warning line');
    assert.equal(lines[i + 1 + expected.length], '', 'the warning is the last approval line');
    oneUrl(r, msg, `N4 received ${received}`);
  }
  const { msg } = await compose('REQUESTED', 0, { enforced_approvals: 2, approver_candidates: [] });
  assert.ok(linesOf(msg).includes(WARNING), 'no candidate at all: warning');
});

test('N5: ESCALATED with 2 and none received: "0 of 2" with no parentheses, right after the escalation target', async () => {
  for (const approved_by of [[], [{ name: 'Sarah Chen' }]]) {
    const { r, msg } = await compose('ESCALATED', 1, { enforced_approvals: 2, approvals_received: 0, approved_by });
    const lines = linesOf(msg);
    const i = indexOf(lines, '*Escalation target:*');
    assert.ok(i >= 0, 'escalation target line present');
    assert.equal(lines[i + 1], '*Approvals received:* 0 of 2', `approved_by ${JSON.stringify(approved_by)}`);
    assert.ok(!lines[i + 1].includes('('), 'no parentheses');
    assert.ok(!lines.some((l) => l.startsWith('*Approvals needed:*') || l.startsWith('*Warning:*')), 'REQUESTED-only lines absent');
    assert.equal(lines.at(-1), DUAL_CLOSING);
    oneUrl(r, msg, 'N5');
  }
  const { msg } = await compose('ESCALATED', 1, { enforced_approvals: 2, approvals_received: 1, approved_by: [{ name: APPROVER_MARK }] });
  const lines = linesOf(msg);
  assert.equal(lines[indexOf(lines, '*Escalation target:*') + 1], `*Approvals received:* 1 of 2 (${esc(APPROVER_MARK)})`);
});

test('N6: ESCALATED after the deadline: the expired closing line unchanged, the received line present', async () => {
  const { r, msg } = await compose('ESCALATED', 1, {
    timeout_at: PAST, enforced_approvals: 2, approvals_received: 1, approved_by: [{ name: 'Sarah Chen' }],
  });
  const lines = linesOf(msg);
  assert.match(lines[0], /expired without a decision\*$/);
  assert.equal(lines[indexOf(lines, '*Escalation target:*') + 1], '*Approvals received:* 1 of 2 (Sarah Chen)');
  assert.equal(lines.at(-1), EXPIRED_CLOSING, 'expired closing line unchanged');
  assert.ok(!msg.body.text.includes('Each approver counts once'), 'no dual closing line after the deadline');
  assert.ok(!/approve or reject/i.test(msg.body.text), 'no call to decide');
  oneUrl(r, msg, 'N6');
});

test('N7: every dual-approval notice has exactly one URL, the request page, and never names the invoker', async () => {
  const variants = [
    ['REQUESTED', 0, { enforced_approvals: 2 }],
    ['REQUESTED', 0, { enforced_approvals: 3, approvals_received: 2, approved_by: [{ name: 'Sarah Chen' }, { name: APPROVER_MARK }] }],
    ['REQUESTED', 0, { enforced_approvals: 2, approver_candidates: [] }],
    ['ESCALATED', 1, { enforced_approvals: 2, approvals_received: 1, approved_by: [{ name: 'Sarah Chen' }] }],
    ['ESCALATED', 1, { enforced_approvals: 2, timeout_at: PAST }],
  ];
  for (const [kind, level, over] of variants) {
    const label = `${kind} ${JSON.stringify(over)}`;
    const { r, msg } = await compose(kind, level, over);
    assert.equal(msg.compose_ok, true, label);
    const text = msg.body.text;
    const urls = text.match(/https?:\/\/[^\s|>]+/g) || [];
    assert.deepEqual(urls, [r.approval_url], `${label}: exactly one URL`);
    assert.equal((text.match(/<http/g) || []).length, 1, `${label}: one Slack link`);
    assert.ok(!JSON.stringify(msg).includes(MARK.invoker), `${label}: never names the invoker`);
  }
});
