// ============================================================================
// FinAgent OS e2e: fake Slack Web API (local only, never live)
// ----------------------------------------------------------------------------
// Runs as a sidecar container that shares the n8n container's network
// namespace (docker run --network container:finagent-e2e-n8n), so the local
// setting slack_api_base_url = http://127.0.0.1:8099/api resolves to this
// server from inside n8n without changing any database row.
//
//   POST /api/chat.postMessage   records the request; answers by mode
//   GET  /_e2e/requests          every recorded request, oldest first
//   POST /_e2e/mode              {"mode": "ok" | "http_500" | "ok_false"}
//   POST /_e2e/reset             clears the record and sets mode "ok"
//   GET  /_e2e/health            {"ok": true}
//
// Modes: ok answers 200 {ok:true, ts}; http_500 answers 500 {ok:false,
// error:"e2e_forced_failure"}; ok_false answers 200 {ok:false,
// error:"e2e_channel_not_found"}. Nothing is forwarded anywhere.
// ============================================================================

import { createServer } from 'node:http';

const PORT = Number(process.env.FAKE_SLACK_PORT || 8099);
const MODES = new Set(['ok', 'http_500', 'ok_false']);
let mode = 'ok';
let seq = 0;
let requests = [];

function send(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 1024 * 1024) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  let raw = '';
  try { raw = await readBody(req); } catch { send(res, 413, { ok: false }); return; }
  const url = new URL(req.url, 'http://fake-slack.local');

  if (req.method === 'POST' && url.pathname === '/api/chat.postMessage') {
    seq += 1;
    let json = null;
    try { json = raw ? JSON.parse(raw) : null; } catch { json = null; }
    const entry = {
      seq,
      at: new Date().toISOString(),
      mode,
      method: req.method,
      path: url.pathname,
      authorization: req.headers.authorization || null,
      content_type: req.headers['content-type'] || null,
      raw,
      json,
    };
    requests.push(entry);
    if (mode === 'http_500') { send(res, 500, { ok: false, error: 'e2e_forced_failure' }); return; }
    if (mode === 'ok_false') { send(res, 200, { ok: false, error: 'e2e_channel_not_found' }); return; }
    send(res, 200, { ok: true, channel: json && json.channel, ts: `1700000000.${String(seq).padStart(6, '0')}` });
    return;
  }
  if (req.method === 'GET' && url.pathname === '/_e2e/requests') { send(res, 200, { mode, requests }); return; }
  if (req.method === 'GET' && url.pathname === '/_e2e/health') { send(res, 200, { ok: true, mode }); return; }
  if (req.method === 'POST' && url.pathname === '/_e2e/reset') { requests = []; mode = 'ok'; send(res, 200, { ok: true }); return; }
  if (req.method === 'POST' && url.pathname === '/_e2e/mode') {
    let m = null;
    try { m = JSON.parse(raw).mode; } catch { m = null; }
    if (!MODES.has(m)) { send(res, 400, { ok: false, error: 'unknown mode' }); return; }
    mode = m;
    send(res, 200, { ok: true, mode });
    return;
  }
  send(res, 404, { ok: false, error: 'not_found' });
});

server.listen(PORT, '0.0.0.0', () => {
  process.stdout.write(`fake-slack listening on ${PORT}\n`);
});
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => server.close(() => process.exit(0)));
