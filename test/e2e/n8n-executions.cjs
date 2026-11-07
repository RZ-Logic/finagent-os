// ============================================================================
// FinAgent OS e2e: read n8n executions from inside the e2e container
// ----------------------------------------------------------------------------
// Run with: docker exec finagent-e2e-n8n node /e2e/n8n-executions.cjs [after]
// Prints one JSON array: every execution with id greater than `after`
// (default 0): id, workflowId, mode, status, startedAt, stoppedAt, and for a
// failed execution the error message and node. Reads n8n's own SQLite file
// read-only with the sqlite3 and flatted modules n8n ships; writes nothing.
// ============================================================================
'use strict';

const base = '/usr/local/lib/node_modules/n8n/node_modules/';
const sqlite3 = require(`${base}sqlite3`);
let flatted = null;
try { flatted = require(`${base}flatted`); } catch { flatted = null; }

const after = Number(process.argv[2] || 0);
const db = new sqlite3.Database('/home/node/.n8n/database.sqlite', sqlite3.OPEN_READONLY);

function all(sql, params) {
  return new Promise((resolve, reject) => db.all(sql, params, (e, rows) => (e ? reject(e) : resolve(rows))));
}

function summarise(raw) {
  if (!raw || !flatted) return {};
  let d;
  try { d = flatted.parse(raw); } catch { return { parse_error: true }; }
  const rd = (d && d.resultData) || {};
  const out = { lastNodeExecuted: rd.lastNodeExecuted || null };
  if (rd.error) {
    out.error = {
      message: rd.error.message || null,
      description: rd.error.description || null,
      node: rd.error.node && rd.error.node.name ? rd.error.node.name : null,
    };
  }
  const runData = rd.runData || {};
  out.nodes = Object.keys(runData);
  const nodeErrors = [];
  for (const [name, runs] of Object.entries(runData)) {
    for (const r of runs || []) {
      if (r && r.error) nodeErrors.push({ node: name, message: r.error.message || null });
    }
  }
  if (nodeErrors.length) out.nodeErrors = nodeErrors;
  return out;
}

(async () => {
  const rows = await all(
    `SELECT e.id, e.workflowId, e.mode, e.status, e.finished, e.startedAt, e.stoppedAt, d.data
       FROM execution_entity e LEFT JOIN execution_data d ON d.executionId = e.id
      WHERE e.id > ? ORDER BY e.id`,
    [after],
  );
  const out = rows.map((r) => ({
    id: String(r.id),
    workflowId: r.workflowId,
    mode: r.mode,
    status: r.status,
    finished: !!r.finished,
    startedAt: r.startedAt,
    stoppedAt: r.stoppedAt,
    ...summarise(r.data),
  }));
  process.stdout.write(JSON.stringify(out));
  db.close();
})().catch((e) => {
  process.stderr.write(`n8n-executions: ${e.message}\n`);
  process.exit(1);
});
