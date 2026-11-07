// ============================================================================
// FinAgent OS API tests: the GraphQL endpoint exposes no private helper
// Controls: FAO-GOV-015 (fao_private and the local schema tests are never
// reachable through an API), FAO-GOV-004 (no signed-in user can ask
// fao_private.has_role or has_any_role about another user's roles).
//
// pg_graphql reflects only schemas on the request search_path that the
// calling role may use. PostgREST builds that path from the request profile
// (graphql_public) and [api] extra_search_path. Hosted projects run pg_graphql;
// the local stack does not enable it, so the reflection test enables it,
// with introspection switched on for every schema, inside a transaction that
// is always rolled back.
// ============================================================================

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { http, signIn, uid, owner, q, closeAll } from './lib.mjs';
import { configToml } from '../../scripts/stage-local-supabase.mjs';

after(closeAll);

const PRIVATE_SCHEMAS = ['fao_private', 'tests'];
// IC-18: client RPCs take one unnamed json body, which pg_graphql does not
// reflect, so none of these names may appear; a control function with a
// named argument, created in the rolled-back transaction, shows that
// introspection works.
const CLIENT_RPCS = [
  'fao_whoami', 'fao_run_start', 'fao_hitl_get', 'fao_hitl_decide', 'fao_ledger_correct',
  'fao_admin_set_threshold', 'fao_admin_set_agent', 'fao_admin_set_role', 'fao_admin_set_owner_active',
];
const CONTROL_FN = 'zz_graphql_control';
const INTROSPECTION = '{ __schema { queryType { name } mutationType { name } types { name fields { name } } } }';

// The request search_path PostgREST uses for /graphql/v1, from the staged
// config: the graphql_public profile, then [api] extra_search_path.
function requestSearchPath() {
  const m = /^extra_search_path\s*=\s*\[([^\]]*)\]/m.exec(configToml(17));
  assert.ok(m, 'staged config.toml has [api] extra_search_path');
  const extra = m[1].split(',').map((s) => s.trim().replace(/^"|"$/g, '')).filter(Boolean);
  for (const s of PRIVATE_SCHEMAS) assert.ok(!extra.includes(s), `extra_search_path does not include ${s}`);
  return ['graphql_public', ...extra];
}

// Names of every function and relation in fao_private and tests.
async function privateNames() {
  const fns = await q(
    `SELECT DISTINCT p.proname::text AS n FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace s ON s.oid = p.pronamespace
      WHERE s.nspname = ANY($1)`, [PRIVATE_SCHEMAS]);
  const rels = await q(
    `SELECT DISTINCT c.relname::text AS n FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace s ON s.oid = c.relnamespace
      WHERE s.nspname = ANY($1) AND c.relkind IN ('r', 'v', 'm', 'p', 'f')`, [PRIVATE_SCHEMAS]);
  const functions = new Set(fns.map((r) => r.n));
  assert.ok(functions.has('has_role') && functions.has('has_any_role'), 'fao_private helpers found in the catalog');
  assert.ok(functions.has('do_as') && functions.has('as_owner'), 'schema tests helpers found in the catalog');
  return { functions, relations: rels.map((r) => r.n) };
}

// Every type and field name in an introspection result.
function schemaNames(body) {
  const s = body && body.data && body.data.__schema;
  if (!s) return null;
  const names = [];
  for (const t of s.types || []) {
    names.push(t.name);
    for (const f of t.fields || []) names.push(f.name);
  }
  return names;
}

function leaked(names, priv) {
  return names.filter((n) => priv.functions.has(n) || priv.relations.some((r) => n.includes(r)));
}

test('/graphql/v1 introspection and direct helper calls as anon and as Outsider reach no fao_private or tests field', async (t) => {
  const priv = await privateNames();
  const outsider = await signIn('outsider');
  const callers = [['anon', undefined], ['outsider', outsider]];
  for (const [label, token] of callers) {
    const r = await http('POST', '/graphql/v1', { token, body: { query: INTROSPECTION } });
    assert.ok(r.status < 500, `${label}: status ${r.status}`);
    const names = schemaNames(r.body);
    if (names === null) {
      // Local stack: pg_graphql is not enabled, or introspection is off.
      assert.ok(r.body && Array.isArray(r.body.errors) && r.body.errors.length > 0, `${label}: no schema means an error body`);
      t.diagnostic(`${label}: /graphql/v1 returned no schema (${r.body.errors[0].message})`);
    } else {
      assert.deepEqual(leaked(names, priv), [], `${label}: introspection lists no private name`);
    }
    for (const s of PRIVATE_SCHEMAS) assert.ok(!r.text.includes(`"${s}`), `${label}: response does not name schema ${s}`);

    const calls = [
      `{ has_any_role(p_uid: "${uid('sarah')}") }`,
      `{ has_role(p_uid: "${uid('sarah')}", p_role: "approver", p_agent_id: null) }`,
      'mutation { do_as(p_who: "service_role", p_sql: "SELECT 1") }',
      'mutation { as_owner }',
      '{ uid(p_email: "sarah.chen@finagent-os.demo") }',
    ];
    for (const query of calls) {
      const c = await http('POST', '/graphql/v1', { token, body: { query } });
      assert.ok(c.status < 500, `${label}: ${query}: status ${c.status}`);
      assert.ok(!(c.body && c.body.data), `${label}: ${query}: no data returned`);
      assert.ok(c.body && Array.isArray(c.body.errors) && c.body.errors.length > 0, `${label}: ${query}: refused with an error`);
      assert.ok(!/"(true|false)"|: ?(true|false)\b/.test(JSON.stringify(c.body.errors)), `${label}: ${query}: no role answer in the error`);
    }
  }
});

test('pg_graphql (enabled, introspection on, in a rolled-back transaction) reflects no fao_private or tests entity for anon or Outsider', async () => {
  const priv = await privateNames();
  const path = requestSearchPath();
  const client = await owner().connect();
  const resolve = async (query) => JSON.parse((await client.query('SELECT graphql.resolve($1)::text AS r', [query])).rows[0].r);
  const asAnon = async () => {
    await client.query('SET LOCAL ROLE anon');
    await client.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify({ role: 'anon' })]);
  };
  const asOutsider = async () => {
    await client.query('SET LOCAL ROLE authenticated');
    await client.query("SELECT set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: uid('outsider'), role: 'authenticated', aal: 'aal1' })]);
    await client.query("SELECT set_config('request.jwt.claim.sub', $1, true)", [uid('outsider')]);
  };
  const asOwner = async () => {
    await client.query('RESET ROLE');
    await client.query("SELECT set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true)");
  };
  try {
    await client.query('BEGIN');
    const avail = await client.query("SELECT 1 FROM pg_catalog.pg_available_extensions WHERE name = 'pg_graphql'");
    assert.equal(avail.rowCount, 1, 'pg_graphql is available on the local image');
    await client.query('CREATE EXTENSION IF NOT EXISTS pg_graphql');
    for (const s of ['public', ...PRIVATE_SCHEMAS]) {
      await client.query(`COMMENT ON SCHEMA ${s} IS e'@graphql({"introspection": true})'`);
    }
    await client.query(`CREATE FUNCTION public.${CONTROL_FN}(p_x text) RETURNS text LANGUAGE sql VOLATILE AS $$ SELECT p_x $$`);
    await client.query(`GRANT EXECUTE ON FUNCTION public.${CONTROL_FN}(text) TO anon, authenticated`);
    await client.query(`SET LOCAL search_path = ${path.map((s) => `"${s}"`).join(', ')}`);

    for (const [label, become, control] of [['anon', asAnon, CONTROL_FN], ['outsider', asOutsider, CONTROL_FN]]) {
      await become();
      const body = await resolve(INTROSPECTION);
      const names = schemaNames(body);
      assert.ok(names, `${label}: introspection answered (${JSON.stringify(body.errors || null)})`);
      assert.ok(names.includes(control), `${label}: control field ${control} is reflected, so introspection works`);
      assert.deepEqual(leaked(names, priv), [], `${label}: no fao_private or tests name is reflected`);
      assert.deepEqual(CLIENT_RPCS.filter((n) => names.some((x) => x === n || x.includes(n))), [], `${label}: no client RPC is reflected (IC-18)`);
      for (const query of [`{ has_any_role(p_uid: "${uid('sarah')}") }`, 'mutation { do_as(p_who: "service_role", p_sql: "SELECT 1") }']) {
        const r = await resolve(query);
        assert.equal(r.data ?? null, null, `${label}: ${query}: no data`);
        assert.match(String(r.errors && r.errors[0] && r.errors[0].message), /Unknown field/, `${label}: ${query}: unknown field`);
      }
      await asOwner();
    }

    // Detector control: with the private schemas on the path, the same check
    // does find them, so an empty result above is not a blind check.
    await client.query(`SET LOCAL search_path = ${[...path, ...PRIVATE_SCHEMAS].map((s) => `"${s}"`).join(', ')}`);
    await asOutsider();
    const widened = schemaNames(await resolve(INTROSPECTION));
    assert.ok(widened && leaked(widened, priv).includes('has_any_role'), 'control: a widened search_path would reflect fao_private.has_any_role');
    await asOwner();
  } finally {
    await client.query('ROLLBACK').catch(() => {});
    client.release();
  }
});
