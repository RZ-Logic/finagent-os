#!/usr/bin/env node
// ============================================================================
// FinAgent OS - create one pending approval request on the local stack
// ----------------------------------------------------------------------------
// Controls exercised: FAO-GOV-008 (run start as Aisha with her own session,
// claim and append as fao_workflow), FAO-GOV-004 (request opened by
// fao_run_finalize). For the manual check of the approval page (build spec
// 6.8). Local only: test/api/lib.mjs refuses any non-local URL.
// Default: the flagship run (seven assets; SOL and ADA REQUIRE_HUMAN
// CRITICAL), so the request is CRITICAL. --standard: makeRequest from
// test/api/lib.mjs (one USDT REQUIRE_HUMAN STANDARD asset, enforced_approvals 1).
// Usage: node test/api/tools/make-request.mjs [--standard] [invoker key, default aisha]
// ============================================================================

import { makeRun, append, finalize, flagshipEvents, makeRequest, closeAll } from '../lib.mjs';

const args = process.argv.slice(2);
const standard = args.includes('--standard');
const invoker = args.find((a) => !a.startsWith('--')) || 'aisha';
try {
  if (standard) {
    const r = await makeRequest(invoker);
    console.log(`hitl_id      ${r.hitlId}`);
    console.log(`invoker      ${invoker}`);
    console.log('kind         standard');
    console.log(`approval URL ${r.approvalUrl}`);
  } else {
    const { assets } = flagshipEvents('00000000-0000-4000-8000-000000000000');
    const corr = await makeRun(invoker, assets);
    await append(flagshipEvents(corr).events);
    const f = await finalize(corr);
    if (!f.hitl_required) throw new Error(`finalize did not open a request (state ${f.state})`);
    console.log(`hitl_id      ${f.hitl_id}`);
    console.log(`invoker      ${invoker}`);
    console.log('kind         flagship');
    // The request's sub_tier is the finalize review_sub_tier, STANDARD when null (0018 create_request).
    console.log(`sub_tier     ${f.review_sub_tier ?? 'STANDARD'}`);
    console.log(`approval URL ${f.approval_url}`);
  }
} catch (err) {
  console.error(`make-request: ${err.message}`);
  process.exitCode = 1;
} finally {
  await closeAll();
}
