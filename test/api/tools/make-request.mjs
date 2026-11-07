#!/usr/bin/env node
// ============================================================================
// FinAgent OS - create one pending approval request on the local stack
// ----------------------------------------------------------------------------
// Controls exercised: FAO-GOV-008 (run start as Aisha with her own session,
// claim and append as fao_workflow), FAO-GOV-004 (request opened by
// fao_run_finalize). For the manual check of the approval page (build spec
// 6.8). Local only: test/api/lib.mjs refuses any non-local URL.
// Usage: node test/api/tools/make-request.mjs [invoker key, default aisha]
// ============================================================================

import { makeRun, append, finalize, flagshipEvents, closeAll } from '../lib.mjs';

const invoker = process.argv[2] || 'aisha';
try {
  const { assets } = flagshipEvents('00000000-0000-4000-8000-000000000000');
  const corr = await makeRun(invoker, assets);
  await append(flagshipEvents(corr).events);
  const f = await finalize(corr);
  if (!f.hitl_required) throw new Error(`finalize did not open a request (state ${f.state})`);
  console.log(`hitl_id      ${f.hitl_id}`);
  console.log(`invoker      ${invoker}`);
  console.log(`approval URL ${f.approval_url}`);
} catch (err) {
  console.error(`make-request: ${err.message}`);
  process.exitCode = 1;
} finally {
  await closeAll();
}
