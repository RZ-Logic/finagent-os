# ADR-0002: Identity Comes From the Session; Roles Are Grants in the Database

| | |
|---|---|
| **Status** | Accepted (owner sign-off 2026-11-09, with the cutover). Built on branch `phase2-5-core-2026-11-07`; deployed 2026-11-09. |
| **Date** | 2026-11-07 |
| **Author** | Rizwan Ahmed, ACCA · Velocyt Consulting |
| **Supersedes** | None. Extends ADR-0001's context: identity is now bound; dual approval was the remaining gap when this was written and is now built ([ADR-0004](0004-dual-approval-enforced.md)). |
| **Superseded by** | None |

## Context

In v1 the approver and the invoker were whatever a caller said they were. `fao_hitl_resolve` took an approver email as an argument, and a run's invoker was a field in the workflow payload. A self-approval check compared two strings the caller supplied, so it proved nothing. The MCP server read the audit trail with the service-role key, which bypasses row-level security and can write anything.

## Decision

1. **Identity only from `auth.uid()`.** Every client function reads the caller from the Supabase Auth session. No argument, body field, header or claim set by FinAgent code names a person. A call with no session gets 401 `NO_SESSION` and is journaled.
2. **Run start with a token.** `fao_run_start` records the invoker from the session, checks the agent's registry status, tier and `max_runs_per_hour`, enforces an idempotency key and returns a single-use run token. Only a hash of it is stored. n8n consumes it once through `fao_run_claim`; a forged, expired or reused token is refused. The run's invoker is therefore the signed-in person who started it, not a value in the webhook body.
3. **Application roles are rows, not Postgres roles.** `fao_user_roles` grants `invoker`, `approver`, `admin` or `reader`, per agent or globally (`agent_id` NULL). Grants need an active `process_owners` row (except `reader`), are changed only through `fao_admin_set_role` with a reason, and every change writes an audit row. `has_role` and `has_any_role` answer RLS and RPC checks. A client that asks about another user learns nothing (KNOWN-LIMITS U12); since patch round 6 the common case (`p_uid = auth.uid()` or an owner session) answers before any call-stack read and the policies call the helpers once per statement.
4. **Self-approval refused in the database.** `fao_hitl_decide` refuses an approver who invoked the run, whatever roles they hold.
5. **One Postgres role for n8n.** `fao_workflow` (NOLOGIN in the migration, LOGIN set by setup or the runbook) can execute the workflow functions and read thresholds, nothing else. `service_role` and PUBLIC hold nothing on FinAgent objects.
6. **The MCP reads as a person-shaped reader.** A dedicated Auth user, `mcp.reader@finagent-os.demo`, holds only the `reader` role (control FAO-GOV-015). The server refuses to start with a privileged key and requires https except on loopback. Invoking a run through the MCP uses the human invoker's own session.

## Why the second factor is deferred

A TOTP second factor for approvers and admins is planned for wave 2. Session binding was the larger gap: without it a second factor would have protected an identity the database never checked. Until TOTP ships, a stored password is enough to approve for any user holding the approver role, so run-start credentials kept on an agent host should belong to a user without that role (KNOWN-LIMITS section 1 item 1).

## Consequences

- The controls bind actions to identities; they cannot prove two identities are different people. In the public demo one person holds every demo identity.
- The database owner, holders of the `postgres` password and holders of platform admin or secret keys stay outside the control.
- Dual approval (ADR-0001) can be added on top: the request already records its configured approval count and the single approval enforced when this was written. It was added in [ADR-0004](0004-dual-approval-enforced.md): CRITICAL requests on the flagship now need two approvals.
