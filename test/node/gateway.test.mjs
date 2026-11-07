// ============================================================================
// FinAgent OS - notifier Code nodes (fao_hitl_gateway_v1.json)
// Controls: FAO-GOV-007 (notification payload, escaping, one link, outcome
// classification), FAO-GOV-004 (the invoker is never offered as an approver).
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runCodeNode, nodeOf } from './harness.mjs';

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

function context(kind, level) {
  return {
    ok: true, code: 'OK', http_status: 200, message: 'OK', ref: null,
    send: true, hitl_id: 77, kind, level,
    agent_id: 'fao_reserve_recon_v1',
    agent_name: MARK.agent,
    risk_tier: 'RED', sub_tier: 'CRITICAL',
    timeout_at: '2026-11-08T12:00:00Z',
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

async function compose(kind, level) {
  const r = context(kind, level);
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
    const text = msg.body.text;
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
