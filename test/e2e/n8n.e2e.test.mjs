// ============================================================================
// FinAgent OS e2e: real n8n executions against the local stack
// ----------------------------------------------------------------------------
// Controls: FAO-GOV-001 (Writer appends, ordered chain), FAO-GOV-004 (one
// request, a different approver decides, self-approval refused, expiry and
// one escalation), FAO-GOV-007 (Slack notice, escaping, failure recorded and
// re-sent), FAO-GOV-008 (run token gate, header auth, error workflow),
// FAO-REC-001/002/004/006/007 (policy matrix and fail-closed inputs).
//
// Every run starts with fao_run_start as the signed-in invoker (PostgREST),
// then the token alone goes to the n8n production webhook, as the MCP invoke
// tool does. Tests run in order; each closes the requests it opens. Needs
// `node scripts/e2e-n8n.mjs up` first (scripts/test-all.mjs does that).
// ============================================================================

import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { assertLocalTargets } from './guard.mjs';
import * as L from './lib.mjs';
import {
  MARKUP_NOTE, MARKUP_NOTE_2, FAILING_NOTIFIER_ID, FAILING_NOTIFIER_MESSAGE, SWEEP_NFAIL_ID, SWEEP_NFAIL_PATH,
  DEPRECATE_AGENT, PAUSE_NODE, PAUSE_BEFORE_FINALIZE_MS,
  HARNESSES, GATEWAY_CALLER_ID, GATEWAY_CALLER_PATH, PRECLAIM_MESSAGE, VARIANTS,
} from './variants.mjs';

const P = L.state.variant_paths;
const FLAGSHIP_PATH = L.state.flagship_path;
const FLAGSHIP_WF = 'uhB2KjEaJDuviM4D';
const WRITER_WF = 'dQslIEVwF3WqMliT';
const GATEWAY_WF = 'mUAC9qIMkVzlV5qw';
const ERROR_WF = 'FaoErrHandlerV01';
const SWEEP_WF = 'FaoE2eSweepHook1';
const T = { timeout: 180000 };

const MARKUP_AGENT_NAME = '<b>E2E</b> & <!channel> <@U0E2E> "markup" agent';
const MARKUP_REASON = `<script>alert("reason")</script> & <!here> '; DROP TABLE public.run_invocations; -- ${'é'}`;
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

let channel;
before(async () => {
  channel = (await L.one("SELECT value FROM public.fao_settings WHERE key = 'slack_channel_id'")).value;
  await L.slack.reset();
  await L.slack.mode('ok');
});
after(L.closeAll);

const byWorkflow = (ex, wf) => ex.filter((e) => e.workflowId === wf);
const assets = (rows) => rows.filter((r) => r.t === 'ASSET_RECONCILED');

// Start a run, post its token, wait until it leaves RUNNING and every n8n
// execution it caused has stopped.
async function invoke(invoker, path, { agent, reason, minExecutions = 1 } = {}) {
  const before = L.lastExecutionId();
  const { corr, token } = await L.startRun(invoker, { agent, reason });
  const w = await L.webhook(path, { run_token: token });
  assert.equal(w.status, 202, `webhook answered ${w.status} ${w.text}`);
  assert.deepEqual(w.json, { accepted: true, correlation_id: corr });
  const r = await L.waitSettled(corr);
  if (r.state === 'AWAITING_HITL') {
    const req = (await L.requests(corr))[0];
    assert.ok(req, 'AWAITING_HITL without a request');
    await L.waitNotifications(Number(req.hitl_id), 1);
  }
  const ex = await L.waitExecutions(before, minExecutions);
  return { corr, token, run: await L.run(corr), ex, before };
}

async function openRequest(corr) {
  const reqs = await L.requests(corr);
  assert.equal(reqs.length, 1, 'exactly one request');
  return { ...reqs[0], hitl_id: Number(reqs[0].hitl_id) };
}

function record(t, scenario, data) {
  L.evidence(scenario, data);
  if (data.executions) t.diagnostic(`${scenario} executions ${data.executions}`);
}

// ---------------------------------------------------------------------------
test('S01 all-in-band run commits SUCCESS with 7 asset rows and no request', T, async (t) => {
  await L.slack.reset();
  const { corr, run, ex } = await invoke('sarah', P.inband, { minExecutions: 3 });
  assert.equal(run.state, 'COMMITTED');
  const rows = await L.ledger(corr);
  assert.deepEqual(rows.map((r) => r.t), ['STARTED', ...Array(7).fill('ASSET_RECONCILED'), 'COMMITTED']);
  assert.deepEqual(assets(rows).map((r) => r.inputs.asset), ['ADA', 'BTC', 'ETH', 'SOL', 'USDC', 'USDT', 'XRP']);
  for (const a of assets(rows)) {
    assert.equal(a.outcome, 'ALLOW', `${a.inputs.asset}`);
    assert.equal(a.inputs.band_status, 'IN_BAND');
    assert.equal(a.hitl_status, 'NOT_REQUIRED');
  }
  // Patch round 6 (P9, IC-38): the stablecoin band read from the database is
  // [1.0000, 1.0500], and USDC at 1.006 (above the old 1.0050) is IN_BAND.
  const byAsset = Object.fromEntries(assets(rows).map((a) => [a.inputs.asset, a]));
  for (const s of ['USDC', 'USDT']) {
    const th = byAsset[s].inputs.threshold || {};
    assert.deepEqual([Number(th.ratio_floor), Number(th.ratio_band_lower), Number(th.ratio_band_upper)], [1, 1, 1.05], `${s} band ${JSON.stringify(th)}`);
  }
  assert.equal(Number(byAsset.USDC.inputs.ratio), 1.006);
  assert.equal(Number(byAsset.USDC.inputs.discrepancy), 6000);
  const committed = rows.at(-1);
  assert.equal(committed.status, 'SUCCESS');
  assert.equal(committed.outcome, 'ALLOW');
  assert.equal((await L.requests(corr)).length, 0, 'no request');
  assert.equal(rows[0].inputs.invoker_id, L.uid('sarah'));
  assert.equal(rows[0].inputs.n8n_execution_id, run.n8n_execution_id);
  assert.equal((await L.slack.requests()).length, 0, 'no Slack message');
  const flag = ex.find((e) => e.id === run.n8n_execution_id);
  assert.equal(flag && flag.status, 'success');
  assert.equal(flag.lastNodeExecuted, 'Run Complete');
  assert.equal(byWorkflow(ex, WRITER_WF).filter((e) => e.status === 'success').length, 2, 'two Writer executions');
  assert.equal(byWorkflow(ex, GATEWAY_WF).length, 0, 'notifier not called');
  record(t, 'S01', { corr, state: run.state, ledger: rows.map((r) => r.t), executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S02 review run: one request, one Slack message, B approves, HITL_RESOLVED and COMMITTED', T, async (t) => {
  await L.slack.reset();
  const { corr, run, ex } = await invoke('aisha', FLAGSHIP_PATH, { minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL');
  const req = await openRequest(corr);
  assert.equal(req.decision, 'PENDING');
  assert.equal(req.sub_tier, 'CRITICAL');
  assert.equal(req.agent_invoker_id, L.uid('aisha'));
  assert.deepEqual(req.escalated_assets.map((a) => a.asset), ['ADA', 'SOL', 'USDT']);
  assert.deepEqual(await L.types(corr), ['STARTED', ...Array(7).fill('ASSET_RECONCILED'), 'HITL_REQUESTED', 'NOTIFICATION_SENT']);

  const notes = await L.notifications(req.hitl_id);
  assert.equal(notes.length, 1);
  assert.equal(notes[0].outcome, 'SENT');
  const msgs = await L.slack.forHitl(req.hitl_id);
  assert.equal(msgs.length, 1, 'one Slack message');
  const m = msgs[0];
  assert.equal(m.authorization, `Bearer ${L.SLACK_TOKEN}`);
  assert.equal(m.json.channel, channel);
  assert.equal(m.json.mrkdwn, true);
  assert.equal(notes[0].external_ref, `1700000000.${String(m.seq).padStart(6, '0')}`);
  assert.match(m.json.text, new RegExp(`^\\*Approval required: request ${req.hitl_id} for Reserve Reconciliation Agent\\*`));
  assert.match(m.json.text, /\*Eligible approvers:\* Marcus Patel, Sarah Chen\n/);
  assert.doesNotMatch(m.json.text, /Aisha/, 'the invoker is never named');
  assert.ok(m.json.text.includes(`<${req.approval_url}|Open the approval page>`));
  assert.match(m.json.text, /ADA \(REQUIRE_HUMAN\/CRITICAL\), SOL \(REQUIRE_HUMAN\/CRITICAL\), USDT \(REQUIRE_HUMAN\/STANDARD\)/);
  const gw = byWorkflow(ex, GATEWAY_WF);
  assert.equal(gw.length, 1);
  assert.equal(gw[0].status, 'success');
  assert.equal(gw[0].lastNodeExecuted, 'Record Notification');

  const d = await L.decide('sarah', req.hitl_id, 'APPROVED', 'e2e approval by B');
  assert.equal(d.status, 200, JSON.stringify(d.body));
  assert.equal(d.body.committed, true);
  const rows = await L.ledger(corr);
  assert.deepEqual(rows.slice(-2).map((r) => r.t), ['HITL_RESOLVED', 'COMMITTED']);
  assert.equal(rows.at(-1).status, 'SUCCESS');
  const after = await openRequest(corr);
  assert.equal(after.decision, 'APPROVED');
  assert.equal(after.approver_id, L.uid('sarah'));
  assert.equal((await L.run(corr)).state, 'COMMITTED');
  assert.equal((await L.slack.forHitl(req.hitl_id)).length, 1, 'no Slack message for the decision');
  record(t, 'S02', { corr, hitl_id: req.hitl_id, ledger: rows.map((r) => r.t), slack_seq: m.seq, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S03 rejection by C: HITL_RESOLVED and COMMITTED with ROLLED_BACK', T, async (t) => {
  const { corr, run, ex } = await invoke('aisha', FLAGSHIP_PATH, { minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL');
  const req = await openRequest(corr);
  const d = await L.decide('marcus', req.hitl_id, 'REJECTED', 'e2e rejection by C');
  assert.equal(d.status, 200, JSON.stringify(d.body));
  assert.equal(d.body.decision, 'REJECTED');
  const rows = await L.ledger(corr);
  assert.deepEqual(rows.slice(-2).map((r) => r.t), ['HITL_RESOLVED', 'COMMITTED']);
  assert.equal(rows.at(-1).status, 'ROLLED_BACK', 'BUILD-CORE 2.10: REJECTED commits ROLLED_BACK');
  assert.equal(rows.at(-1).hitl_status, 'REJECTED');
  const after = await openRequest(corr);
  assert.equal(after.decision, 'REJECTED');
  assert.equal(after.approver_id, L.uid('marcus'));
  assert.equal(after.decision_notes, 'e2e rejection by C');
  assert.equal((await L.run(corr)).state, 'COMMITTED');
  record(t, 'S03', { corr, hitl_id: req.hitl_id, ledger: rows.map((r) => r.t), executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S04 self-approval by the invoker is refused', T, async (t) => {
  const { corr, ex } = await invoke('aisha', FLAGSHIP_PATH, { minExecutions: 4 });
  const req = await openRequest(corr);
  const typesBefore = await L.types(corr);
  for (const decision of ['APPROVED', 'REJECTED']) {
    const d = await L.decide('aisha', req.hitl_id, decision, 'self decision attempt');
    assert.equal(d.status, 403, JSON.stringify(d.body));
    assert.equal(d.body.code, 'SOD_SELF_APPROVAL');
  }
  assert.equal((await openRequest(corr)).decision, 'PENDING');
  assert.deepEqual(await L.types(corr), typesBefore, 'no ledger row for a refused decision');
  const j = await L.q(
    "SELECT code FROM public.fao_refusal_journal WHERE entry_point = 'rpc:fao_hitl_decide' AND actor_uid = $1 AND target_key = $2",
    [L.uid('aisha'), String(req.hitl_id)],
  );
  assert.equal(j.filter((r) => r.code === 'SOD_SELF_APPROVAL').length, 2, 'both refusals journaled');
  const close = await L.decide('sarah', req.hitl_id, 'REJECTED', 'e2e cleanup after the self-approval check');
  assert.equal(close.status, 200);
  record(t, 'S04', { corr, hitl_id: req.hitl_id, refused: 2, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S05 forged, expired, reused and missing run tokens are refused at the webhook with no rows', T, async (t) => {
  const ev = {};
  const before = L.lastExecutionId();
  const journalStart = Number((await L.one('SELECT coalesce(max(refusal_id), 0) AS m FROM public.fao_refusal_journal')).m);
  const s05Start = (await L.one('SELECT clock_timestamp() AS t')).t;

  // Forged: the right shape, never issued.
  const forged = randomBytes(32).toString('base64url');
  assert.equal(forged.length, 43);
  const f = await L.webhook(FLAGSHIP_PATH, { run_token: forged });
  assert.equal(f.status, 401, f.text);
  assert.deepEqual(f.json, { accepted: false, code: 'INVALID_TOKEN' });
  const fex = (await L.waitExecutions(before, 1)).at(-1);
  assert.equal(fex.status, 'success');
  assert.equal(fex.lastNodeExecuted, 'Respond Claim Refused');
  const jr = await L.q(
    "SELECT code, attempted FROM public.fao_refusal_journal WHERE refusal_id > $1 AND entry_point = 'rpc:fao_run_claim' AND attempted->>'n8n_execution_id' = $2",
    [journalStart, fex.id],
  );
  assert.deepEqual(jr.map((r) => r.code), ['INVALID_TOKEN']);
  assert.ok(!JSON.stringify(jr[0].attempted).includes(forged), 'the token is never journaled');
  // R09: a fresh instance reuses execution ids that earlier runs hold, so only
  // a run claimed during this test would mean the forged token claimed one.
  assert.equal((await L.q('SELECT 1 FROM public.run_invocations WHERE n8n_execution_id = $1 AND claimed_at >= $2', [fex.id, s05Start])).length, 0);
  ev.forged = { status: f.status, execution: fex.id };

  // Missing or malformed: refused by Validate Invoke Body before any database call.
  for (const body of [{}, { run_token: null }, { run_token: 'short' }, { token: forged }, { run_token: `${forged}x` }]) {
    const exBefore = L.lastExecutionId();
    const r = await L.webhook(FLAGSHIP_PATH, body);
    assert.equal(r.status, 400, `${JSON.stringify(body)}: ${r.text}`);
    assert.deepEqual(r.json, { accepted: false, code: 'INVALID_INPUT' });
    const e = (await L.waitExecutions(exBefore, 1)).at(-1);
    assert.equal(e.lastNodeExecuted, 'Respond 400');
    assert.ok(!e.nodes.includes('Claim Run'), 'no database call');
  }
  ev.missing = { refused: 5 };

  // Expired: a real token whose expiry has passed (moved back as the owner).
  const exp = await L.startRun('sarah', { reason: 'e2e expired token' });
  await L.ownerTx((c) => c.query("UPDATE fao_private.run_tokens SET expires_at = now() - interval '1 second' WHERE correlation_id = $1", [exp.corr]));
  const e1 = await L.webhook(FLAGSHIP_PATH, { run_token: exp.token });
  assert.equal(e1.status, 410, e1.text);
  assert.deepEqual(e1.json, { accepted: false, code: 'TOKEN_EXPIRED' });
  assert.equal((await L.run(exp.corr)).state, 'EXPIRED');
  assert.equal((await L.ledger(exp.corr)).length, 0, 'no ledger row for an expired token');
  assert.equal((await L.requests(exp.corr)).length, 0);
  ev.expired = { corr: exp.corr, status: e1.status };

  // Reused: a token that already ran is refused and adds nothing.
  const ok = await invoke('sarah', P.inband, { minExecutions: 3 });
  assert.equal(ok.run.state, 'COMMITTED');
  const rowsBefore = await L.ledger(ok.corr);
  const again = await L.webhook(FLAGSHIP_PATH, { run_token: ok.token });
  assert.equal(again.status, 409, again.text);
  assert.deepEqual(again.json, { accepted: false, code: 'ALREADY_CLAIMED' });
  await L.sleep(1000);
  assert.deepEqual((await L.ledger(ok.corr)).map((r) => r.ledger_id), rowsBefore.map((r) => r.ledger_id), 'no new rows');
  assert.equal((await L.run(ok.corr)).n8n_execution_id, ok.run.n8n_execution_id, 'claim unchanged');
  ev.reused = { corr: ok.corr, status: again.status };
  record(t, 'S05', { ...ev, executions: L.brief(L.executions(before)) });
});

// ---------------------------------------------------------------------------
test('S06 an unauthenticated webhook call is refused and leaves the token unused', T, async (t) => {
  const before = L.lastExecutionId();
  const { corr, token } = await L.startRun('sarah', { reason: 'e2e unauthenticated call' });
  const none = await L.webhook(P.inband, { run_token: token }, { key: null });
  assert.equal(none.status, 403, none.text);
  const wrong = await L.webhook(P.inband, { run_token: token }, { key: randomBytes(32).toString('base64url') });
  assert.equal(wrong.status, 403, wrong.text);
  const otherHeader = await L.webhook(P.inband, { run_token: token }, { header: 'X-FAO-Other-Key' });
  assert.equal(otherHeader.status, 403, otherHeader.text);
  await L.sleep(1000);
  assert.equal(L.executions(before).length, 0, 'no n8n execution for a refused call');
  const r = await L.run(corr);
  assert.equal(r.state, 'REQUESTED');
  assert.equal(r.n8n_execution_id, null);
  assert.equal((await L.ledger(corr)).length, 0);
  // The same token still works with the key: the refused calls consumed nothing.
  const w = await L.webhook(P.inband, { run_token: token });
  assert.equal(w.status, 202, w.text);
  assert.equal((await L.waitSettled(corr)).state, 'COMMITTED');
  const ex = await L.waitExecutions(before, 3);
  record(t, 'S06', { corr, refused: [none.status, wrong.status, otherHeader.status], executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S09 a forced node failure goes through the error handler and the run ends FAILED', T, async (t) => {
  const t0 = await L.dbNow();
  const before = L.lastExecutionId();
  const { corr, token } = await L.startRun('sarah', { reason: 'e2e forced node failure' });
  const w = await L.webhook(P.failnode, { run_token: token });
  assert.equal(w.status, 202, w.text);
  const r = await L.waitSettled(corr);
  assert.equal(r.state, 'FAILED');
  const ex = await L.waitExecutions(before, 2);
  const flag = ex.find((e) => e.id === r.n8n_execution_id);
  assert.equal(flag.status, 'error');
  assert.equal(flag.lastNodeExecuted, 'Init Execution');
  assert.match(flag.error.message, /FAO-REC-001 recon: fixture asset symbol is not a valid symbol/);
  const handler = byWorkflow(ex, ERROR_WF);
  assert.equal(handler.length, 1, 'error workflow ran once');
  assert.equal(handler[0].status, 'success');
  assert.equal(handler[0].lastNodeExecuted, 'Record Run Failure');
  const rows = await L.ledger(corr);
  assert.deepEqual(rows.map((x) => x.t), ['FAILED']);
  assert.equal(rows[0].inputs.source, 'error_workflow');
  assert.equal(rows[0].inputs.stage, 'before_request');
  assert.equal(rows[0].inputs.failed_node, 'Init Execution');
  assert.equal(rows[0].inputs.n8n_execution_id, r.n8n_execution_id);
  assert.match(rows[0].error_details, /fixture asset symbol is not a valid symbol/);
  assert.equal(rows[0].status, 'FAILURE');
  assert.ok(r.finished_at, 'finished_at set');
  assert.equal((await L.requests(corr)).length, 0);
  // K1 (round 5): source 'flagship' on a RUNNING newest holder attaches the
  // FAILED row, and that is the one durable record (no workflow_failures row).
  const failRes = (handler[0].lastNodeOutput || {}).r || {};
  assert.equal(failRes.ok, true, JSON.stringify(failRes));
  assert.equal(failRes.code, 'OK', JSON.stringify(failRes));
  assert.equal(failRes.outcome, 'ATTACHED', JSON.stringify(failRes));
  assert.equal(failRes.state, 'FAILED');
  assert.equal(failRes.correlation_id, corr);
  assert.equal(String(failRes.ledger_id), String(rows[0].ledger_id));
  assert.deepEqual(await L.workflowFailures(r.n8n_execution_id, t0), [], 'no workflow_failures row for an attached failure');
  record(t, 'S09', { corr, state: r.state, last_error: r.last_error, fail_outcome: failRes.outcome, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
// The local-only markup agent (S10, S13): process owner Sarah. Kept until the
// next db:reset.
async function ensureMarkupAgent() {
  await L.ownerTx(async (c) => {
    await c.query("SELECT set_config('fao.change_reason', 'e2e n8n: local-only markup agent for the escaping scenario', true)");
    await c.query(
      `INSERT INTO public.agent_registry (agent_id, display_name, risk_tier, status, workflow_id, approval_threshold, sox_control_ids,
         ai_advisory_enabled, rollback_procedure, data_sources, production_targets, sla_max_execution_seconds,
         sla_max_hitl_resolution_hrs, process_owner_id, max_runs_per_hour)
       SELECT $1, $2, 'RED', 'ACTIVE', NULL, 2, ARRAY['FAO-GOV-004','FAO-GOV-007']::text[], FALSE,
         'Local e2e test agent. Writes nothing outside the Shadow Ledger; an erroneous ledger row is corrected by a CORRECTION event that references the original ledger_id.',
         '{"note": "local e2e agent; no data sources"}'::jsonb, '{"note": "local e2e agent; no production targets"}'::jsonb,
         900, 24, po.id, 60
         FROM public.process_owners po WHERE po.email = 'sarah.chen@finagent-os.demo'
       ON CONFLICT (agent_id) DO NOTHING`,
      [L.MARKUP_AGENT, MARKUP_AGENT_NAME],
    );
  });
}

test('S10 markup and injection-shaped values are stored verbatim and escaped in the Slack text', T, async (t) => {
  await ensureMarkupAgent();
  assert.equal((await L.one('SELECT display_name FROM public.agent_registry WHERE agent_id = $1', [L.MARKUP_AGENT])).display_name, MARKUP_AGENT_NAME);

  await L.slack.reset();
  const { corr, run, ex } = await invoke('aisha', P.markup, { agent: L.MARKUP_AGENT, reason: MARKUP_REASON, minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL');
  assert.equal(run.reason, MARKUP_REASON, 'reason stored verbatim');
  const rows = await L.ledger(corr);
  const started = rows[0];
  assert.equal(started.inputs.reason, MARKUP_REASON);
  assert.equal(started.inputs.fixture_provenance.BTC.notes, MARKUP_NOTE, 'note stored verbatim');
  assert.equal(started.inputs.fixture_provenance.USDT.notes, MARKUP_NOTE_2);
  assert.equal(started.inputs.fixture_provenance.USDT.control, '<b>FAO-REC-002</b>');
  const req = await openRequest(corr);

  const msgs = await L.slack.forHitl(req.hitl_id);
  assert.equal(msgs.length, 1);
  const text = msgs[0].json.text;
  assert.ok(text.includes(`for ${esc(MARKUP_AGENT_NAME)}*`), 'agent name escaped in the header');
  assert.ok(!text.includes(MARKUP_AGENT_NAME), 'raw agent name never posted');
  const link = `<${req.approval_url}|Open the approval page>`;
  assert.equal(text.split(link).length, 2, 'one approval link');
  const rest = text.replace(link, '');
  assert.doesNotMatch(rest, /[<>]/, 'no raw angle bracket outside the one link');
  assert.doesNotMatch(rest, /&(?!amp;|lt;|gt;)/, 'every ampersand is an escape');
  for (const raw of [MARKUP_REASON, MARKUP_NOTE, MARKUP_NOTE_2]) assert.ok(!text.includes(raw), 'free text is not posted');

  const d = await L.decide('sarah', req.hitl_id, 'REJECTED', MARKUP_NOTE);
  assert.equal(d.status, 200, JSON.stringify(d.body));
  assert.equal((await openRequest(corr)).decision_notes, MARKUP_NOTE, 'decision note stored verbatim');
  record(t, 'S10', { corr, hitl_id: req.hitl_id, slack_text: text, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S11 BLOCKED plus critical assets route to review', T, async (t) => {
  await L.slack.reset();
  const { corr, run, ex } = await invoke('sarah', P.blocked, { minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL');
  const rows = assets(await L.ledger(corr));
  const by = Object.fromEntries(rows.map((r) => [r.inputs.asset, r]));
  assert.deepEqual(Object.keys(by), ['ADA', 'BTC', 'DOGE', 'SOL']);
  assert.equal(by.DOGE.outcome, 'BLOCKED');
  assert.equal(by.DOGE.inputs.band_status, 'ONE_SIDED');
  assert.equal(by.DOGE.status, 'FAILURE');
  assert.equal(by.DOGE.hitl_status, 'PENDING');
  assert.equal(by.DOGE.inputs.ratio, null);
  assert.equal(by.SOL.outcome, 'REQUIRE_HUMAN');
  assert.equal(by.SOL.sub_tier, 'CRITICAL');
  assert.equal(by.ADA.outcome, 'REQUIRE_HUMAN');
  assert.equal(by.ADA.sub_tier, 'CRITICAL');
  assert.equal(by.BTC.outcome, 'ALLOW');
  const req = await openRequest(corr);
  assert.deepEqual(req.escalated_assets.map((a) => a.asset).sort(), ['ADA', 'DOGE', 'SOL']);
  assert.equal(req.sub_tier, 'CRITICAL');
  const msgs = await L.slack.forHitl(req.hitl_id);
  assert.equal(msgs.length, 1);
  assert.match(msgs[0].json.text, /DOGE \(BLOCKED\)/);
  assert.match(msgs[0].json.text, /SOL \(REQUIRE_HUMAN\/CRITICAL\)/);
  assert.match(msgs[0].json.text, /\*Eligible approvers:\* Aisha Okonkwo, Marcus Patel\n/);
  const d = await L.decide('marcus', req.hitl_id, 'REJECTED', 'e2e cleanup: blocked run');
  assert.equal(d.status, 200);
  record(t, 'S11', { corr, hitl_id: req.hitl_id, sub_tier: req.sub_tier, escalated: req.escalated_assets, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S12 a NaN or missing balance fails closed', T, async (t) => {
  const { corr, run, ex } = await invoke('sarah', P.badinput, { minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL', 'never committed on bad input');
  const rows = assets(await L.ledger(corr));
  const by = Object.fromEntries(rows.map((r) => [r.inputs.asset, r]));
  assert.deepEqual(Object.keys(by), ['BTC', 'ETH', 'XRP']);
  assert.equal(by.BTC.outcome, 'BLOCKED');
  assert.equal(by.BTC.inputs.band_status, 'INVALID_INPUT');
  assert.match(by.BTC.inputs.input_problem, /^wallet value is nan$/);
  assert.equal(by.BTC.inputs.wallet, null);
  assert.equal(by.BTC.inputs.ratio, null);
  assert.equal(by.ETH.outcome, 'BLOCKED');
  assert.equal(by.ETH.inputs.band_status, 'ONE_SIDED');
  assert.equal(by.ETH.inputs.input_problem, 'ledger balance missing');
  assert.equal(by.XRP.outcome, 'ALLOW');
  const req = await openRequest(corr);
  assert.deepEqual(req.escalated_assets.map((a) => a.asset).sort(), ['BTC', 'ETH']);
  assert.ok(!(await L.types(corr)).includes('COMMITTED'), 'no COMMITTED before a decision');
  const d = await L.decide('aisha', req.hitl_id, 'REJECTED', 'e2e cleanup: bad input run');
  assert.equal(d.status, 200);
  record(t, 'S12', { corr, hitl_id: req.hitl_id, btc_input_problem: by.BTC.inputs.input_problem, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
test('S07 a Slack failure records NOTIFICATION_FAILED and the sweeper renotifies', T, async (t) => {
  await L.slack.reset();
  await L.slack.mode('http_500');
  let req;
  let corr;
  let ex1;
  try {
    const r = await invoke('aisha', FLAGSHIP_PATH, { minExecutions: 4 });
    corr = r.corr;
    ex1 = r.ex;
    assert.equal(r.run.state, 'AWAITING_HITL');
    req = await openRequest(corr);
  } finally {
    await L.slack.mode('ok');
  }
  const first = await L.notifications(req.hitl_id);
  assert.equal(first.length, 1);
  assert.equal(first[0].outcome, 'FAILED');
  assert.equal(first[0].attempt, 1);
  // n8n 2.46 puts no HTTP status on the error-output item; Classify Slack Result
  // recovers it from the cause and adds the Slack error code (e2e finding 2, fixed
  // in fix round 2).
  assert.match(first[0].error, /^http error 500: .*\(e2e_forced_failure\)$/);
  const failedRow = (await L.ledger(corr)).filter((r) => r.t === 'NOTIFICATION_FAILED');
  assert.equal(failedRow.length, 1);
  assert.equal(failedRow[0].status, 'FAILURE');
  assert.equal(byWorkflow(ex1, GATEWAY_WF)[0].status, 'success', 'the notifier records the failure and ends normally');
  assert.equal((await L.slack.forHitl(req.hitl_id)).length, 1, 'the failed attempt reached the fake Slack');

  const before = L.lastExecutionId();
  const s = await L.sweep();
  const ex2 = await L.waitExecutions(before, 1);
  const sweepEx = byWorkflow(ex2, SWEEP_WF);
  assert.equal(sweepEx.length, 1, `sweep webhook answered ${s.status}`);
  const notes = await L.waitNotifications(req.hitl_id, 2);
  assert.equal(notes[1].outcome, 'SENT');
  assert.equal(notes[1].attempt, 2);
  const msgs = await L.slack.forHitl(req.hitl_id);
  assert.equal(msgs.length, 2);
  assert.equal(msgs[1].mode, 'ok');
  assert.match(msgs[1].json.text, /^\*Approval required: request /);
  const types = await L.types(corr);
  assert.deepEqual(types.slice(-3), ['HITL_REQUESTED', 'NOTIFICATION_FAILED', 'NOTIFICATION_SENT']);
  const d = await L.decide('sarah', req.hitl_id, 'REJECTED', 'e2e cleanup: renotify run');
  assert.equal(d.status, 200);
  record(t, 'S07', {
    corr, hitl_id: req.hitl_id, sweep_http: s.status, sweep_execution: L.brief(sweepEx),
    executions: `${L.brief(ex1)} | ${L.brief(ex2)}`,
  });
});

// ---------------------------------------------------------------------------
test('S08 expiry and one escalation through the sweeper with the owner-only test clock', T, async (t) => {
  await L.slack.reset();
  const { corr, run, ex } = await invoke('aisha', FLAGSHIP_PATH, { minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL');
  const req = await openRequest(corr);
  const offset = Math.ceil((new Date(req.timeout_at).getTime() - Date.now()) / 1000) + 120;
  assert.ok(offset > 0 && offset <= 2592000);

  const before = L.lastExecutionId();
  // The clock is shared: clear it as soon as the sweep has committed this
  // request's expiry, while the sweeper goes on to send the notices.
  let sweepResponse;
  await L.withTestClock(offset, async () => {
    sweepResponse = L.sweep();
    await L.waitUntil('request to expire', async () => (await openRequest(corr)).decision === 'EXPIRED', { timeoutMs: 60000, everyMs: 200 });
  });
  const s = await sweepResponse;
  const ex2 = await L.waitExecutions(before, 2);
  assert.equal((await L.q('SELECT count(*)::int AS n FROM fao_private.test_clock')).at(0).n, 0, 'test clock cleared');

  const after = await openRequest(corr);
  assert.equal(after.decision, 'EXPIRED');
  const rows = await L.ledger(corr);
  const tail = rows.map((r) => r.t).slice(rows.findIndex((r) => r.t === 'HITL_EXPIRED'));
  assert.deepEqual(tail, ['HITL_EXPIRED', 'HITL_ESCALATED', 'NOTIFICATION_SENT']);
  const esc1 = rows.find((r) => r.t === 'HITL_ESCALATED');
  assert.equal(esc1.inputs.level, 1);
  assert.equal(esc1.inputs.reason, 'TIMEOUT');
  assert.equal(esc1.inputs.target_owner_id, L.uid('marcus'));
  // Patch round 6 (P3): HITL_EXPIRED is the closing record; no COMMITTED row.
  const closing = rows.find((r) => r.t === 'HITL_EXPIRED');
  assert.equal(closing.status, 'FAILURE');
  assert.equal(closing.inputs.committed, false);
  assert.equal(closing.inputs.run_state, 'EXPIRED');
  assert.ok(!rows.some((r) => r.t === 'COMMITTED'), 'no COMMITTED row for an expired request');
  assert.equal((await L.run(corr)).state, 'EXPIRED');
  await L.waitNotifications(req.hitl_id, 2);
  const all = await L.slack.forHitl(req.hitl_id);
  assert.equal(all.length, 2, 'the REQUESTED notice and one escalation notice');
  const msgs = all.filter((m) => m.json.text.startsWith('*Escalation:'));
  assert.equal(msgs.length, 1, 'one escalation notice');
  assert.match(msgs[0].json.text, new RegExp(`^\\*Escalation: approval request ${req.hitl_id} for Reserve Reconciliation Agent needs attention\\*`));
  assert.match(msgs[0].json.text, /\*Escalation target:\* Marcus Patel\n/);
  const notes = await L.notifications(req.hitl_id);
  assert.deepEqual(notes.map((n) => `${n.kind}/${n.level}/${n.outcome}`), ['REQUESTED/0/SENT', 'ESCALATED/1/SENT']);

  // A second sweep escalates nothing more for this request.
  const before2 = L.lastExecutionId();
  await L.sweep();
  await L.waitExecutions(before2, 1);
  const rows2 = await L.ledger(corr);
  assert.equal(rows2.filter((r) => r.t === 'HITL_ESCALATED').length, 1, 'escalated once');
  assert.equal(rows2.length, rows.length, 'nothing more written');
  assert.equal((await L.slack.forHitl(req.hitl_id)).length, 2, 'no further notice');
  record(t, 'S08', {
    corr, hitl_id: req.hitl_id, offset_seconds: offset, sweep_http: s.status, ledger: rows.map((r) => r.t),
    executions: `${L.brief(ex)} | ${L.brief(byWorkflow(ex2, SWEEP_WF))}`,
  });
});

// ---------------------------------------------------------------------------
// S13 (fix round 3): a failed notifier call and a sweep item error in the
// same sweep both surface in one failed sweeper execution. The sweeper copy
// SWEEP_NFAIL_ID calls a notifier stand-in that always throws (variants.mjs).
// The item error is NO_ESCALATION_TARGET: B (Sarah) invokes the markup agent
// she owns while her escalation_to is NULL for the sweep, so the TIMEOUT
// escalation has no target (never the invoker) and is still listed for the
// channel notice. Her seeded escalation_to (Marcus) is put back in a finally;
// the helper refuses to start unless it finds that seeded value.
async function withNoEscalationTarget(user, fn) {
  const email = (await L.one('SELECT email FROM public.process_owners WHERE id = $1', [L.uid(user)])).email;
  const seeded = L.uid('marcus');
  await L.ownerTx(async (c) => {
    await c.query("SELECT set_config('fao.change_reason', 'e2e n8n S13: no escalation target for one sweep', true)");
    const u = await c.query('UPDATE public.process_owners SET escalation_to = NULL WHERE email = $1 AND escalation_to = $2', [email, seeded]);
    if (u.rowCount !== 1) throw new Error(`e2e S13: ${email} escalation_to is not the seeded value; not changing it`);
  });
  try {
    return await fn();
  } finally {
    await L.ownerTx(async (c) => {
      await c.query("SELECT set_config('fao.change_reason', 'e2e n8n S13: restore the seeded escalation_to', true)");
      await c.query('UPDATE public.process_owners SET escalation_to = $2 WHERE email = $1 AND escalation_to IS NULL', [email, seeded]);
    });
  }
}

test('S13 a notifier failure and a sweep item error in the same sweep both fail one sweeper execution', T, async (t) => {
  // The setup step waits only for the standing webhook paths; wait for this one.
  await L.waitUntil(`webhook ${SWEEP_NFAIL_PATH}`, async () => (await L.webhook(SWEEP_NFAIL_PATH, {}, { key: null })).status === 403,
    { timeoutMs: 60000, everyMs: 500 });
  await ensureMarkupAgent();
  await L.slack.reset();
  const { corr, run, ex } = await invoke('sarah', P.markup, { agent: L.MARKUP_AGENT, reason: 'e2e S13 notifier failure plus item error', minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL');
  const req = await openRequest(corr);
  assert.equal(req.agent_invoker_id, L.uid('sarah'));
  const offset = Math.ceil((new Date(req.timeout_at).getTime() - Date.now()) / 1000) + 120;
  assert.ok(offset > 0 && offset <= 2592000);

  const t0 = await L.dbNow();
  const before = L.lastExecutionId();
  let sweepResponse;
  await withNoEscalationTarget('sarah', () => L.withTestClock(offset, async () => {
    sweepResponse = L.webhook(SWEEP_NFAIL_PATH, {});
    await L.waitUntil('request to expire', async () => (await openRequest(corr)).decision === 'EXPIRED', { timeoutMs: 60000, everyMs: 200 });
  }));
  const s = await sweepResponse;
  const ex2 = await L.waitExecutions(before, 2);
  assert.equal((await L.q('SELECT count(*)::int AS n FROM fao_private.test_clock')).at(0).n, 0, 'test clock cleared');
  assert.equal((await L.one('SELECT escalation_to FROM public.process_owners WHERE id = $1', [L.uid('sarah')])).escalation_to, L.uid('marcus'), 'escalation_to restored');

  // The database side: expired (closing record, no COMMITTED), escalated with no target.
  const rows = await L.ledger(corr);
  const tail = rows.map((r) => r.t).slice(rows.findIndex((r) => r.t === 'HITL_EXPIRED'));
  assert.deepEqual(tail, ['HITL_EXPIRED', 'HITL_ESCALATED']);
  const esc1 = rows.find((r) => r.t === 'HITL_ESCALATED');
  assert.equal(esc1.inputs.reason, 'TIMEOUT');
  assert.equal(esc1.inputs.target_owner_id, null, 'never the invoker');
  assert.equal(rows.find((r) => r.t === 'HITL_EXPIRED').status, 'FAILURE');
  assert.equal(rows.find((r) => r.t === 'HITL_EXPIRED').inputs.committed, false);
  assert.equal((await L.run(corr)).state, 'EXPIRED');

  // The n8n side: the stand-in was called and failed, and the sweeper
  // execution failed once, at Check Sweep Errors, naming both failures.
  const stand = byWorkflow(ex2, FAILING_NOTIFIER_ID);
  assert.ok(stand.length >= 1 && stand.every((e) => e.status === 'error'), `stand-in executions ${L.brief(stand)}`);
  const sweepEx = byWorkflow(ex2, SWEEP_NFAIL_ID);
  assert.equal(sweepEx.length, 1, `sweep webhook answered ${s.status}`);
  assert.equal(sweepEx[0].status, 'error');
  assert.ok(sweepEx[0].error, L.brief(sweepEx));
  // n8n 2.46.6 stores no node name on a Code node's top-level error (as S09
  // shows), so the failing node is read from lastNodeExecuted and the per-node
  // errors: exactly one, at Check Sweep Errors, after Check Notifier Results ran.
  assert.equal(sweepEx[0].lastNodeExecuted, 'Check Sweep Errors', L.brief(sweepEx));
  assert.deepEqual((sweepEx[0].nodeErrors || []).map((e) => e.node), ['Check Sweep Errors'], L.brief(sweepEx));
  const nodesRun = sweepEx[0].nodes || [];
  assert.ok(nodesRun.indexOf('Check Notifier Results') >= 0
    && nodesRun.indexOf('Check Notifier Results') < nodesRun.indexOf('Check Sweep Errors'), nodesRun.join(', '));
  const msg = sweepEx[0].error.message;
  assert.equal(sweepEx[0].nodeErrors[0].message, msg);
  const i007 = msg.indexOf('FAO-GOV-007 sweep: ');
  const i008 = msg.indexOf('FAO-GOV-008 sweep: ');
  assert.ok(i007 >= 0 && i008 > i007, msg);
  assert.ok(msg.slice(i007, i008).includes(`${req.hitl_id}:ESCALATED:1 (`), msg);
  assert.ok(msg.slice(i007, i008).includes(FAILING_NOTIFIER_MESSAGE), msg);
  assert.ok(msg.slice(i008).includes(`expire_request:${req.hitl_id}:NO_ESCALATION_TARGET`), msg);

  // The failed call recorded nothing: only the REQUESTED notice from the run.
  const notes = await L.notifications(req.hitl_id);
  assert.deepEqual(notes.map((n) => `${n.kind}/${n.level}/${n.outcome}`), ['REQUESTED/0/SENT']);
  assert.equal((await L.slack.forHitl(req.hitl_id)).length, 1, 'no escalation notice reached Slack');

  // Round 5 (F-20, K1): the sweeper copy runs with the sweeper's
  // settings.errorWorkflow, so the failed sweep reaches the error handler
  // once, mapped to 'sweeper', and fao_run_fail writes exactly one
  // workflow_failures row (NOT_FLAGSHIP) and no ledger row. The failing
  // notifier stand-in has no error workflow, so it adds no handler run.
  const handler = await L.waitUntil('the error handler for the failed sweep', async () => {
    const h = byWorkflow(L.executions(before), ERROR_WF);
    return h.length >= 1 && h.every((e) => e.stoppedAt) ? h : null;
  }, { timeoutMs: 60000, everyMs: 750 });
  assert.equal(handler.length, 1, `error workflow ran once: ${L.brief(handler)}`);
  assert.equal(handler[0].status, 'success', L.brief(handler));
  assert.equal(handler[0].lastNodeExecuted, 'Record Run Failure');
  const failRes = (handler[0].lastNodeOutput || {}).r || {};
  assert.deepEqual(
    [failRes.ok, failRes.code, failRes.outcome, failRes.correlation_id, failRes.ledger_id, failRes.state],
    [true, 'OK', 'NOT_FLAGSHIP', null, null, null], JSON.stringify(failRes),
  );
  const wfRows = await L.workflowFailures(sweepEx[0].id, t0);
  assert.equal(wfRows.length, 1, JSON.stringify(wfRows));
  assert.equal(wfRows[0].source, 'sweeper');
  assert.equal(wfRows[0].outcome, 'NOT_FLAGSHIP');
  assert.equal(wfRows[0].failed_node, 'Check Sweep Errors');
  assert.equal(wfRows[0].message, L.cleanText(msg, 500));
  assert.equal(wfRows[0].correlation_id, null);
  record(t, 'S13', {
    corr, hitl_id: req.hitl_id, offset_seconds: offset, sweep_http: s.status, sweep_error: msg,
    workflow_failure: { id: wfRows[0].id, source: wfRows[0].source, outcome: wfRows[0].outcome },
    executions: `${L.brief(ex)} | ${L.brief(ex2)} | ${L.brief(handler)}`,
  });
});

// ---------------------------------------------------------------------------
// S14 (patch P1, KNOWN-LIMITS U16 (a)): the agent is deprecated after the
// claim and the asset writes, before Finalize Run. fao_run_finalize then
// writes COMMIT_BLOCKED, moves the run to FAILED and returns the
// AGENT_NOT_ACTIVE envelope (IC-24); Check Finalize Result must fail the
// execution so the error workflow runs, and the error workflow's
// fao_run_fail must answer ALREADY_TERMINAL, write no ledger row and record
// exactly one workflow_failures row (round 5, K1). The deprecate
// variant (variants.mjs) runs under the local-only agent DEPRECATE_AGENT and
// waits PAUSE_BEFORE_FINALIZE_MS in E2E Pause Before Finalize. The agent is
// deprecated and re-activated through fao_admin_set_agent as Marcus (admin),
// as an operator would; it is left ACTIVE.
async function ensureDeprecateAgent() {
  await L.ownerTx(async (c) => {
    await c.query("SELECT set_config('fao.change_reason', 'e2e n8n: local-only agent for the deprecate-before-finalize scenario', true)");
    await c.query(
      `INSERT INTO public.agent_registry (agent_id, display_name, risk_tier, status, workflow_id, approval_threshold, sox_control_ids,
         ai_advisory_enabled, rollback_procedure, data_sources, production_targets, sla_max_execution_seconds,
         sla_max_hitl_resolution_hrs, process_owner_id, max_runs_per_hour)
       SELECT $1, 'E2E deprecate-before-finalize agent', 'RED', 'ACTIVE', NULL, 2, ARRAY['FAO-GOV-002','FAO-GOV-008']::text[], FALSE,
         'Local e2e test agent. Writes nothing outside the Shadow Ledger; an erroneous ledger row is corrected by a CORRECTION event that references the original ledger_id.',
         '{"note": "local e2e agent; no data sources"}'::jsonb, '{"note": "local e2e agent; no production targets"}'::jsonb,
         900, 24, po.id, 60
         FROM public.process_owners po WHERE po.email = 'sarah.chen@finagent-os.demo'
       ON CONFLICT (agent_id) DO NOTHING`,
      [DEPRECATE_AGENT],
    );
  });
}

const agentStatus = async () => (await L.one('SELECT status::text AS s FROM public.agent_registry WHERE agent_id = $1', [DEPRECATE_AGENT])).s;
async function setAgentStatus(token, status, why) {
  const r = await L.rpc('fao_admin_set_agent', {
    p_agent_id: DEPRECATE_AGENT, p_status: status, p_ai_advisory_enabled: null, p_max_runs_per_hour: null, p_reason: `e2e n8n S14: ${why}`,
  }, { token });
  assert.equal(r.status, 200, `fao_admin_set_agent ${status}: ${r.status} ${JSON.stringify(r.body)}`);
  assert.equal(r.body.ok, true, JSON.stringify(r.body));
  assert.equal(await agentStatus(), status);
}

test('S14 the agent deprecated between claim and finalize fails the execution at Check Finalize Result; the error handler records ALREADY_TERMINAL only', T, async (t) => {
  await ensureDeprecateAgent();
  const marcus = await L.signIn('marcus');
  if (await agentStatus() !== 'ACTIVE') await setAgentStatus(marcus, 'ACTIVE', 'activate before the run');
  await L.slack.reset();

  const t0 = await L.dbNow();
  const before = L.lastExecutionId();
  const { corr, token } = await L.startRun('sarah', { agent: DEPRECATE_AGENT, reason: 'e2e S14 agent deprecated before finalize' });
  let r;
  let ex;
  try {
    const w = await L.webhook(P.deprecate, { run_token: token });
    assert.equal(w.status, 202, `webhook answered ${w.status} ${w.text}`);
    assert.deepEqual(w.json, { accepted: true, correlation_id: corr });

    // Claimed and every asset row written: the execution is now inside the pause.
    const started = Date.now();
    await L.waitUntil('7 ASSET_RECONCILED rows', async () => assets(await L.ledger(corr)).length === 7,
      { timeoutMs: PAUSE_BEFORE_FINALIZE_MS, everyMs: 200 });
    await setAgentStatus(marcus, 'DEPRECATED', 'deprecate between claim and finalize');
    const mid = await L.run(corr);
    assert.equal(mid.state, 'RUNNING', 'the agent was deprecated before Finalize Run ran (pause long enough)');
    assert.ok(!(await L.types(corr)).some((x) => x.startsWith('COMMIT')), 'no COMMIT row before the deprecation');
    t.diagnostic(`S14 deprecated ${Date.now() - started} ms after the 202 (pause ${PAUSE_BEFORE_FINALIZE_MS} ms)`);

    r = await L.waitSettled(corr, { timeoutMs: PAUSE_BEFORE_FINALIZE_MS + 60000 });
    // The flagship execution, both Writer calls and the error handler, all stopped.
    ex = await L.waitUntil('flagship, two Writer calls and the error handler to stop', async () => {
      const all = L.executions(before);
      return all.length >= 4 && all.every((e) => e.stoppedAt) && byWorkflow(all, ERROR_WF).length >= 1 ? all : null;
    }, { timeoutMs: 60000, everyMs: 750 });
  } finally {
    if (await agentStatus() !== 'ACTIVE') await setAgentStatus(marcus, 'ACTIVE', 'restore after the run');
  }

  // The database side: run FAILED, exactly one COMMIT_BLOCKED, no FAILED row.
  assert.equal(r.state, 'FAILED');
  assert.equal(r.last_error, 'agent not ACTIVE at commit');
  assert.ok(r.finished_at, 'finished_at set');
  const rows = await L.ledger(corr);
  assert.deepEqual(rows.map((x) => x.t), ['STARTED', ...Array(7).fill('ASSET_RECONCILED'), 'COMMIT_BLOCKED']);
  const blocked = rows.at(-1);
  assert.equal(blocked.inputs.code, 'AGENT_NOT_ACTIVE');
  assert.equal(blocked.inputs.agent_status, 'DEPRECATED');
  assert.equal(blocked.inputs.hitl_id, null);
  assert.equal(blocked.outcome, 'BLOCKED');
  assert.equal(blocked.status, 'FAILURE');
  assert.equal(blocked.hitl_status, 'NOT_REQUIRED');
  assert.match(blocked.policy_rationale, /^FAO-GOV-002 agent fao_e2e_deprecate_v1 status DEPRECATED at commit; run not committed/);
  assert.equal((await L.requests(corr)).length, 0, 'no request');
  // No FAILED row anywhere for this execution id after the run's first row.
  // Since round 5 (K1) fao_run_fail looks only at the newest run holding the
  // id; it is terminal, so nothing falls back to an older run (U14 (a)).
  const stray = await L.q(
    `SELECT ledger_id, correlation_id FROM public.shadow_ledger
      WHERE inputs->>'event_type' = 'FAILED' AND inputs->>'n8n_execution_id' = $1 AND ledger_id > $2`,
    [String(r.n8n_execution_id), rows[0].ledger_id],
  );
  assert.deepEqual(stray, [], 'the error handler wrote no FAILED row');

  // The n8n side: the flagship failed at Check Finalize Result, after Finalize
  // Run and never on to Human Review Required?, Run Complete or the notifier.
  const flag = ex.find((e) => e.id === String(r.n8n_execution_id));
  assert.ok(flag, `flagship execution ${r.n8n_execution_id} in ${L.brief(ex)}`);
  assert.equal(flag.workflowId, 'FaoE2eReconDepr1');
  assert.equal(flag.status, 'error', L.brief([flag]));
  assert.equal(flag.lastNodeExecuted, 'Check Finalize Result', L.brief([flag]));
  assert.deepEqual((flag.nodeErrors || []).map((e) => e.node), ['Check Finalize Result'], L.brief([flag]));
  const expected = `FAO-GOV-008 recon: fao_run_finalize refused with AGENT_NOT_ACTIVE for run ${corr}; the run was not committed`;
  // The fixed text, plus at most the " [line N]" suffix n8n may add to a Code node error.
  const reEsc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  assert.match(flag.error.message, new RegExp(`^${reEsc(expected)}( \\[line \\d+\\])?$`), flag.error.message);
  assert.equal(flag.nodeErrors[0].message, flag.error.message);
  const nodesRun = flag.nodes || [];
  for (const n of ['Claim Run', PAUSE_NODE, 'Finalize Run', 'Check Finalize Result']) assert.ok(nodesRun.includes(n), `${n} ran: ${nodesRun.join(', ')}`);
  for (const n of ['Human Review Required?', 'Run Complete', 'Notify Input', 'HITL Gateway']) assert.ok(!nodesRun.includes(n), `${n} did not run: ${nodesRun.join(', ')}`);
  const writers = byWorkflow(ex, WRITER_WF);
  assert.equal(writers.length, 2, L.brief(ex));
  assert.ok(writers.every((e) => e.status === 'success'), L.brief(writers));
  assert.equal(byWorkflow(ex, GATEWAY_WF).length, 0, 'the notifier was never called');

  // The error handler ran once; fao_run_fail (source 'flagship', K1) found
  // the newest holder of the id terminal: ALREADY_TERMINAL, no ledger row,
  // and exactly one workflow_failures row naming that run.
  const handler = byWorkflow(ex, ERROR_WF);
  assert.equal(handler.length, 1, `error workflow ran once: ${L.brief(ex)}`);
  assert.equal(handler[0].status, 'success', L.brief(handler));
  assert.equal(handler[0].lastNodeExecuted, 'Record Run Failure');
  const failRes = (handler[0].lastNodeOutput || {}).r || {};
  assert.equal(failRes.ok, true, JSON.stringify(handler[0].lastNodeOutput));
  assert.equal(failRes.code, 'ALREADY_TERMINAL', JSON.stringify(failRes));
  assert.equal(failRes.outcome, 'ALREADY_TERMINAL', JSON.stringify(failRes));
  assert.equal(failRes.ledger_id, null);
  assert.equal(failRes.correlation_id, corr);
  assert.equal(failRes.state, 'FAILED');
  assert.deepEqual((await L.ledger(corr)).map((x) => x.ledger_id), rows.map((x) => x.ledger_id), 'nothing appended after the handler');
  const wfRows = await L.workflowFailures(r.n8n_execution_id, t0);
  assert.equal(wfRows.length, 1, JSON.stringify(wfRows));
  assert.deepEqual(
    [wfRows[0].source, wfRows[0].outcome, wfRows[0].correlation_id, wfRows[0].failed_node],
    ['flagship', 'ALREADY_TERMINAL', corr, 'Check Finalize Result'],
  );
  assert.equal(wfRows[0].message, L.cleanText(flag.error.message, 500));
  assert.equal((await L.slack.requests()).length, 0, 'no Slack message');
  assert.equal(await agentStatus(), 'ACTIVE', 'agent restored');
  record(t, 'S14', {
    corr, state: r.state, last_error: r.last_error, flagship_error: flag.error.message,
    fail_result: failRes.code, workflow_failure: wfRows[0].id, executions: L.brief(ex),
  });
});

// ===========================================================================
// Round 5 scenarios (K1, F-20, F-32, B-19 / F-38)
// ===========================================================================
const maxLedgerId = async () => (await L.one('SELECT coalesce(max(ledger_id), 0)::text AS m FROM public.shadow_ledger')).m;
const strayFailed = (executionId, afterLedgerId) => L.q(
  `SELECT ledger_id, correlation_id FROM public.shadow_ledger
    WHERE inputs->>'event_type' = 'FAILED' AND inputs->>'n8n_execution_id' = $1 AND ledger_id > $2::bigint`,
  [String(executionId), afterLedgerId],
);
const failResult = (exec) => ((exec && exec.lastNodeOutput) || {}).r || {};

// Waits until executions after `before` include at least `min[workflowId]`
// of each listed workflow and every execution has stopped.
const waitFor = (label, before, min) => L.waitUntil(label, async () => {
  const all = L.executions(before);
  const enough = Object.entries(min).every(([wf, n]) => byWorkflow(all, wf).length >= n);
  return enough && all.every((e) => e.stoppedAt) ? all : null;
}, { timeoutMs: 90000, everyMs: 750 });

// ---------------------------------------------------------------------------
// S15 (F-20, K1): the notifier export fails as a sub-workflow (bad input from
// the e2e caller); its settings.errorWorkflow runs the error handler, which
// maps it to 'gateway', and fao_run_fail records one workflow_failures row
// (NOT_FLAGSHIP) and no ledger row.
test('S15 a notifier failure reaches the error handler as gateway and writes one workflow_failures row', T, async (t) => {
  await L.waitUntil(`webhook ${GATEWAY_CALLER_PATH}`, async () => (await L.webhook(GATEWAY_CALLER_PATH, {}, { key: null })).status === 403,
    { timeoutMs: 60000, everyMs: 500 });
  const t0 = await L.dbNow();
  const ledgerBefore = await maxLedgerId();
  const before = L.lastExecutionId();
  const w = await L.webhook(GATEWAY_CALLER_PATH, {});
  const ex = await waitFor('caller, notifier and error handler', before, { [GATEWAY_CALLER_ID]: 1, [GATEWAY_WF]: 1, [ERROR_WF]: 1 });

  const gw = byWorkflow(ex, GATEWAY_WF);
  assert.equal(gw.length, 1, L.brief(ex));
  assert.equal(gw[0].status, 'error', L.brief(gw));
  assert.equal(gw[0].lastNodeExecuted, 'Validate Payload', L.brief(gw));
  assert.match(gw[0].error.message, /^FAO-GOV-007 notifier: hitl_id invalid/);
  const caller = byWorkflow(ex, GATEWAY_CALLER_ID);
  assert.equal(caller.length, 1, L.brief(ex));
  assert.equal(caller[0].status, 'error', 'the caller fails with its sub-workflow');
  const handler = byWorkflow(ex, ERROR_WF);
  assert.equal(handler.length, 1, `the error workflow ran once (only the notifier has errorWorkflow): ${L.brief(ex)}`);
  assert.equal(handler[0].status, 'success', L.brief(handler));
  assert.equal(handler[0].lastNodeExecuted, 'Record Run Failure');
  const r = failResult(handler[0]);
  assert.deepEqual([r.ok, r.code, r.outcome, r.correlation_id, r.ledger_id, r.state], [true, 'OK', 'NOT_FLAGSHIP', null, null, null], JSON.stringify(r));

  const rows = await L.workflowFailures(gw[0].id, t0);
  assert.equal(rows.length, 1, JSON.stringify(rows));
  assert.deepEqual([rows[0].source, rows[0].outcome, rows[0].failed_node, rows[0].correlation_id], ['gateway', 'NOT_FLAGSHIP', 'Validate Payload', null]);
  assert.equal(rows[0].message, L.cleanText(gw[0].error.message, 500));
  assert.deepEqual(await strayFailed(gw[0].id, ledgerBefore), [], 'no FAILED ledger row');
  record(t, 'S15', { webhook_http: w.status, workflow_failure: rows[0].id, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
// S16 (K1, U14 (a)): an older run, claimed with the id the next n8n
// execution will get (what a fresh instance that reuses ids produces, R09)
// and taken to AWAITING_HITL, is never touched when that next execution, a
// flagship copy, fails before Claim Run. The handler sends
// 'flagship_pre_claim' (last node upstream of Claim Run); fao_run_fail looks
// up no run and records PRE_CLAIM. The older run is set up as the invoker
// (fao_run_start) and fao_workflow (claim, append, finalize), as n8n would.
test('S16 a flagship failure before Claim Run records PRE_CLAIM and leaves an older AWAITING_HITL run on the same id untouched', T, async (t) => {
  const t0 = await L.dbNow();
  const ledgerBefore = await maxLedgerId();
  const next = String(L.nextExecutionId());

  const old = await L.startRun('aisha', { reason: 'e2e S16 older run holding the next execution id' });
  const c = await L.claim(old.token, next);
  assert.equal(c.ok, true, `claim with execution id ${next}: ${JSON.stringify(c)}`);
  await L.append([L.startedEvent(old.corr, ['USDT'])]);
  await L.append([L.assetEvent(old.corr, 'USDT', 'REQUIRE_HUMAN', 'STANDARD')]);
  const f = await L.finalize(old.corr);
  assert.equal(f.hitl_required, true, JSON.stringify(f));
  const oldRun = await L.run(old.corr);
  assert.equal(oldRun.state, 'AWAITING_HITL');
  assert.equal(oldRun.n8n_execution_id, next);
  const oldRows = await L.ledger(old.corr);
  const req = await openRequest(old.corr);
  assert.equal(req.decision, 'PENDING');

  assert.equal(String(L.nextExecutionId()), next, 'no n8n execution started while the older run was set up');
  const before = Number(next) - 1;
  const w = await L.webhook(P.preclaim, {});
  assert.notEqual(w.status, 202, w.text);
  const ex = await waitFor('pre-claim flagship copy and error handler', before, { [VARIANTS.preclaim.id]: 1, [ERROR_WF]: 1 });

  const flag = byWorkflow(ex, VARIANTS.preclaim.id);
  assert.equal(flag.length, 1, L.brief(ex));
  assert.equal(flag[0].id, next, `the failing execution has the older run's id: ${L.brief(ex)}`);
  assert.equal(flag[0].status, 'error');
  assert.equal(flag[0].lastNodeExecuted, 'Validate Invoke Body');
  assert.ok(flag[0].error.message.startsWith(PRECLAIM_MESSAGE), flag[0].error.message);
  assert.ok(!(flag[0].nodes || []).includes('Claim Run'), 'Claim Run never ran');
  const handler = byWorkflow(ex, ERROR_WF);
  assert.equal(handler.length, 1, L.brief(ex));
  assert.equal(handler[0].status, 'success', L.brief(handler));
  const r = failResult(handler[0]);
  assert.deepEqual([r.ok, r.code, r.outcome, r.correlation_id, r.ledger_id, r.state], [true, 'OK', 'PRE_CLAIM', null, null, null], JSON.stringify(r));

  const rows = await L.workflowFailures(next, t0);
  assert.equal(rows.length, 1, JSON.stringify(rows));
  assert.deepEqual([rows[0].source, rows[0].outcome, rows[0].failed_node, rows[0].correlation_id],
    ['flagship_pre_claim', 'PRE_CLAIM', 'Validate Invoke Body', null]);
  assert.equal(rows[0].message, L.cleanText(flag[0].error.message, 500));

  // The older run: same rows, same state, request still pending.
  assert.deepEqual((await L.ledger(old.corr)).map((x) => x.ledger_id), oldRows.map((x) => x.ledger_id), 'no row on the older run');
  const after = await L.run(old.corr);
  assert.equal(after.state, 'AWAITING_HITL');
  assert.equal(after.last_error, oldRun.last_error);
  assert.equal((await openRequest(old.corr)).decision, 'PENDING');
  assert.deepEqual(await strayFailed(next, ledgerBefore), [], 'no FAILED ledger row for that execution id');

  const d = await L.decide('sarah', req.hitl_id, 'REJECTED', 'e2e cleanup: S16 older run');
  assert.equal(d.status, 200, JSON.stringify(d.body));
  record(t, 'S16', { corr: old.corr, execution_id: next, webhook_http: w.status, workflow_failure: rows[0].id, executions: L.brief(ex) });
});

// ---------------------------------------------------------------------------
// F-32: the two harness exports, imported unchanged, run with `n8n execute`
// (lib.mjs runHarness) against the local stack.
const H_TIMEOUT = { timeout: 240000 };
function assertHarnessTargetsLocal() {
  assertLocalTargets([['harness Supabase url', L.HARNESS_TARGETS.supabase], ['harness invoke url', L.HARNESS_TARGETS.invoke]]);
}
const harnessRun = (corrKey, executionId, t0) => L.q(
  `SELECT * FROM public.run_invocations
    WHERE invoker_id = $1 AND idempotency_key LIKE $2 AND requested_at >= $3 ORDER BY requested_at`,
  [L.uid('aisha'), `${corrKey}-${executionId}-%`, t0],
);

test('S17 the Writer harness export runs with n8n execute: 8 events stored, the bad batch refused, the run closed FAILED', H_TIMEOUT, async (t) => {
  assertHarnessTargetsLocal();
  const t0 = await L.dbNow();
  const before = L.lastExecutionId();
  const res = L.runHarness(HARNESSES.writer.id, L.harnessEnv('aisha'));
  assert.equal(res.timedOut, false, 'n8n execute timed out');
  assert.equal(res.status, 0, 'n8n execute exit code');
  const ex = await waitFor('the Writer harness and its two Writer calls', before, { [HARNESSES.writer.id]: 1, [WRITER_WF]: 2 });

  const h = byWorkflow(ex, HARNESSES.writer.id);
  assert.equal(h.length, 1, L.brief(ex));
  assert.equal(h[0].mode, 'cli');
  assert.equal(h[0].status, 'success', L.brief(h));
  assert.equal(h[0].lastNodeExecuted, 'Close Run');
  for (const n of ['Assert Test Environment', 'Sign In', 'Start Run', 'Claim', 'Writer: Valid Batch', 'Writer: Bad Batch', 'Assert Results', 'Close Run']) {
    assert.ok((h[0].nodes || []).includes(n), `${n} ran: ${(h[0].nodes || []).join(', ')}`);
  }
  assert.deepEqual(byWorkflow(ex, WRITER_WF).map((e) => e.status).sort(), ['error', 'success'], 'valid batch stored, bad batch failed');
  const r = failResult(h[0]);
  assert.deepEqual([r.ok, r.code, r.outcome, r.state], [true, 'OK', 'ATTACHED', 'FAILED'], JSON.stringify(r));

  const runs = await harnessRun('harness-writer', h[0].id, t0);
  assert.equal(runs.length, 1, 'one harness run');
  const run = runs[0];
  assert.equal(run.correlation_id, r.correlation_id);
  assert.equal(run.state, 'FAILED');
  assert.equal(run.invoked_via, 'test');
  assert.equal(run.n8n_execution_id, h[0].id);
  const rows = await L.ledger(run.correlation_id);
  assert.deepEqual(rows.map((x) => x.t), ['STARTED', ...Array(7).fill('ASSET_RECONCILED'), 'FAILED']);
  assert.deepEqual(assets(rows).map((x) => x.inputs.asset), ['ADA', 'BTC', 'ETH', 'SOL', 'USDC', 'USDT', 'XRP']);
  const failed = rows.at(-1);
  assert.equal(String(failed.ledger_id), String(r.ledger_id));
  assert.equal(failed.inputs.failed_node, 'writer_harness');
  assert.equal(failed.inputs.source, 'error_workflow');
  assert.ok(!rows.some((x) => ['A0', 'A1', 'A2'].includes(x.inputs.asset)), 'nothing from the bad batch');
  assert.deepEqual(await L.workflowFailures(h[0].id, t0), []);
  record(t, 'S17', { corr: run.correlation_id, ledger: rows.map((x) => x.t), executions: L.brief(ex) });
});

test('S18 the notifier harness export runs with n8n execute: the token is accepted and the flagship opens one request with one Slack notice', H_TIMEOUT, async (t) => {
  assertHarnessTargetsLocal();
  await L.slack.reset();
  const t0 = await L.dbNow();
  const before = L.lastExecutionId();
  const res = L.runHarness(HARNESSES.gateway.id, L.harnessEnv('aisha'));
  assert.equal(res.timedOut, false, 'n8n execute timed out');
  assert.equal(res.status, 0, 'n8n execute exit code');
  const hs = await waitFor('the notifier harness', before, { [HARNESSES.gateway.id]: 1 });
  const h = byWorkflow(hs, HARNESSES.gateway.id);
  assert.equal(h.length, 1, L.brief(hs));
  assert.equal(h[0].mode, 'cli');
  assert.equal(h[0].status, 'success', L.brief(h));
  assert.equal(h[0].lastNodeExecuted, 'Assert Accepted');
  const out = h[0].lastNodeOutput || {};
  assert.equal(out.accepted, true, JSON.stringify(out));
  const runs = await harnessRun('harness-notifier', h[0].id, t0);
  assert.equal(runs.length, 1, 'one harness run');
  const corr = runs[0].correlation_id;
  assert.equal(out.correlation_id, corr);

  const r = await L.waitSettled(corr);
  assert.equal(r.state, 'AWAITING_HITL');
  const req = await openRequest(corr);
  assert.equal(req.agent_invoker_id, L.uid('aisha'));
  const notes = await L.waitNotifications(req.hitl_id, 1);
  assert.deepEqual(notes.map((n) => `${n.kind}/${n.level}/${n.outcome}`), ['REQUESTED/0/SENT']);
  assert.equal((await L.slack.forHitl(req.hitl_id)).length, 1, 'one Slack message');
  const ex = await waitFor('the flagship, two Writer calls and the notifier', before, { [FLAGSHIP_WF]: 1, [WRITER_WF]: 2, [GATEWAY_WF]: 1 });
  const flag = ex.find((e) => e.id === String(r.n8n_execution_id));
  assert.ok(flag && flag.workflowId === FLAGSHIP_WF && flag.status === 'success', L.brief(ex));
  assert.equal(byWorkflow(ex, ERROR_WF).length, 0, 'no failure');
  assert.deepEqual(await L.types(corr), ['STARTED', ...Array(7).fill('ASSET_RECONCILED'), 'HITL_REQUESTED', 'NOTIFICATION_SENT']);
  const d = await L.decide('sarah', req.hitl_id, 'REJECTED', 'e2e cleanup: notifier harness run');
  assert.equal(d.status, 200, JSON.stringify(d.body));
  record(t, 'S18', { corr, hitl_id: req.hitl_id, executions: L.brief(ex) });
});

// S19: Assert Test Environment refuses before any request. The refused
// targets cannot be reached even if the check were broken: .invalid never
// resolves (RFC 2606) and 192.0.2.1 is TEST-NET-1 (RFC 5737); the password
// and invoke key in these runs are dummies.
test('S19 Assert Test Environment refuses FAO_ENV other than test and every non-local target before any request', { timeout: 600000 }, async (t) => {
  const t0 = await L.dbNow();
  const dummy = { FAO_TEST_INVOKER_PASSWORD: 'not-a-password-e2e', FAO_TEST_INVOKE_KEY: 'not-a-key-e2e' };
  const cases = [
    ['writer', { FAO_ENV: 'production' }, /^FAO-GOV-008 harness: FAO_ENV is not test; refusing to run/],
    ['writer', { FAO_TEST_SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co.invalid' }, /^FAO-GOV-008 harness: FAO_TEST_SUPABASE_URL is not a local target; refusing to run/],
    ['gateway', { FAO_TEST_SUPABASE_URL: 'http://192.0.2.1:8000' }, /^FAO-GOV-008 harness: FAO_TEST_SUPABASE_URL is not a local target; refusing to run/],
    ['gateway', { FAO_TEST_INVOKE_URL: 'https://n8n.fao-e2e.invalid/webhook/fao-recon-invoke' }, /^FAO-GOV-008 harness: FAO_TEST_INVOKE_URL is not a local target; refusing to run/],
  ];
  const seen = [];
  for (const [key, change, re] of cases) {
    const id = HARNESSES[key].id;
    const label = `${key} ${Object.keys(change)[0]}`;
    const before = L.lastExecutionId();
    const res = L.runHarness(id, L.harnessEnv('aisha', { ...dummy, ...change }));
    assert.equal(res.timedOut, false, `${label}: n8n execute timed out`);
    assert.equal(res.status, 1, `${label}: n8n execute exit code`);
    const ex = await L.waitExecutions(before, 1);
    assert.equal(ex.length, 1, `${label}: only the harness ran: ${L.brief(ex)}`);
    assert.equal(ex[0].workflowId, id);
    assert.equal(ex[0].status, 'error', label);
    assert.equal(ex[0].lastNodeExecuted, 'Assert Test Environment', label);
    assert.deepEqual([...(ex[0].nodes || [])].sort(), ['Assert Test Environment', 'Manual Trigger'], `${label}: no request node ran`);
    assert.match(ex[0].error.message, re, label);
    seen.push(`${label}: ${ex[0].id}`);
  }
  const runs = await L.q("SELECT correlation_id FROM public.run_invocations WHERE idempotency_key LIKE 'harness-%' AND requested_at >= $1", [t0]);
  assert.deepEqual(runs, [], 'no run started');
  record(t, 'S19', { refused: seen });
});

// ---------------------------------------------------------------------------
// S20 (B-19, F-38): the auditor query printed in fixtures/README.md
// ("Provenance threading", its one sql block, read from the file, not
// copied) runs as printed after a flagship run and returns each asset's
// provenance source from the STARTED row.
test('S20 the provenance query printed in fixtures/README.md returns the source of each asset of a flagship run', T, async (t) => {
  const readme = readFileSync(join(L.REPO_ROOT, 'fixtures', 'README.md'), 'utf8').replace(/\r\n/g, '\n');
  const start = readme.indexOf('\n## Provenance threading\n');
  assert.ok(start >= 0, 'fixtures/README.md has the Provenance threading section');
  const end = readme.indexOf('\n## ', start + 1);
  const section = readme.slice(start, end < 0 ? undefined : end);
  const blocks = [...section.matchAll(/```sql\n([\s\S]*?)\n```/g)].map((m) => m[1]);
  assert.equal(blocks.length, 1, 'exactly one sql block in the section');
  const sql = blocks[0];

  const { corr, run, ex } = await invoke('aisha', FLAGSHIP_PATH, { minExecutions: 4 });
  assert.equal(run.state, 'AWAITING_HITL');
  const rows = (await L.q(sql)).filter((x) => x.correlation_id === corr);
  const expected = {
    ADA: 'synthetic_anomaly', BTC: 'kraken_por_2025_q4_anchor', ETH: 'kraken_por_2025_q4_anchor', SOL: 'synthetic_anomaly',
    USDC: 'synthetic_clean_baseline', USDT: 'synthetic_anomaly', XRP: 'kraken_por_2025_q4_anchor',
  };
  assert.deepEqual(Object.fromEntries(rows.map((x) => [x.asset, x.provenance])), expected, 'one row per asset with its .source');
  assert.equal(rows.length, 7);
  const ledger = await L.ledger(corr);
  const started = ledger.find((x) => x.t === 'STARTED');
  for (const x of rows) {
    assert.equal(x.provenance, started.inputs.fixture_provenance[x.asset].source, `${x.asset}: the value written by Init Execution`);
    const a = assets(ledger).find((y) => y.inputs.asset === x.asset);
    assert.equal(String(x.policy_outcome), a.outcome, x.asset);
    assert.equal(x.policy_sub_tier === null ? null : String(x.policy_sub_tier), a.sub_tier, x.asset);
  }
  const req = await openRequest(corr);
  const d = await L.decide('sarah', req.hitl_id, 'REJECTED', 'e2e cleanup: provenance query run');
  assert.equal(d.status, 200, JSON.stringify(d.body));
  record(t, 'S20', { corr, provenance: Object.fromEntries(rows.map((x) => [x.asset, x.provenance])), executions: L.brief(ex) });
});

// ===========================================================================
// Patch round 6 scenarios (P1, P4)
// ===========================================================================

// S21 and S22 (P1, FAO-GOV-008): the pre-claim set is every flagship node
// that is not Respond 202 and not downstream of it. An older run is claimed
// with the id the next n8n execution will get and taken to AWAITING_HITL, as
// in S16; then that execution, the respondfail copy, fails at a pre-claim
// Respond node. The error handler must send 'flagship_pre_claim' (PRE_CLAIM,
// one workflow_failures row) and leave the older run untouched; before P1 it
// sent 'flagship' and fao_run_fail attached a FAILED row to the older run.
async function olderRunOnNextId(scenario) {
  const t0 = await L.dbNow();
  const ledgerBefore = await maxLedgerId();
  const next = String(L.nextExecutionId());
  const old = await L.startRun('aisha', { reason: `e2e ${scenario} older run holding the next execution id` });
  const c = await L.claim(old.token, next);
  assert.equal(c.ok, true, `claim with execution id ${next}: ${JSON.stringify(c)}`);
  await L.append([L.startedEvent(old.corr, ['USDT'])]);
  await L.append([L.assetEvent(old.corr, 'USDT', 'REQUIRE_HUMAN', 'STANDARD')]);
  const f = await L.finalize(old.corr);
  assert.equal(f.hitl_required, true, JSON.stringify(f));
  const oldRun = await L.run(old.corr);
  assert.equal(oldRun.state, 'AWAITING_HITL');
  assert.equal(oldRun.n8n_execution_id, next);
  const oldRows = await L.ledger(old.corr);
  const req = await openRequest(old.corr);
  assert.equal(req.decision, 'PENDING');
  assert.equal(String(L.nextExecutionId()), next, 'no n8n execution started while the older run was set up');
  return { t0, ledgerBefore, next, old, oldRun, oldRows, req };
}

async function assertPreClaimRespondFailure(ctx, w, failedNode, mustRun) {
  const { t0, ledgerBefore, next, old, oldRun, oldRows, req } = ctx;
  assert.ok(w.status < 200 || w.status > 299, `the webhook did not answer 2xx: ${w.status} ${w.text}`);
  const ex = await waitFor(`respondfail copy failing at ${failedNode} and the error handler`, Number(next) - 1, { [VARIANTS.respondfail.id]: 1, [ERROR_WF]: 1 });

  const flag = byWorkflow(ex, VARIANTS.respondfail.id);
  assert.equal(flag.length, 1, L.brief(ex));
  assert.equal(flag[0].id, next, `the failing execution has the older run's id: ${L.brief(ex)}`);
  assert.equal(flag[0].status, 'error');
  assert.equal(flag[0].lastNodeExecuted, failedNode);
  assert.equal(flag[0].error && flag[0].error.node, failedNode, L.brief(flag));
  for (const n of mustRun) assert.ok((flag[0].nodes || []).includes(n), `${n} ran`);
  for (const n of ['Respond 202', 'Init Execution', 'Writer: STARTED']) assert.ok(!(flag[0].nodes || []).includes(n), `${n} never ran`);

  const handler = byWorkflow(ex, ERROR_WF);
  assert.equal(handler.length, 1, L.brief(ex));
  assert.equal(handler[0].status, 'success', L.brief(handler));
  const r = failResult(handler[0]);
  assert.deepEqual([r.ok, r.code, r.outcome, r.correlation_id, r.ledger_id, r.state], [true, 'OK', 'PRE_CLAIM', null, null, null], JSON.stringify(r));

  const rows = await L.workflowFailures(next, t0);
  assert.equal(rows.length, 1, JSON.stringify(rows));
  assert.deepEqual([rows[0].source, rows[0].outcome, rows[0].failed_node, rows[0].correlation_id],
    ['flagship_pre_claim', 'PRE_CLAIM', failedNode, null]);
  assert.equal(rows[0].message, L.cleanText(flag[0].error.message, 500));

  // The older run: same rows, same state, request still pending.
  assert.deepEqual((await L.ledger(old.corr)).map((x) => x.ledger_id), oldRows.map((x) => x.ledger_id), 'no row on the older run');
  const after = await L.run(old.corr);
  assert.equal(after.state, 'AWAITING_HITL');
  assert.equal(after.last_error, oldRun.last_error);
  assert.equal((await openRequest(old.corr)).decision, 'PENDING');
  assert.deepEqual(await strayFailed(next, ledgerBefore), [], 'no FAILED ledger row for that execution id');

  const d = await L.decide('sarah', req.hitl_id, 'REJECTED', 'e2e cleanup: older run on a reused execution id');
  assert.equal(d.status, 200, JSON.stringify(d.body));
  return { ex, row: rows[0] };
}

test('S21 a flagship failure at Respond 400 (bad body) records PRE_CLAIM and leaves an older AWAITING_HITL run on the same id untouched', T, async (t) => {
  const ctx = await olderRunOnNextId('S21');
  const w = await L.webhook(P.respondfail, {});
  const { ex, row } = await assertPreClaimRespondFailure(ctx, w, 'Respond 400', ['Validate Invoke Body', 'Body Valid?']);
  assert.ok(!(byWorkflow(ex, VARIANTS.respondfail.id)[0].nodes || []).includes('Claim Run'), 'Claim Run never ran');
  record(t, 'S21', { corr: ctx.old.corr, execution_id: ctx.next, webhook_http: w.status, workflow_failure: row.id, executions: L.brief(ex) });
});

test('S22 a flagship failure at Respond Claim Refused (replayed token) records PRE_CLAIM and leaves an older AWAITING_HITL run on the same id untouched', T, async (t) => {
  const ctx = await olderRunOnNextId('S22');
  const refusalsBefore = Number((await L.one('SELECT coalesce(max(refusal_id), 0) AS m FROM public.fao_refusal_journal')).m);
  // The older run's own token, already consumed: Claim Run refuses it
  // ALREADY_CLAIMED, so the refused branch runs and its Respond node fails.
  const w = await L.webhook(P.respondfail, { run_token: ctx.old.token });
  const { ex, row } = await assertPreClaimRespondFailure(ctx, w, 'Respond Claim Refused', ['Validate Invoke Body', 'Body Valid?', 'Claim Run', 'Claim OK?']);
  const refusals = await L.q(
    "SELECT code, target_key FROM public.fao_refusal_journal WHERE refusal_id > $1 AND entry_point = 'rpc:fao_run_claim' ORDER BY refusal_id",
    [refusalsBefore],
  );
  assert.deepEqual(refusals.map((x) => [x.code, x.target_key]), [['ALREADY_CLAIMED', ctx.old.corr]], 'Claim Run refused the replayed token once');
  record(t, 'S22', { corr: ctx.old.corr, execution_id: ctx.next, webhook_http: w.status, workflow_failure: row.id, executions: L.brief(ex) });
});

// S23 (P4, K4; FAO-GOV-008): n8n stops a flagship execution at 600 s, before
// the claim's stale-run rule (sla_max_execution_seconds, at least 900) can
// fail its run for a new execution on the same id. The imported workflows
// (as n8n stored them) carry the export timeouts, every flagship copy keeps
// the flagship's, and the container's EXECUTIONS_TIMEOUT_MAX does not cap
// the flagship's below what the export sets.
test('S23 the imported flagship has executionTimeout 600, below the agent SLA, and the notifier and sweeper carry 120 and 300', T, async (t) => {
  const s = L.workflowSettings();
  const timeout = (id) => (s[id] || {}).executionTimeout;
  assert.equal(timeout(FLAGSHIP_WF), 600, `flagship settings ${JSON.stringify(s[FLAGSHIP_WF])}`);
  assert.equal(timeout(GATEWAY_WF), 120, `notifier settings ${JSON.stringify(s[GATEWAY_WF])}`);
  assert.equal(timeout('FaoSweeperV1x001'), 300, `sweeper settings ${JSON.stringify(s.FaoSweeperV1x001)}`);
  for (const [name, v] of Object.entries(VARIANTS)) assert.equal(timeout(v.id), 600, `flagship copy ${name}`);
  for (const id of [SWEEP_WF, SWEEP_NFAIL_ID]) assert.equal(timeout(id), 300, `sweeper copy ${id}`);

  const max = L.containerEnv('EXECUTIONS_TIMEOUT_MAX');
  assert.ok(max !== null && Number(max) >= 600, `EXECUTIONS_TIMEOUT_MAX is at least 600 (got ${max})`);

  const sla = Number((await L.one('SELECT sla_max_execution_seconds AS s FROM public.agent_registry WHERE agent_id = $1', [L.FLAGSHIP])).s);
  assert.ok(sla >= 900, `flagship sla_max_execution_seconds ${sla} is at least 900`);
  assert.ok(timeout(FLAGSHIP_WF) < sla, `executionTimeout ${timeout(FLAGSHIP_WF)} is below the SLA ${sla}`);
  record(t, 'S23', { flagship: timeout(FLAGSHIP_WF), notifier: timeout(GATEWAY_WF), sweeper: timeout('FaoSweeperV1x001'), timeout_max: Number(max), sla });
});
