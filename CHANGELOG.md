# Changelog

Notable changes to the live FinAgent OS system, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Times are UTC.

## v2.0.0 (2026-11-09): November 2026 release, live

The November 2026 release, including dual approval ([ADR-0004](docs/adr/0004-dual-approval-enforced.md)), was deployed to the live stack at commit `c9c2fc0`. The cutover ran from 2026-11-08 17:45 to 2026-11-09 04:25, step by step, each step with its own check. During pre-flight the full test suite passed at `c9c2fc0` on PostgREST 14.5, the live version: 2313 of 2313, nothing skipped.

### Changed

- **Database (Supabase, ca-central-1).** Migrations 0009 to 0020 applied: 0009 on its own, then 0010 to 0020 in one transaction, committed 2026-11-08 19:43:45. The four v1 requests still PENDING were expired, each with a HITL_EXPIRED ledger event. The v1 `hitl_queue_sod_guard` trigger and `fao_hitl_create` are dropped; `fao_hitl_resolve` remains only as a stub that always raises. Decisions now go only through `fao_hitl_decide` with the approver's own session.
- **Workflow role.** `fao_workflow` can log in through the Session pooler; it cannot read `shadow_ledger` directly.
- **Auth.** New sign-ups and anonymous sign-ins are off; secure password change is on. The MCP reader user was created and the three demo users were given new passwords.
- **Seeds and settings.** Seeds 0007 (application roles) and 0008 (settings) applied. `approval_app_base_url` is `https://approve.velocyt.ca`. The flagship's stale-run limit (`sla_max_execution_seconds`) is 900. The USDC and USDT upper band is 1.0500, set by Marcus through `fao_admin_set_threshold` with a change reason; floor and lower band stay 1.0000. The flagship's `rollback_procedure` now describes a CORRECTION event, and its `sox_control_ids` are the 18 ids of seed 0003 (10 before).
- **Approval page.** Deployed on Cloudflare Pages at https://approve.velocyt.ca. Response headers match `_headers` and the CSP is enforced. Cloudflare Web Analytics injected a beacon the CSP blocked, so a zone Configuration Rule disables it for that host only.
- **n8n.** Upgraded from 2.44.5 to 2.46.6 (self-hosted at `n8n.velocyt.ca`). Three credentials added: `FAO Postgres (fao_workflow)` (Session pooler, SSL Require with certificate verification; the n8n host trusts the Supabase Root 2021 CA through `NODE_EXTRA_CA_CERTS`), `FAO Invoke Header Auth` and `FAO Slack Bot`. The five production workflows were imported with their ids and published in order: Writer, error handler, notifier, sweeper, flagship. The run-start webhook refuses a call without the right key (403).
- **MCP.** `mcp/.env` holds the reader user, the webhook URL and the invoke key, with no service or secret key. The invoker is left empty, so the invoke tool refuses with `NO_USER_CREDENTIAL` (see Known limits). Live check: 21 of 21 on the rerun (the first run's INSERT probe named a column the table does not have and failed with 400 before the privilege check; the probe was corrected).

### Removed

- The v1 n8n approval handler is archived; its webhooks return 404.
- `test_agent`, a v1 ledger-trigger test agent, is set to DEPRECATED with an audit row. It cannot be deleted because ledger row 1 references it and the ledger is append-only.
- The n8n backups on the droplet were deleted (they held the retired `postgres` password). The local Supabase backups from 2026-11-08 are kept outside the repo.

### Security

Retired credentials:

- The n8n "Postgres account" credential (the `postgres` superuser, with SSL checks off) is deleted; n8n's only Postgres credential is now `FAO Postgres (fao_workflow)`.
- The `postgres` database password was rotated by the owner.
- The legacy `anon` and `service_role` API keys are disabled.
- The legacy HS256 JWT signing secret is revoked; the ECC P-256 key is the only signing key.
- The only secret API key is deleted. The project has no secret key, and FinAgent needs none.

### Cutover checks

- **Functional smoke (2026-11-09 01:38).** A run started through the MCP invoke tool as Aisha opened a CRITICAL request with 2 enforced approvals. The Slack notice was sent once with the approval link. Aisha's approval of her own run was refused with `SOD_SELF_APPROVAL` and journaled. Sarah and then Marcus approved on the approval page. Ledger chain: STARTED, 7 ASSET_RECONCILED, HITL_REQUESTED, NOTIFICATION_SENT, HITL_APPROVAL_RECORDED, HITL_RESOLVED, COMMITTED; the MCP shows APPROVED, 2 of 2. A second run, started by mistake, was rejected by Sarah and closed with a COMMITTED row of status ROLLED_BACK, the designed terminal record for a rejection, so the live reject path ran too. The owner entered both approvals and the rejection, signed in as each demo identity in turn, so the smoke proves two distinct identities on live, not two people.
- **Security smoke (2026-11-09 03:07).** The old `service_role` and `anon` keys are refused as `apikey` and as Bearer (401). The old `postgres` password is refused. A decision body with a `\u0000` escape returns 400 `INVALID_INPUT`, journaled, with nothing changed. `GET /rest/v1/rpc/fao_whoami` returns 404. `pg_graphql` is not enabled, so there is no GraphQL surface. Ledger and audit counts were unchanged by the probes.
- **Re-export diff (2026-11-09 04:25).** The five live workflows, exported again from n8n, equal the repo exports: no logic difference, and the published version of each is the stored one.

### Control gaps closed

These v1 gaps were open before this release and are closed on live:

- **Identity binding.** The invoker and the approver are taken from their own Supabase Auth sessions (`auth.uid()`), never from a payload.
- **Decided requests locked; self-approval refused.** Decisions go only through `fao_hitl_decide`, decided requests cannot change, and the service-role key has no access to FinAgent objects.
- **Approval endpoints.** The unauthenticated n8n approval pages are retired. Approvers decide on a static page with their own session. The run-start webhook needs a header key and a single-use run token.
- **Atomic resolution.** A decision and its ledger events commit in one transaction, and so do request creation and its ledger event.
- **Failure records.** An error workflow, a five-minute sweep and notification records. Failures that cannot attach to a run go to the append-only `workflow_failures` table.
- **HITL timeout.** Late decisions are refused. Overdue requests expire (HITL_EXPIRED) and escalate once, and are never recorded as a commit.
- **Append-only, narrowed.** UPDATE, DELETE, TRUNCATE and direct INSERT are refused for every application role. Ledger rows are appended only through database functions with database-set timestamps. The owner remains outside the control (see README).
- **Writer batches.** The Writer stores a batch all or none and names every bad item.
- **Dual approval.** CRITICAL review needs two qualifying approvals from different approvers, never the invoker, and one rejection closes the request ([ADR-0004](docs/adr/0004-dual-approval-enforced.md), closes ADR-0001).

### Known limits

The cutover did not close these:

- Wallet and ledger data are fixtures inside the flagship workflow, not live connectors.
- There is no TOTP second factor yet: a stored approver password is enough to approve, so the MCP invoker is left empty.
- The Supabase project is on the Free plan, which has no automatic backups. Backups are manual dumps; the first one after go-live (2026-11-09) passed a restore test.
- n8n has no backup or droplet snapshot since 2026-11-09. The workflow logic can be rebuilt from the repo exports; execution history and credentials cannot.
- n8n's own database is postgres:16, which n8n supports for compatibility only; the owner left it as is.
- Every other limit in the README [Known Limitations](README.md#-known-limitations) still applies unless this entry says otherwise.
