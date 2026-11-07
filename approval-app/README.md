# `approval-app/`: FinAgent OS approval page

A static page where an approver reviews one HITL request and approves or rejects it (FAO-GOV-004). The approver signs in with their own email and password; the page then calls two database functions through PostgREST (POST with a JSON body) with that person's own session:

- `fao_hitl_get` with the body `{p_hitl_id}` to show the request,
- `fao_hitl_decide` with the body `{p_hitl_id, p_decision, p_notes}` to record the decision (`p_notes` is null when the note is empty).

Each client function takes that one JSON body and validates it in the database (FAO-GOV-008, IC-18): a missing required key, an extra key, a value that is not a JSON string or null, or a `\u0000` escape is refused as `INVALID_INPUT` and journaled.

The page holds no authority of its own. The database takes the approver's identity from the session, refuses a decision on a run the person started (`SOD_SELF_APPROVAL`), refuses decisions after the deadline, and journals every refusal. There is no n8n step and no service key in the decision path.

**Status:** built and unit-tested on the branch `phase2-5-core-2026-11-07`; not deployed. Live still uses the v1 n8n approval endpoints until the cutover. The page has not yet been checked end to end in a real browser against the local stack (the manual check below); there is no automated browser test.

## Files

| File | Purpose |
|---|---|
| `index.html` | Static markup. Loads `config.js`, `vendor/supabase.js`, then `app.js` as a module. No inline script or style |
| `app.js` | ES module. Exports the fixed texts (`CODE_MESSAGES`, `FALLBACK_MESSAGES`, `PAGE_TEXT`) and the pure functions (`parseHitlId`, `statusMessage`, `buildViewModel` and small helpers) for the Node tests; the browser bootstrap runs only when `window.document` exists |
| `styles.css` | Minimal styles |
| `favicon.svg` | Page icon, served from the page's own origin (CSP `img-src 'self'`) |
| `vendor/supabase.js`, `vendor/SHA256SUMS` | supabase-js UMD build copied from the exactly pinned devDependency by `npm run vendor` (`scripts/vendor-supabase-js.mjs`); `node scripts/vendor-supabase-js.mjs --check` verifies the hash. Currently `@supabase/supabase-js` 2.118.0 |
| `.gitattributes` | Keeps the vendored files byte for byte (no line-ending conversion), so the hash holds on every checkout |
| `config.example.js` | Template for `config.js` (`window.FAO_CONFIG = {supabaseUrl, supabasePublicKey}`). `config.js` itself is never committed: `scripts/local-setup.mjs` writes it locally, and it is written at deploy live |
| `_headers` | Cloudflare Pages security headers (CSP with `connect-src https://*.supabase.co`) |
| `serve.json` | The same headers for the local static server, with `connect-src http://127.0.0.1:54321`, plus redirects so the local server does not return `README.md`, `serve.json`, `config.example.js`, `vendor/SHA256SUMS`, `.gitattributes` or `_headers` |

## How the page behaves

- The link is `<approval_app_base_url>/?hitl_id=<id>`. Anything other than exactly one `hitl_id` of 1 to 12 digits with a value of at least 1 shows `The request is not valid.` and makes no network call.
- With no session the page shows the sign-in form and no request data.
- The request view shows the risk tier, review sub-tier, rationale, escalated assets, deadline, who started the run, and both approval counts (`Configured approvals` from the registry, `Enforced approvals`, which is 1 until dual approval is built).
- Approve and Reject buttons appear only when `fao_hitl_get` reports `viewer_can_decide`. The invoker of the run sees the request and `You cannot decide a run you started.`
- Notes are optional, at most 2000 characters, counted like the database (Unicode characters, so an emoji counts once). A longer note is refused on the page with no call, and the note is kept.
- A refused decision that can be retried (`INVALID_INPUT`, `BUSY`, a network or server failure) keeps the request, the form and the typed note on screen; other results replace the form.
- Sign-out, and every sign-in, clear the draft note, the email field, the request fields, the asset list and the result, so nothing carries over to the next person in the same tab.
- An approval recorded when the agent is no longer ACTIVE is never committed (`fao_hitl_decide` returns `AGENT_NOT_ACTIVE` with the decision fields). The page shows the result view with `Decision recorded. The run was not committed because the agent is no longer active.`, the decision, the time it was recorded and `Committed: No`, plus the reference id.
- An approval recorded when the run's invoker is no longer active or no longer holds the invoker grant for the agent is never committed either (`fao_hitl_decide` returns `INVOKER_NOT_ACTIVE` with the same decision fields; the agent check comes first). The page shows `Decision recorded. The run was not committed because the invoker is no longer authorised for this agent.`, the decision, its time and `Committed: No`, plus the reference id.
- Reloading a decided request reads `committed` and `commit_blocked_reason` from the top level of the `fao_hitl_get` envelope. When the approval was blocked, the page shows the same not-committed text for the reason (`AGENT_NOT_ACTIVE` or `INVOKER_NOT_ACTIVE`); an approval not committed for a reason the database does not name shows `Decision recorded. The run was not committed.`; a committed approval or a rejection keeps `This request has already been decided.` The closed view adds a `Committed` row whenever `committed` is a boolean. A reason outside the closed set is never shown.
- After each view change, focus moves to the status line, which is also announced (`aria-live`).
- Only fixed texts are shown: the messages of section 2.6 of the build spec, chosen by result code, plus a few page texts (sign-in failed, decision recorded, decision recorded but not committed). Database error text is never displayed. When a refusal was journaled, the page shows its reference id.
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
2. Build the upload folder from the allow-list below, and nothing else. Do not point Pages at `approval-app/` itself: that would publish `README.md`, `serve.json`, `config.example.js`, `vendor/SHA256SUMS` and `.gitattributes` too.

   | Published file | Source |
   |---|---|
   | `index.html`, `app.js`, `styles.css`, `favicon.svg` | `approval-app/` |
   | `vendor/supabase.js` | `approval-app/vendor/` |
   | `_headers` | `approval-app/` (Pages reads it and does not serve it) |
   | `config.js` | written for the deploy (step 3) |

   For example, from the repository root (bash): `rm -rf .local/approval-deploy && mkdir -p .local/approval-deploy/vendor && cp approval-app/{index.html,app.js,styles.css,favicon.svg,_headers} .local/approval-deploy/ && cp approval-app/vendor/supabase.js .local/approval-deploy/vendor/`
3. Write `config.js` into that folder with the live project URL and the publishable key only:
   `window.FAO_CONFIG = {supabaseUrl: 'https://<project-ref>.supabase.co', supabasePublicKey: '<publishable key>'};`
   Never a service or secret key.
4. Upload that folder as the Pages project's output (direct upload, for example `npx wrangler pages deploy .local/approval-deploy`; no build command). Confirm the response headers of the deployed page match `_headers`, and that `/README.md`, `/serve.json`, `/config.example.js` and `/vendor/SHA256SUMS` do not return those files.
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
8. The browser console shows no CSP violation and no 404 (the favicon loads).
9. Type a note as Sarah, sign out, sign in as Marcus in the same tab: the note box is empty.
