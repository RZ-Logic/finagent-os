// ============================================================================
// FinAgent OS e2e: start a fresh n8n instance's execution ids above a floor
// ----------------------------------------------------------------------------
// Run inside the one-shot import container, after the n8n CLI has created the
// SQLite schema:  node /e2e/n8n-exec-seq.cjs <floor>
//
// Why: n8n numbers executions 1, 2, 3 ... per instance, and the database
// keeps run_invocations.n8n_execution_id UNIQUE across all time. A fresh e2e
// instance would reuse ids an earlier instance already claimed runs with, so
// fao_run_claim refuses the new run ALREADY_CLAIMED (409). The harness reads
// the highest numeric id on record and starts this instance above it. This is
// a test workaround for the finding recorded in test/e2e/README.md, not a fix.
// ============================================================================
'use strict';

const sqlite3 = require('/usr/local/lib/node_modules/n8n/node_modules/sqlite3');

const floor = Number(process.argv[2]);
if (!Number.isSafeInteger(floor) || floor < 1 || floor > 2000000000) {
  process.stderr.write('n8n-exec-seq: floor must be an integer from 1 to 2000000000\n');
  process.exit(2);
}
const db = new sqlite3.Database('/home/node/.n8n/database.sqlite');
const run = (sql, p = []) => new Promise((resolve, reject) => db.run(sql, p, function done(e) { return e ? reject(e) : resolve(this.changes); }));
const get = (sql, p = []) => new Promise((resolve, reject) => db.get(sql, p, (e, row) => (e ? reject(e) : resolve(row))));

(async () => {
  const rows = await get('SELECT count(*) AS n FROM execution_entity');
  if (rows.n !== 0) throw new Error(`instance already has ${rows.n} executions`);
  const changed = await run("UPDATE sqlite_sequence SET seq = ? WHERE name = 'execution_entity'", [floor]);
  if (changed === 0) await run("INSERT INTO sqlite_sequence (name, seq) VALUES ('execution_entity', ?)", [floor]);
  const check = await get("SELECT seq FROM sqlite_sequence WHERE name = 'execution_entity'");
  process.stdout.write(`n8n-exec-seq: execution ids start after ${check.seq}\n`);
  db.close();
})().catch((e) => {
  process.stderr.write(`n8n-exec-seq: ${e.message}\n`);
  process.exit(1);
});
