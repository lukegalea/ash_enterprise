# Runbook: crypto-shredding an erasure scope

Written 2026-10-12, against the erasure half of [ADR 0024](../adr/0024-audit-retention-and-erasure.md).
Code: `AshEnterprise.Erasure` (`lib/ash_enterprise/erasure.ex` and `lib/ash_enterprise/erasure/`). Tests:
`test/ash_enterprise/erasure_test.exs`.

## What a shred does

Content that arrives through an external connection is sealed, as it is written, under the key of that connection's
**erasure scope**. Shredding the scope destroys its key, which makes all of that content permanently unreadable:

- `AshEnterprise.Ingestion.SourceObject.raw_payload`, the raw landing;
- the canonical content projected from it: `Message.body`, `Conversation.subject` and `participants`,
  `CalendarEvent.title` and `location`;
- the copies of that content in the audit log. An audited write stores only the ciphertext (`changed_attributes`
  → `encrypted_*`), and the plaintext argument is recorded as `null` in `data`.

What survives: every row, every foreign key, every structural column (system, external id, stream, timestamps,
direction, who-did-what in the audit log), and the audit hash chain. Nothing in `audit_events` changes, so
`mix ash_enterprise.audit.verify` still passes. After a shred, a sealed value reads as
`%AshEnterprise.Erasure.Shredded{}`. It renders as `[shredded]` in templates, in strings and in JSON. It does not crash
and it is never `nil`.

## Scopes

A scope is `(kind, ref)`, unique, with exactly one key for its whole life:

| kind | covers | ref |
|---|---|---|
| `connection` | everything that came in through one linked account / Nango connection / tap pipeline | the connection's stable id, e.g. the Nango connection id for the VendorPM Slack, or `pipeline:<name>` for a configured tap |
| `data_subject` | content belonging to one person | the subject's stable id |

Each row is sealed under exactly one scope. Shredding a `connection` scope does not reach a person's data that came in
through a *different* connection, and nothing lands under a `data_subject` scope yet (see "Not reached" below).

## Before you shred: stop new data arriving

Shredding stops nothing from arriving. A shredded scope refuses any further writes under it, so a connection that is
still live would make its next sync fail loudly rather than land data. Do these first:

1. **Delete the Nango connection** for the account (Nango dashboard, environment `dev`, integration `slack` /
   `google-mail` / `google-calendar` → the connection → delete), or `DELETE /connection/{connectionId}` (with its
   `provider_config_key`) against the Nango API. This also deletes the OAuth tokens Nango holds for it.
2. **Revoke the provider's grant:**
   - Slack: revoke the app's tokens in the workspace (workspace settings → Manage apps → the app → Remove app, or
     `auth.revoke` with the token). Removing the app from the VendorPM workspace stops any token that survived Nango.
   - Google: <https://myaccount.google.com/permissions> → the app → Remove access.
3. Remove or disable the pipeline/linked-account config that would start a new sync.

## Shred

```bash
devenv shell -- mix ash_enterprise.erasure.scopes
devenv shell -- mix ash_enterprise.erasure.shred connection:<ref> --as you@example.com --reason "left VendorPM"
```

The task asks for a final `y` (or pass `--yes`). Typing the full `kind:ref` is also the confirmation the action
requires: `confirm` must equal the scope's `ref`.

Or from IEx (`devenv shell -- iex-server`):

```elixir
user = AshEnterprise.Accounts.get_user_by_email!("you@example.com", authorize?: false)
actor = AshEnterprise.Security.ActorContext.attach(user, AshEnterprise.Security.ActorContext.build(user))
scope = AshEnterprise.Erasure.scope_by_ref!(:connection, "<ref>", authorize?: false)
AshEnterprise.Erasure.shred_scope!(scope, scope.ref, "left VendorPM", actor: actor)
```

**Who can shred:** a human holding `write` on `AshEnterprise.Erasure.Scope` at `global` depth. After deploying this
change, run `devenv shell -- mix ash_enterprise.seed --privileges-only` so the privilege exists. Then grant it: from
IEx, `AshEnterprise.Platform.Seeder.regrant_administrator_privileges(org_id)` gives the tenant's Administrator role
every missing global privilege, this one included. Or assign it to a narrower role. No system actor can
shred: not `oban`, not `system`, and not `ai`. The shred is audited on the scope (`action: shred`, the person's
`user_id`, the reason, `shredded_at`). The key itself is never audited, so nothing in the log can bring it back.

## Verify

```bash
devenv shell -- mix ash_enterprise.audit.verify      # the chain still verifies
devenv shell -- mix ash_enterprise.erasure.scopes     # the scope reads "shredded <time>"
```

## Not reached by a key destroy

Be honest with whoever asked for the erasure about these. Each is a real copy of something:

- **Backups, WAL archives, replicas and dead tuples.** The key row is `DELETE`d, but Postgres keeps the old tuple until
  `VACUUM`, and backups and WAL keep it until they age out. Every one of those copies holds only the *wrapped* key,
  which opens only with the master key (`ERASURE_MASTER_KEY`). Someone holding both an old backup and the master key
  can recover a shredded scope until that backup expires. To close it, rotate the master key and re-wrap the live keys
  once the backup window has passed (not built yet), or expire the backups.
- **The master key.** Losing it shreds every scope at once. Leaking it alongside a database copy exposes every live
  scope. It is a production secret of the same class as the database password. In dev it lives in
  `.devenv/state/erasure/master.key`.
- **Content that predates sealing.** The migration that introduced sealing drops the old plaintext columns. Audit
  events written *before* it carry plaintext forever, because the log is append-only. Land this change before
  connecting a real account. The migration also refuses to run while `ingestion_source_objects` or the sealed canonical
  tables hold rows, because `erasure_scope_id` is `NOT NULL`. Those rows are reconstructible (re-run the tap, then
  `Projection.replay`), so empty them first. Their old audit events are the plaintext caveat above.
- **`Canonical.Person`.** Names and email addresses are not sealed. A person is shared across sources and upserts on
  email, so it cannot carry one connection's key. A `data_subject` scope is the intended unit, and nothing writes under
  one yet.
- **Scope refs and labels.** `kind`, `ref` and `label` are structural and are audited when a scope opens, so they
  outlive the shred. Use opaque ids (a Nango connection id, a Slack team id), never an email address or a person's
  name.
- **Tenancy.** Scopes are not tenant-scoped (nor are raw landings). A global write grant on `Scope` reaches every
  scope in the deployment, so in a multi-tenant deployment one tenant's Administrator could shred another tenant's
  connection. That is acceptable for the single-operator dogfood deployment. Make scopes tenant-scoped before any
  multi-tenant use.
- **Structural columns.** External ids, Slack channel ids, iCal UIDs, timestamps and the audit `data` for non-content
  inputs stay readable by design. A Slack channel *name* that is used as a conversation subject is content and is
  sealed. A channel *id* is not.
- **Nango.** Its own database holds the connection, its tokens, and any records cached by its syncs, until the
  connection is deleted (step 1 above).
- **The provider.** The Slack and Google originals are untouched. This erases VendorPM's copy, not Slack's.
- **Logs, error reports, traces.** Anything that logged a payload, such as an exception report with a changeset or
  a debug log line, is outside the key's reach. OpenTelemetry spans carry action names and are not meant to carry
  values. Verify that before relying on it.
- **Oban job args.** Tap jobs carry a pipeline name, not content. A future adapter that puts message content in job
  args would put it beyond the shred. Pass ids.
- **OpenLineage / Marquez.** Facets carry structural names only (dataset and job names), never values. A dataset
  named after a channel or a person would be a leak. Keep names structural.
- **Anything derived outside these resources.** Embeddings, model outputs, agent transcripts and System One
  evidence built from shredded content are not sealed under the scope. Do not derive from raw content without
  carrying the scope id forward.
