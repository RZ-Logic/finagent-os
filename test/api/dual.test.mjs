// ============================================================================
// FinAgent OS API tests: dual approval over HTTP with real sign-ins
// (DUAL-APPROVAL.md 9.2, cases A1 to A18; owner decisions DA-1 to DA-4)
// Controls: FAO-GOV-004 (a CRITICAL request needs two approvals from
// different eligible approvers, never the invoker; one rejection closes it;
// an approval counts only through a qualifying approver grant, DA-4),
// FAO-GOV-001 (refusals journaled with the caller's id; approvals and the
// ledger append-only), FAO-GOV-015 (the reader sees approvals and the
// summary columns).
//
// Users: A = Aisha (invoker), B = Sarah, C = Marcus (approver, admin),
// R = the MCP reader, O = outsider, L = ratelimit@local.test (owner row, no
// approver grant in the seeds). "2 of 2" is a CRITICAL flagship request
// invoked by A (makeCriticalRequest). A15 to A18 grant L only, so no seed
// grant changes; each revokes every L approver grant in a finally (owner pg,
// with a change reason) and rejects its open requests as C. A8 restores B's
// grant by an owner insert with granted_by NULL, never through
// fao_admin_set_role (that would record granted_by C, and under DA-4 B would
// then stop counting on every later request C also approves).
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  rpc, rest, signIn, one, q, uid, closeAll, owner, ownerTx, makeRequest, makeCriticalRequest,
  ledgerTypes, maxRefusalId, journalSince, journalRow, MESSAGES, FORBIDDEN_TEXT, FLAGSHIP,
} from './lib.mjs';

after(closeAll);

const TAG = `api-dual-${randomUUID().slice(0, 8)}`;

const DECIDE_KEYS = ['code', 'committed', 'committed_ledger_id', 'decided_at', 'decision', 'hitl_id', 'http_status', 'message', 'ok', 'ref'];
const AWAITING_KEYS = [
  'approvals_received', 'approved_at', 'code', 'committed', 'committed_ledger_id', 'decided_at', 'decision',
  'enforced_approvals', 'hitl_id', 'http_status', 'message', 'ok', 'ref',
];
const REFUSAL_KEYS = ['code', 'http_status', 'message', 'ok', 'ref'];

const A = 'aisha';
const B = 'sarah';
const C = 'marcus';
const L = 'ratelimit';

// --- Calls -----------------------------------------------------------------------

async function decide(key, hitlId, decision, { notes, headers, extra } = {}) {
  const body = { p_hitl_id: String(hitlId), p_decision: decision, ...(notes === undefined ? {} : { p_notes: notes }), ...(extra || {}) };
  return rpc('fao_hitl_decide', body, { token: await signIn(key), headers });
}
async function view(key, hitlId) {
  return rpc('fao_hitl_get', { p_hitl_id: String(hitlId) }, { token: await signIn(key) });
}

// --- Reads (owner) ---------------------------------------------------------------

const approvalRows = (hitlId) => q(
  'SELECT approval_id, approver_id, approved_at, decision_notes FROM public.hitl_approvals WHERE hitl_id = $1 ORDER BY approval_id',
  [hitlId],
);
const approvers = async (hitlId) => (await approvalRows(hitlId)).map((r) => r.approver_id);
const requestRow = (hitlId) => one(
  'SELECT decision::text AS decision, approver_id, configured_approvals, enforced_approvals, created_at FROM public.hitl_queue WHERE hitl_id = $1',
  [hitlId],
);
const runState = async (corr) => (await one('SELECT state::text AS s FROM public.run_invocations WHERE correlation_id = $1', [corr])).s;
const eventRows = (corr, type) => q(
  "SELECT inputs, hitl_approver_id, status::text AS status, hitl_status::text AS hitl_status, policy_rationale FROM public.shadow_ledger WHERE correlation_id = $1 AND inputs->>'event_type' = $2 ORDER BY ledger_id",
  [corr, type],
);
const activeApproverGrants = (key) => q(
  "SELECT id, agent_id, granted_by, granted_at FROM public.fao_user_roles WHERE user_id = $1 AND role = 'approver' AND revoked_at IS NULL ORDER BY id",
  [uid(key)],
);

// --- Expectations ----------------------------------------------------------------

function expectAwaiting(r, hitlId, received, label) {
  assert.equal(r.status, 200, `${label}: ${r.status} ${JSON.stringify(r.body)}`);
  assert.deepEqual(Object.keys(r.body).sort(), AWAITING_KEYS, `${label}: exactly the 13 AWAITING_FURTHER_APPROVAL keys`);
  assert.equal(r.body.ok, true, label);
  assert.equal(r.body.code, 'AWAITING_FURTHER_APPROVAL', label);
  assert.equal(r.body.http_status, 200, label);
  assert.equal(r.body.message, MESSAGES.AWAITING_FURTHER_APPROVAL, label);
  assert.equal(r.body.ref, null, `${label}: not journaled`);
  assert.equal(Number(r.body.hitl_id), hitlId, label);
  assert.equal(r.body.decision, 'PENDING', label);
  assert.equal(r.body.decided_at, null, label);
  assert.equal(r.body.committed, false, label);
  assert.equal(r.body.committed_ledger_id, null, label);
  assert.equal(r.body.approvals_received, received, `${label}: approvals_received`);
  assert.equal(r.body.enforced_approvals, 2, `${label}: enforced_approvals`);
  assert.ok(typeof r.body.approved_at === 'string' && r.body.approved_at !== '', `${label}: approved_at`);
}

function expectDecided(r, hitlId, decision, label) {
  assert.equal(r.status, 200, `${label}: ${r.status} ${JSON.stringify(r.body)}`);
  assert.deepEqual(Object.keys(r.body).sort(), DECIDE_KEYS, `${label}: exactly the core decide keys`);
  assert.equal(r.body.ok, true, label);
  assert.equal(r.body.code, 'OK', label);
  assert.equal(r.body.message, MESSAGES.OK, label);
  assert.equal(Number(r.body.hitl_id), hitlId, label);
  assert.equal(r.body.decision, decision, label);
  assert.equal(r.body.committed, true, `${label}: committed`);
}

async function expectRefusal(r, { status, code, who, hitlId, decision, label }) {
  assert.equal(r.status, status, `${label}: ${r.status} ${JSON.stringify(r.body)}`);
  assert.deepEqual(Object.keys(r.body).sort(), REFUSAL_KEYS, `${label}: the plain refusal keys`);
  assert.equal(r.body.ok, false, label);
  assert.equal(r.body.code, code, label);
  assert.equal(r.body.http_status, status, label);
  assert.equal(r.body.message, MESSAGES[code], label);
  assert.ok(!FORBIDDEN_TEXT.test(r.text), `${label}: no database text (${r.text})`);
  assert.ok(r.body.ref, `${label}: journal reference returned`);
  const row = await journalRow(r.body.ref);
  assert.ok(row, `${label}: journal row readable after the response (committed with the 4xx)`);
  assert.equal(row.code, code, label);
  assert.equal(row.message, MESSAGES[code], label);
  assert.equal(row.actor_uid, uid(who), `${label}: journal names the signed-in caller`);
  assert.equal(row.session_role, 'authenticator', label);
  assert.equal(row.target_table, 'hitl_queue', label);
  assert.equal(row.target_key, String(hitlId), label);
  assert.equal(row.attempted.decision, decision, `${label}: attempted decision`);
  return row;
}

// --- Set-up and clean-up ---------------------------------------------------------

// Owner grant of the approver role to L, with granted_by exactly as given
// (NULL for a seed-style grant). Committed before it returns, so its
// granted_at is strictly before any request opened afterwards.
async function grantL(agentId, grantedBy, why) {
  return ownerTx(async (c) => {
    await c.query("SELECT set_config('fao.change_reason', $1, true)", [`${TAG} ${why}`]);
    const { rows } = await c.query(
      "INSERT INTO public.fao_user_roles (user_id, role, agent_id, granted_by, reason) VALUES ($1, 'approver', $2, $3, $4) RETURNING id, granted_at",
      [uid(L), agentId, grantedBy, `${TAG} ${why}`],
    );
    return rows[0];
  });
}

async function revokeL(why) {
  await ownerTx(async (c) => {
    await c.query("SELECT set_config('fao.change_reason', $1, true)", [`${TAG} ${why}`]);
    await c.query(
      "UPDATE public.fao_user_roles SET revoked_at = now() WHERE user_id = $1 AND role = 'approver' AND revoked_at IS NULL",
      [uid(L)],
    );
  });
}

// Rejects each request still PENDING as C (the cleanup the spec names).
async function rejectOpen(ids) {
  for (const id of ids) {
    if (id === undefined || id === null) continue;
    const row = await requestRow(id);
    if (row && row.decision === 'PENDING') {
      await decide(C, id, 'REJECTED', { notes: `${TAG} cleanup` });
    }
  }
}

// Every case that grants L starts from no active L approver grant.
async function startWithoutLGrants() {
  if ((await activeApproverGrants(L)).length > 0) await revokeL('clear L approver grants left by an earlier run');
  assert.equal((await activeApproverGrants(L)).length, 0, 'L holds no approver grant');
}

async function setOwnerActive(c, key, active, why) {
  await c.query("SELECT set_config('fao.change_reason', $1, true)", [`${TAG} ${why}`]);
  await c.query('UPDATE public.process_owners SET active = $2 WHERE id = $1 AND active IS DISTINCT FROM $2', [uid(key), active]);
}

// --- A1, A2, A11 -----------------------------------------------------------------

test('A1, A2, A11: B then C approve a 2 of 2 over HTTP; seed grants qualify; R reads the approvals, O sees none, nobody writes them', async () => {
  // A2 seed check (DA-4): B's and C's unrevoked approver grants have granted_by NULL.
  for (const key of [B, C]) {
    const grants = await activeApproverGrants(key);
    assert.ok(grants.length >= 1, `${key} holds an approver grant`);
    for (const g of grants) assert.equal(g.granted_by, null, `${key} grant ${g.id}: granted_by NULL (seed-style, qualifying)`);
  }

  const { hitlId, corr } = await makeCriticalRequest(A);
  const req = await requestRow(hitlId);
  assert.equal(req.configured_approvals, 2);
  assert.equal(req.enforced_approvals, 2, 'CRITICAL review on the flagship enforces 2 (DA-1)');
  for (const key of [B, C]) {
    for (const g of await activeApproverGrants(key)) {
      assert.ok(new Date(g.granted_at) < new Date(req.created_at), `${key} grant ${g.id} was made before the request opened`);
    }
  }

  // A1
  const before = await maxRefusalId();
  const notes = `${TAG} A1 approval by B`;
  const a1 = await decide(B, hitlId, 'APPROVED', { notes });
  expectAwaiting(a1, hitlId, 1, 'A1');
  assert.equal((await journalSince(before)).filter((j) => j.actor_uid === uid(B)).length, 0, 'A1: no journal row for B');
  const rows1 = await approvalRows(hitlId);
  assert.deepEqual(rows1.map((r) => r.approver_id), [uid(B)], 'A1: one approval row, B');
  assert.equal(rows1[0].decision_notes, notes, 'A1: notes as sent');
  const same = await one('SELECT (approved_at = $2::timestamptz) AS eq FROM public.hitl_approvals WHERE approval_id = $1', [rows1[0].approval_id, a1.body.approved_at]);
  assert.equal(same.eq, true, 'A1: approved_at in the envelope is the row time');
  assert.equal((await requestRow(hitlId)).decision, 'PENDING');
  assert.equal((await requestRow(hitlId)).approver_id, null);
  assert.equal(await runState(corr), 'AWAITING_HITL');
  const recorded = await eventRows(corr, 'HITL_APPROVAL_RECORDED');
  assert.equal(recorded.length, 1, 'A1: one HITL_APPROVAL_RECORDED');
  assert.deepEqual(recorded[0].inputs.approvers, [uid(B)]);
  assert.equal(recorded[0].hitl_approver_id, uid(B));
  assert.equal(recorded[0].hitl_status, 'PENDING');

  // A2
  const a2 = await decide(C, hitlId, 'APPROVED', { notes: `${TAG} A2 approval by C` });
  expectDecided(a2, hitlId, 'APPROVED', 'A2');
  const types = await ledgerTypes(corr);
  assert.deepEqual(types.slice(-3), ['HITL_APPROVAL_RECORDED', 'HITL_RESOLVED', 'COMMITTED'], `A2: ledger tail (${types.join(', ')})`);
  const res = (await eventRows(corr, 'HITL_RESOLVED'))[0];
  assert.deepEqual(res.inputs.approvers, [uid(B), uid(C)], 'A2: HITL_RESOLVED names both approvers in order');
  assert.equal(res.inputs.approver_id, uid(C));
  assert.equal(Number(res.inputs.enforced_approvals), 2);
  const com = (await eventRows(corr, 'COMMITTED'))[0];
  assert.equal(com.status, 'SUCCESS');
  assert.equal(com.hitl_approver_id, uid(C));
  const done = await requestRow(hitlId);
  assert.equal(done.decision, 'APPROVED');
  assert.equal(done.approver_id, uid(C));
  assert.equal(await runState(corr), 'COMMITTED');
  const reader = await signIn('reader');
  const sum = await rest('GET', 'fao_run_summary', { token: reader, query: `?correlation_id=eq.${corr}` });
  assert.equal(sum.status, 200);
  assert.equal(sum.body.length, 1);
  assert.equal(sum.body[0].hitl_decision, 'APPROVED');
  assert.equal(sum.body[0].approver_id, uid(C));
  assert.equal(Number(sum.body[0].enforced_approvals), 2);
  assert.equal(Number(sum.body[0].approvals_recorded), 2);

  // A11: R reads the rows; O reads none; B and C cannot write.
  const rows = await rest('GET', 'hitl_approvals', { token: reader, query: `?hitl_id=eq.${hitlId}&order=approval_id` });
  assert.equal(rows.status, 200);
  assert.deepEqual(rows.body.map((r) => r.approver_id), [uid(B), uid(C)], 'A11: the reader sees both approval rows');
  const outsider = await signIn('outsider');
  const none = await rest('GET', 'hitl_approvals', { token: outsider, query: `?hitl_id=eq.${hitlId}` });
  assert.equal(none.status, 200);
  assert.deepEqual(none.body, [], 'A11: the outsider sees no approval row');
  const snap = async () => (await one(
    "SELECT count(*) AS n, md5(coalesce(string_agg(x::text, '|' ORDER BY x.approval_id), '')) AS h FROM public.hitl_approvals x",
  ));
  const s0 = await snap();
  for (const key of [B, C]) {
    const token = await signIn(key);
    const post = await rest('POST', 'hitl_approvals', {
      token, headers: { Prefer: 'return=minimal' },
      body: { hitl_id: hitlId, approver_id: uid(key), approved_at: new Date().toISOString(), decision_notes: `${TAG} direct` },
    });
    assert.ok(post.status >= 400 && post.status < 500, `A11: ${key} POST ${post.status}`);
    const patch = await rest('PATCH', 'hitl_approvals', { token, query: `?hitl_id=eq.${hitlId}`, body: { decision_notes: `${TAG} direct` }, headers: { Prefer: 'return=minimal' } });
    assert.ok(patch.status >= 400 && patch.status < 500, `A11: ${key} PATCH ${patch.status}`);
    const del = await rest('DELETE', 'hitl_approvals', { token, query: `?hitl_id=eq.${hitlId}`, headers: { Prefer: 'return=minimal' } });
    assert.ok(del.status >= 400 && del.status < 500, `A11: ${key} DELETE ${del.status}`);
  }
  assert.deepEqual(await snap(), s0, 'A11: hitl_approvals unchanged');
});

// --- A3, A7 ----------------------------------------------------------------------

test('A3, A7: B approves twice (second ALREADY_APPROVED 409, journaled); the decision view shows the progress to B and C', async () => {
  const { hitlId, corr } = await makeCriticalRequest(A);
  try {
    expectAwaiting(await decide(B, hitlId, 'APPROVED'), hitlId, 1, 'A3 first');
    const ledgerBefore = await ledgerTypes(corr);
    const second = await decide(B, hitlId, 'APPROVED');
    await expectRefusal(second, { status: 409, code: 'ALREADY_APPROVED', who: B, hitlId, decision: 'APPROVED', label: 'A3 second' });
    assert.deepEqual(await approvers(hitlId), [uid(B)], 'A3: still one approval row');
    assert.deepEqual(await ledgerTypes(corr), ledgerBefore, 'A3: ledger unchanged');
    assert.equal((await requestRow(hitlId)).decision, 'PENDING');

    // A7
    const vb = await view(B, hitlId);
    assert.equal(vb.status, 200);
    assert.equal(vb.body.request.approvals_received, 1);
    assert.equal(vb.body.request.viewer_has_approved, true);
    assert.equal(vb.body.request.viewer_can_decide, true);
    const vc = await view(C, hitlId);
    assert.equal(vc.status, 200);
    assert.equal(vc.body.request.approvals_received, 1);
    assert.equal(vc.body.request.viewer_has_approved, false);
    assert.equal(vc.body.request.viewer_can_decide, true);
  } finally {
    await rejectOpen([hitlId]);
  }
});

// --- A4, A5 ----------------------------------------------------------------------

test('A4: B approves, C rejects: REJECTED by C, COMMITTED ROLLED_BACK', async () => {
  const { hitlId, corr } = await makeCriticalRequest(A);
  expectAwaiting(await decide(B, hitlId, 'APPROVED'), hitlId, 1, 'A4 approve');
  const r = await decide(C, hitlId, 'REJECTED', { notes: `${TAG} A4 rejection` });
  expectDecided(r, hitlId, 'REJECTED', 'A4 reject');
  const row = await requestRow(hitlId);
  assert.equal(row.decision, 'REJECTED');
  assert.equal(row.approver_id, uid(C));
  const res = (await eventRows(corr, 'HITL_RESOLVED'))[0];
  assert.deepEqual(res.inputs.approvers, [uid(C)], 'HITL_RESOLVED names the rejector only');
  assert.match(res.policy_rationale, /; approvals received 1 of 2 before the rejection$/);
  const com = await eventRows(corr, 'COMMITTED');
  assert.equal(com.length, 1);
  assert.equal(com[0].status, 'ROLLED_BACK');
  assert.equal(await runState(corr), 'COMMITTED');
  assert.deepEqual(await approvers(hitlId), [uid(B)], "B's approval row is kept");
});

test('A5: B approves, then B rejects: REJECTED by B', async () => {
  const { hitlId, corr } = await makeCriticalRequest(A);
  expectAwaiting(await decide(B, hitlId, 'APPROVED'), hitlId, 1, 'A5 approve');
  expectDecided(await decide(B, hitlId, 'REJECTED', { notes: `${TAG} A5 rejection` }), hitlId, 'REJECTED', 'A5 reject');
  const row = await requestRow(hitlId);
  assert.equal(row.decision, 'REJECTED');
  assert.equal(row.approver_id, uid(B));
  assert.equal((await eventRows(corr, 'COMMITTED'))[0].status, 'ROLLED_BACK');
});

// --- A6, A10 ---------------------------------------------------------------------

test('A6, A10: the invoker is refused both decisions with no approval row; identity in body keys is INVALID_INPUT, in headers it changes nothing', async () => {
  const { hitlId } = await makeCriticalRequest(A);
  try {
    for (const d of ['APPROVED', 'REJECTED']) {
      await expectRefusal(await decide(A, hitlId, d), { status: 403, code: 'SOD_SELF_APPROVAL', who: A, hitlId, decision: d, label: `A6 ${d}` });
    }
    assert.deepEqual(await approvers(hitlId), [], 'A6: no approval row for the request');

    // A10: body keys naming an approver are refused by the body rule.
    for (const extra of [{ p_approver_id: uid(C) }, { p_approvers: [uid(C)] }]) {
      const label = `A10 ${Object.keys(extra)[0]}`;
      const r = await decide(B, hitlId, 'APPROVED', { extra });
      assert.equal(r.status, 400, `${label}: ${r.status}`);
      assert.equal(r.body.code, 'INVALID_INPUT', label);
      assert.equal(r.body.message, MESSAGES.INVALID_INPUT, label);
      assert.ok(r.body.ref, `${label}: journaled`);
      const row = await journalRow(r.body.ref);
      assert.equal(row.actor_uid, uid(B), label);
      assert.equal(row.attempted.invalid_body, 'unknown_key', label);
    }
    assert.deepEqual(await approvers(hitlId), [], 'A10: no approval row after the refused bodies');

    // Headers naming C: the approval is B's, and only B's.
    const forged = { 'X-User-Id': uid(C), 'X-Forwarded-User': 'marcus.patel@finagent-os.demo', 'X-Forwarded-Email': 'marcus.patel@finagent-os.demo' };
    expectAwaiting(await decide(B, hitlId, 'APPROVED', { headers: forged }), hitlId, 1, 'A10 headers');
    assert.deepEqual(await approvers(hitlId), [uid(B)], 'A10: the approval row names B');
  } finally {
    await rejectOpen([hitlId]);
  }
});

// --- A8 --------------------------------------------------------------------------

test("A8: B approves, C revokes B's approver grant, C's approval is partial (1 of 2); B's grant restored by an owner insert", async () => {
  const { hitlId, corr } = await makeCriticalRequest(A);
  const marcus = await signIn(C);
  try {
    expectAwaiting(await decide(B, hitlId, 'APPROVED'), hitlId, 1, 'A8 B');
    const rv = await rpc('fao_admin_set_role', { p_user_id: uid(B), p_role: 'approver', p_agent_id: null, p_grant: 'false', p_reason: `${TAG} A8 revoke B` }, { token: marcus });
    assert.equal(rv.status, 200, `revoke: ${rv.status} ${rv.body && rv.body.code}`);
    assert.equal(rv.body.ok, true);
    const c1 = await decide(C, hitlId, 'APPROVED');
    expectAwaiting(c1, hitlId, 1, 'A8 C');
    const rec = await eventRows(corr, 'HITL_APPROVAL_RECORDED');
    assert.equal(rec.length, 2);
    assert.deepEqual(rec[1].inputs.approvers, [uid(C)], 'B no longer counts');
    assert.match(rec[1].policy_rationale, /; 1 earlier approvals no longer count$/);
    assert.equal((await requestRow(hitlId)).decision, 'PENDING');
  } finally {
    await ownerTx(async (c) => {
      await c.query("SELECT set_config('fao.change_reason', $1, true)", [`${TAG} A8 restore B approver grant`]);
      await c.query(
        `INSERT INTO public.fao_user_roles (user_id, role, agent_id, granted_by, reason)
         SELECT $1, 'approver', NULL, NULL, $2
          WHERE NOT EXISTS (SELECT 1 FROM public.fao_user_roles r
                             WHERE r.user_id = $1 AND r.role = 'approver' AND r.agent_id IS NULL AND r.revoked_at IS NULL)`,
        [uid(B), `${TAG} A8 restore B approver grant`],
      );
    });
    await rejectOpen([hitlId]);
  }
  const grants = await activeApproverGrants(B);
  assert.equal(grants.filter((g) => g.agent_id === null).length, 1, 'B holds one global approver grant again');
  for (const g of grants) assert.equal(g.granted_by, null, 'restored with granted_by NULL');
});

// --- A9 --------------------------------------------------------------------------

test('A9: while a pg session holds the request row, C gets BUSY 409; after release C decides', async () => {
  const { hitlId } = await makeCriticalRequest(A);
  try {
    expectAwaiting(await decide(B, hitlId, 'APPROVED'), hitlId, 1, 'A9 B');
    const holder = await owner().connect();
    try {
      await holder.query('BEGIN');
      await holder.query('SELECT 1 FROM public.hitl_queue WHERE hitl_id = $1 FOR UPDATE', [hitlId]);
      await expectRefusal(await decide(C, hitlId, 'APPROVED'), { status: 409, code: 'BUSY', who: C, hitlId, decision: 'APPROVED', label: 'A9 busy' });
    } finally {
      await holder.query('ROLLBACK').catch(() => {});
      holder.release();
    }
    assert.deepEqual(await approvers(hitlId), [uid(B)], 'A9: nothing written by the BUSY call');
    expectDecided(await decide(C, hitlId, 'APPROVED'), hitlId, 'APPROVED', 'A9 retry');
  } finally {
    await rejectOpen([hitlId]);
  }
});

// --- A12 -------------------------------------------------------------------------

test('A12: a STANDARD request commits on B\'s one approval: one approval row, no HITL_APPROVAL_RECORDED', async () => {
  const { hitlId, corr } = await makeRequest(A);
  const req = await requestRow(hitlId);
  assert.equal(req.configured_approvals, 2);
  assert.equal(req.enforced_approvals, 1, 'STANDARD review enforces 1 (DA-1)');
  expectDecided(await decide(B, hitlId, 'APPROVED', { notes: `${TAG} A12` }), hitlId, 'APPROVED', 'A12');
  assert.deepEqual(await approvers(hitlId), [uid(B)], 'A12: one approval row');
  const types = await ledgerTypes(corr);
  assert.ok(!types.includes('HITL_APPROVAL_RECORDED'), `A12: no HITL_APPROVAL_RECORDED (${types.join(', ')})`);
  assert.deepEqual(types.slice(-3), ['HITL_REQUESTED', 'HITL_RESOLVED', 'COMMITTED']);
  const res = (await eventRows(corr, 'HITL_RESOLVED'))[0];
  assert.deepEqual(res.inputs.approvers, [uid(B)]);
  assert.equal(Number(res.inputs.enforced_approvals), 1);
});

// --- A13 -------------------------------------------------------------------------

test("A13: with B's process_owners row held FOR UPDATE, C's approve is BUSY within 5 s, L1 is released, and C's retry decides", async () => {
  const { hitlId } = await makeCriticalRequest(A);
  try {
    expectAwaiting(await decide(B, hitlId, 'APPROVED'), hitlId, 1, 'A13 B');
    const holder = await owner().connect();
    let open = false;
    try {
      await holder.query('BEGIN');
      open = true;
      await holder.query('SELECT 1 FROM public.process_owners WHERE id = $1 FOR UPDATE', [uid(B)]);
      const t0 = Date.now();
      const r = await decide(C, hitlId, 'APPROVED');
      const elapsed = Date.now() - t0;
      await expectRefusal(r, { status: 409, code: 'BUSY', who: C, hitlId, decision: 'APPROVED', label: 'A13 busy' });
      assert.ok(elapsed < 5000, `A13: BUSY after ${elapsed} ms (bounded wait)`);
      assert.equal((await requestRow(hitlId)).decision, 'PENDING');
      assert.deepEqual(await approvers(hitlId), [uid(B)], 'A13: still one approval row');
      // L1 released: a third session takes the request row with NOWAIT.
      const third = await owner().connect();
      try {
        await third.query('BEGIN');
        const got = await third.query('SELECT hitl_id FROM public.hitl_queue WHERE hitl_id = $1 FOR UPDATE NOWAIT', [hitlId]);
        assert.equal(got.rows.length, 1, 'A13: the request row lock is free');
      } finally {
        await third.query('ROLLBACK').catch(() => {});
        third.release();
      }
    } finally {
      if (open) await holder.query('ROLLBACK').catch(() => {});
      holder.release();
    }
    expectDecided(await decide(C, hitlId, 'APPROVED'), hitlId, 'APPROVED', 'A13 retry');
  } finally {
    await rejectOpen([hitlId]);
  }
});

// --- A14 -------------------------------------------------------------------------

test("A14: C's REJECT waiting at L3 while C is deactivated returns NOT_AUTHORISED 403 (re-check after the locks)", async () => {
  const { hitlId } = await makeCriticalRequest(A);
  await signIn(C); // token cached before the lock is held
  const holder = await owner().connect();
  let open = false;
  try {
    await holder.query('BEGIN');
    open = true;
    const pid = (await holder.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
    await holder.query('SELECT 1 FROM public.process_owners WHERE id = $1 FOR UPDATE', [uid(C)]);
    const pending = decide(C, hitlId, 'REJECTED', { notes: `${TAG} A14 rejection` });
    pending.catch(() => {}); // awaited below; never an unhandled rejection if an assertion fails first
    // Wait until the decide call blocks on the held row (L3), then deactivate
    // C and commit, well inside the 2 s lock wait.
    let blocked = false;
    for (let i = 0; i < 60 && !blocked; i += 1) {
      const n = (await one('SELECT count(*)::int AS n FROM pg_stat_activity WHERE $1 = ANY (pg_catalog.pg_blocking_pids(pid))', [pid])).n;
      blocked = n > 0;
      if (!blocked) await new Promise((res) => setTimeout(res, 25));
    }
    assert.ok(blocked, "A14: C's REJECT waits on the held process_owners row");
    await setOwnerActive(holder, C, false, 'A14 deactivate C while the reject waits');
    await holder.query('COMMIT');
    open = false;
    const r = await pending;
    await expectRefusal(r, { status: 403, code: 'NOT_AUTHORISED', who: C, hitlId, decision: 'REJECTED', label: 'A14' });
    assert.equal((await requestRow(hitlId)).decision, 'PENDING', 'A14: request still PENDING');
  } finally {
    if (open) await holder.query('ROLLBACK').catch(() => {});
    holder.release();
    await ownerTx((c) => setOwnerActive(c, C, true, 'A14 reactivate C'));
    await rejectOpen([hitlId]);
  }
  assert.equal((await one('SELECT active FROM public.process_owners WHERE id = $1', [uid(C)])).active, true, 'C reactivated');
});

// --- A15 to A18 (DA-4) ------------------------------------------------------------

test('A15 (DA-4): a grant made after the request opened does not qualify for it; it qualifies for a request opened later', async () => {
  await startWithoutLGrants();
  const open = [];
  try {
    const r1 = await makeCriticalRequest(A);
    open.push(r1.hitlId);
    await grantL(FLAGSHIP, null, 'A15 grant L after R1 opened');
    for (const d of ['APPROVED', 'REJECTED']) {
      await expectRefusal(await decide(L, r1.hitlId, d), { status: 403, code: 'NOT_AUTHORISED', who: L, hitlId: r1.hitlId, decision: d, label: `A15 R1 ${d}` });
    }
    assert.deepEqual(await approvers(r1.hitlId), [], 'A15: no approval row on R1');
    assert.equal((await requestRow(r1.hitlId)).decision, 'PENDING');
    const g1 = await view(L, r1.hitlId);
    assert.equal(g1.status, 200, JSON.stringify(g1.body));
    assert.equal(g1.body.request.viewer_can_decide, false, 'A15: viewer_can_decide false on R1');

    const r2 = await makeCriticalRequest(A);
    open.push(r2.hitlId);
    expectAwaiting(await decide(L, r2.hitlId, 'APPROVED'), r2.hitlId, 1, 'A15 R2');
    assert.deepEqual(await approvers(r2.hitlId), [uid(L)]);
  } finally {
    await revokeL('A15 revoke L approver grants');
    await rejectOpen(open);
  }
});

test('A16 (DA-4): a grant made by the invoker does not qualify on the invoker\'s request; it qualifies on another invoker\'s', async () => {
  await startWithoutLGrants();
  const open = [];
  try {
    await grantL(FLAGSHIP, uid(A), 'A16 grant L by A');
    const ra = await makeCriticalRequest(A);
    open.push(ra.hitlId);
    for (const d of ['APPROVED', 'REJECTED']) {
      await expectRefusal(await decide(L, ra.hitlId, d), { status: 403, code: 'NOT_AUTHORISED', who: L, hitlId: ra.hitlId, decision: d, label: `A16 A's request ${d}` });
    }
    assert.deepEqual(await approvers(ra.hitlId), []);
    const rb = await makeCriticalRequest(B);
    open.push(rb.hitlId);
    expectAwaiting(await decide(L, rb.hitlId, 'APPROVED'), rb.hitlId, 1, "A16 B's request");
  } finally {
    await revokeL('A16 revoke L approver grants');
    await rejectOpen(open);
  }
});

test('A17 (DA-4): a grant made by a co-approver, both orders', async () => {
  await startWithoutLGrants();
  const open = [];
  try {
    const marcus = await signIn(C);
    const g = await rpc('fao_admin_set_role', { p_user_id: uid(L), p_role: 'approver', p_agent_id: FLAGSHIP, p_grant: 'true', p_reason: `${TAG} A17 C grants L` }, { token: marcus });
    assert.equal(g.status, 200, `grant: ${g.status} ${g.body && g.body.code}`);
    assert.equal(g.body.ok, true);
    assert.equal(g.body.after.granted_by, uid(C), 'the RPC records granted_by C');
    const r1 = await makeCriticalRequest(A);
    open.push(r1.hitlId);
    const r2 = await makeCriticalRequest(A);
    open.push(r2.hitlId);

    // R1, approver first: L counts until C approves, then stops counting.
    expectAwaiting(await decide(L, r1.hitlId, 'APPROVED'), r1.hitlId, 1, 'A17 R1 L');
    expectAwaiting(await decide(C, r1.hitlId, 'APPROVED'), r1.hitlId, 1, 'A17 R1 C (L stops counting)');
    await expectRefusal(await decide(L, r1.hitlId, 'APPROVED'), { status: 403, code: 'NOT_AUTHORISED', who: L, hitlId: r1.hitlId, decision: 'APPROVED', label: 'A17 R1 L again' });
    expectDecided(await decide(B, r1.hitlId, 'APPROVED'), r1.hitlId, 'APPROVED', 'A17 R1 B');
    const res1 = (await eventRows(r1.corr, 'HITL_RESOLVED'))[0];
    assert.deepEqual(res1.inputs.approvers, [uid(C), uid(B)], 'A17 R1: HITL_RESOLVED approvers [C, B]');

    // R2, granter first: L may not approve, but may reject.
    expectAwaiting(await decide(C, r2.hitlId, 'APPROVED'), r2.hitlId, 1, 'A17 R2 C');
    await expectRefusal(await decide(L, r2.hitlId, 'APPROVED'), { status: 403, code: 'NOT_AUTHORISED', who: L, hitlId: r2.hitlId, decision: 'APPROVED', label: 'A17 R2 L approve' });
    assert.deepEqual(await approvers(r2.hitlId), [uid(C)], 'A17 R2: no approval row for L');
    const v = await view(L, r2.hitlId);
    assert.equal(v.status, 200, JSON.stringify(v.body));
    assert.equal(v.body.request.viewer_can_decide, true, 'A17 R2: L may still reject');
    expectDecided(await decide(L, r2.hitlId, 'REJECTED', { notes: `${TAG} A17 R2 rejection by L` }), r2.hitlId, 'REJECTED', 'A17 R2 L reject');
    const row2 = await requestRow(r2.hitlId);
    assert.equal(row2.decision, 'REJECTED');
    assert.equal(row2.approver_id, uid(L));
  } finally {
    await revokeL('A17 revoke L approver grants');
    await rejectOpen(open);
  }
});

test('A18 (DA-4): one disqualified grant (made by the invoker) and one qualifying grant: L\'s approval counts', async () => {
  await startWithoutLGrants();
  const open = [];
  try {
    await grantL(null, uid(A), 'A18 global grant by A');
    await grantL(FLAGSHIP, null, 'A18 flagship grant, granted_by NULL');
    const r = await makeCriticalRequest(A);
    open.push(r.hitlId);
    expectAwaiting(await decide(L, r.hitlId, 'APPROVED'), r.hitlId, 1, 'A18 L');
    expectDecided(await decide(C, r.hitlId, 'APPROVED'), r.hitlId, 'APPROVED', 'A18 C');
    const res = (await eventRows(r.corr, 'HITL_RESOLVED'))[0];
    assert.deepEqual(res.inputs.approvers, [uid(L), uid(C)], 'A18: HITL_RESOLVED approvers [L, C]');
  } finally {
    await revokeL('A18 revoke L approver grants');
    await rejectOpen(open);
  }
});
