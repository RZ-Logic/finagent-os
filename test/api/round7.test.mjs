// ============================================================================
// FinAgent OS API tests: patch round 7 (O3, owner decision 2026-11-08)
// Controls: FAO-GOV-001 (the Writer appends; the database sets identity),
// FAO-GOV-004 (the invoker on STARTED is the run's, never the caller's).
//
// A STARTED event whose inputs carry invoker_id, invoked_via, reason or
// n8n_execution_id, at any depth and in any normalised spelling, is refused
// (SQLSTATE 22023, the Writer's invalid-input class) and nothing in the batch
// is written. Before round 7 the database overwrote the four top-level keys;
// it now refuses them and still sets all four itself on the stored row.
// Runs on the Writer path the n8n Writer uses: fao_ledger_append_batch as
// fao_workflow.
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { startRun, claim, append, finalize, startedEvent, assetEvent, one, q, uid, closeAll } from './lib.mjs';

after(closeAll);

const REASON = `api round7 O3 ${randomUUID().slice(0, 8)}`;

const ledgerCount = async (corr) => Number((await one(
  'SELECT count(*) AS n FROM public.shadow_ledger WHERE correlation_id = $1', [corr],
)).n);
const runRow = (corr) => one(
  'SELECT state::text AS state, invoker_id, invoked_via::text AS invoked_via, reason, n8n_execution_id FROM public.run_invocations WHERE correlation_id = $1',
  [corr],
);

async function expectRefused(batch, label) {
  let err = null;
  try {
    await append(batch);
  } catch (e) {
    err = e;
  }
  assert.ok(err, `${label}: the batch was accepted`);
  assert.equal(err.code, '22023', `${label}: ${err.code} ${err.message}`);
  // The refusal names the inputs key path (today: "inputs.<key> is set only by the database").
  assert.match(err.message, /^FAO-GOV-001 ledger_append: item 0: inputs\./, `${label}: ${err.message}`);
}

test('O3: a STARTED event carrying invoker_id, invoked_via, reason or n8n_execution_id is refused and writes nothing; the database still sets all four', async () => {
  const s = await startRun('aisha', { reason: REASON });
  assert.equal(s.status, 200, JSON.stringify(s.body));
  const corr = s.body.correlation_id;
  const execId = `api-r7-${randomUUID().slice(0, 12)}`;
  const c = await claim(s.body.run_token, execId);
  assert.equal(c.ok, true, `claim: ${c.code}`);
  const runBefore = await runRow(corr);
  assert.equal(runBefore.invoker_id, uid('aisha'));

  const assets = ['BTC'];
  const base = () => startedEvent(corr, assets);
  const withInputs = (extra) => {
    const e = base();
    e.inputs = { ...e.inputs, ...extra };
    return e;
  };
  const withProvenance = (prov) => {
    const e = base();
    e.inputs = { ...e.inputs, fixture_provenance: prov };
    return e;
  };

  const cases = [
    // The exact top-level spellings the database used to overwrite, with the
    // run's own values (a matching value is refused too) and with others.
    ['invoker_id (the run invoker)', withInputs({ invoker_id: uid('aisha') })],
    ['invoker_id (another owner)', withInputs({ invoker_id: uid('sarah') })],
    ['invoked_via', withInputs({ invoked_via: 'test' })],
    ['invoked_via (other channel)', withInputs({ invoked_via: 'mcp' })],
    ['reason', withInputs({ reason: REASON })],
    ['n8n_execution_id', withInputs({ n8n_execution_id: execId })],
    ['all four', withInputs({ invoker_id: uid('aisha'), invoked_via: 'test', reason: REASON, n8n_execution_id: execId })],
    // Normalised spellings (case fold, NFKC full-width letters).
    ['INVOKER_ID', withInputs({ INVOKER_ID: uid('sarah') })],
    ['Invoked_Via', withInputs({ Invoked_Via: 'test' })],
    ['full-width reason', withInputs({ 'ｒｅａｓｏｎ': REASON })],
    // Any depth, arrays included.
    ['nested in fixture_provenance', withProvenance({ BTC: { source: 'api', invoker_id: uid('sarah') } })],
    ['nested in an array', withInputs({ extra: [{ n8n_execution_id: execId }] })],
    ['nested object', withInputs({ meta: { reason: 'x' } })],
  ];
  for (const [label, ev] of cases) await expectRefused([ev], label);

  // All or none: a refused STARTED in a batch with a valid asset stores neither.
  await expectRefused([withInputs({ invoker_id: uid('aisha') }), assetEvent(corr, 'BTC')], 'batch with an asset');

  assert.equal(await ledgerCount(corr), 0, 'no ledger row for any refused batch');
  assert.deepEqual(await runRow(corr), runBefore, 'the run record is unchanged');

  // A clean STARTED is stored, and the database sets the four values itself.
  const a1 = await append([base()]);
  assert.equal(a1.count, 1);
  const st = await one(
    "SELECT inputs FROM public.shadow_ledger WHERE correlation_id = $1 AND inputs->>'event_type' = 'STARTED'", [corr],
  );
  assert.equal(st.inputs.invoker_id, uid('aisha'));
  assert.equal(st.inputs.invoked_via, runBefore.invoked_via);
  assert.equal(st.inputs.reason, REASON);
  assert.equal(st.inputs.n8n_execution_id, execId);

  // Close the run.
  const a2 = await append([assetEvent(corr, 'BTC')]);
  assert.equal(a2.count, 1);
  const f = await finalize(corr);
  assert.equal(f.hitl_required, false);
  assert.equal((await runRow(corr)).state, 'COMMITTED');
  assert.equal((await q("SELECT 1 FROM public.shadow_ledger WHERE correlation_id = $1 AND inputs->>'event_type' = 'STARTED'", [corr])).length, 1);
});
