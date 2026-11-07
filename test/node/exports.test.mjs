// ============================================================================
// FinAgent OS - workflow export rules (scripts/check-exports.mjs)
// Controls: FAO-GOV-001, FAO-GOV-004, FAO-GOV-007, FAO-GOV-008.
// ============================================================================

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkExports, RULES } from '../../scripts/check-exports.mjs';

test('check-exports reports zero violations', () => {
  const report = checkExports();
  assert.ok(report.total >= RULES.length * 7 + 1, `ran ${report.total} checks`);
  assert.deepEqual(report.violations, []);
  assert.equal(report.failed, 0);
});
