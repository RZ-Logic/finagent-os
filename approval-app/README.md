# `approval-app/`: FinAgent OS approval page

A static page where an approver reviews one HITL request and approves or rejects it (FAO-GOV-004). The approver signs in with their own email and password; the page then calls two database functions through PostgREST with that person's own session:

- `fao_hitl_get(p_hitl_id)` to show the request,
- `fao_hitl_decide(p_hitl_id, p_decision, p_notes)` to record the decision.

The page holds no authority of its own. The database takes the approver's identity from the session, refuses a decision on a run the person started (`SOD_SELF_APPROVAL`), refuses decisions after the deadline, and journals every refusal. There is no n8n step and no service key in the decision path.

## Files

| File | Purpose |
|---|---|
| `index.html` | Static markup. Loads `config.js`, `vendor/supabase.js`, then `app.js` as a module. No inline script or style |
| `app.js` | ES module. Exports the pure functions `parseHitlId`, `statusMessage` and `buildViewModel` for the Node tests; the browser bootstrap runs only when `window.document` exists |
| `styles.css` | Minimal styles |
| `vendor/supabase.js`, `vendor/SHA256SUMS` | supabase-js UMD build copied from the exactly pinned devDependency by `npm run vendor` (`scripts/vendor-supabase-js.mjs`); `node scripts/vendor-supabase-js.mjs --check` verifies the hash. Currently `@supabase/supabase-js` 2.118.0 |
| `.gitattributes` | Keeps the vendored files byte for byte (no line-ending conversion), so the hash holds on every checkout |
| `config.example.js` | Template for `config.js` (`window.FAO_CONFIG = {supabaseUrl, supabasePublicKey}`). `config.js` itself is never committed: `scripts/local-setup.mjs` writes it locally, and it is written at deploy live |
| `_headers` | Cloudflare Pages security headers (CSP with `connect-src https://*.supabase.co`) |
| `serve.json` | The same headers for the local static server, with `connect-src http://127.0.0.1:54321` |

## How the page behaves

- The link is `<approval_app_base_url>/?hitl_id=<id>`. Anything other than exactly one `hitl_id` of 1 to 12 digits with a value of at least 1 shows `The request is not valid.` and makes no network call.
- With no session the page shows the sign-in form and no request data.
- Approve and Reject buttons appear only when `fao_hitl_get` reports `viewer_can_decide`. The invoker of the run sees the request and `You cannot decide a run you started.`
- Notes are optional, at most 2000 characters.
- Only fixed texts are shown: the messages of section 2.6 of the build spec, chosen by result code, plus a few page texts (sign-in failed, decision recorded). Database error text is never displayed. When a refusal was journaled, the page shows its reference id.
- Every DOM update uses `textContent`. Request fields (agent name, rationale and so on) are shown as plain text.
- The session lives in `sessionStorage` (closed with the tab); Sign out clears it.

## Local run

Prerequisite: the local Supabase stack is running and `npm run db:reset` has run (it writes `approval-app/config.js` pointing at `http://127.0.0.1:54321`).

```
npm run serve:approval        # same as: npx serve approval-app -l 4173 -c serve.json
```

Open `http://localhost:4173/?hitl_id=<id>`. `-c serve.json` is resolved inside `approval-app/`, so the local CSP and headers apply.

## Deploy (Cloudflare Pages)

1. Run `node scripts/vendor-supabase-js.mjs --check` and confirm it prints `OK`.
2. Create the Pages project from the `approval-app/` folder (no build command; output directory is the folder itself).
3. Add `config.js` at deploy with the live project URL and the publishable key only:
   `window.FAO_CONFIG = {supabaseUrl: 'https://<project-ref>.supabase.co', supabasePublicKey: '<publishable key>'};`
   Never a service or secret key.
4. Confirm the response headers of the deployed page match `_headers`.
5. Set the `approval_app_base_url` setting to the page's origin through the owner's SQL recipe with a change reason, so notification links point at it.

## Manual check (until the automated browser test ships)

Run once per release; record the results in the release run log.

1. `npm run serve:approval`.
2. Create a request with `node test/api/tools/make-request.mjs` (prints the approval URL).
3. Open the URL with no session: the fixed sign-in message, no request data.
4. Sign in as Aisha (the invoker): no buttons; the page says she cannot decide her own run.
5. Sign out, sign in as Sarah, approve with a note: the result view shows the decision and `Committed: Yes`.
6. Reload: the page shows that the request has already been decided.
7. Open `?hitl_id=abc`: the fixed invalid message, and no RPC call in the network panel.
8. The browser console shows no CSP violation.
