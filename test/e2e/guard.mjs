// ============================================================================
// FinAgent OS e2e: local-only guard
// ----------------------------------------------------------------------------
// Every URL or host the e2e layer would use must be loopback (localhost,
// 127.0.0.1, ::1), host.docker.internal, or the name of a container on the
// local Supabase docker network. Anything else stops the run before a single
// request is sent. Used by scripts/e2e-n8n.mjs and by every e2e test.
// ============================================================================

import { spawnSync } from 'node:child_process';

export const NETWORK = 'supabase_network_finagent-os-local';
export const DB_CONTAINER = 'supabase_db_finagent-os-local';
export const N8N_CONTAINER = 'finagent-e2e-n8n';
export const SLACK_CONTAINER = 'finagent-e2e-slack';
// Round 5 (S17 to S19): the local Supabase API gateway as the harnesses reach
// it from inside the n8n container (docker network name, port 8000).
export const KONG_CONTAINER = 'supabase_kong_finagent-os-local';
export const LOOPBACK = new Set(['localhost', '127.0.0.1', '::1', '[::1]', 'host.docker.internal']);

let networkNames = null;
export function dockerNetworkNames() {
  if (networkNames) return networkNames;
  const r = spawnSync('docker', ['network', 'inspect', NETWORK, '--format', '{{range .Containers}}{{.Name}} {{end}}'], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`e2e guard: docker network ${NETWORK} not found; start the local Supabase stack first`);
  networkNames = new Set(r.stdout.trim().split(/\s+/).filter(Boolean));
  return networkNames;
}

export function hostAllowed(host) {
  const h = String(host || '').toLowerCase();
  if (LOOPBACK.has(h)) return true;
  if (h === N8N_CONTAINER || h === SLACK_CONTAINER) return true;
  return dockerNetworkNames().has(h);
}

// Throws unless every entry is allowed. Entries are [label, urlOrHost].
export function assertLocalTargets(entries) {
  const bad = [];
  for (const [label, value] of entries) {
    let host;
    try {
      host = /^[a-z][a-z0-9+.-]*:\/\//i.test(String(value)) ? new URL(value).hostname : String(value);
    } catch {
      bad.push(`${label} (unparseable)`);
      continue;
    }
    if (!hostAllowed(host)) bad.push(`${label} -> ${host}`);
  }
  if (bad.length) throw new Error(`e2e guard: refusing to run, non-local target(s): ${bad.join(', ')}`);
}

// The same environment check test-all runs: no hosted URL in the environment.
export function assertLocalEnv(env = process.env) {
  const entries = [];
  for (const [k, v] of Object.entries(env)) {
    if (!v) continue;
    if (k === 'SUPABASE_URL' || /^N8N_.*URL$/.test(k) || /^FAO_.*_URL$/.test(k)) entries.push([`env ${k}`, v]);
  }
  assertLocalTargets(entries);
}
