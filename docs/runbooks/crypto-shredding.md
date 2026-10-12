# Runbook: crypto-shredding an erasure scope

Written 2026-10-12, against the erasure half of [ADR 0024](../adr/0024-audit-retention-and-erasure.md).
Updated 2026-10-12 when the provider syncs (Google Calendar, Gmail, Slack via Nango, epic E4) were wired to it.
Code: `AshEnterprise.Erasure` (`lib/ash_enterprise/erasure.ex` and `lib/ash_enterprise/erasure/`), and
`AshEnterprise.Integration.Landing` / `Landing.Scoped` for the provider syncs. Tests:
`test/ash_enterprise/erasure_test.exs`, `test/ash_enterprise/integration/erasure_e2e_test.exs` (one end-to-end shred per
vertical) and `test/ash_enterprise/integration/landing_scoped_test.exs`.

## What a shred does

Content that arrives through an external connection is sealed, as it is written, under the key of that connection's
**erasure scope**. Shredding the scope destroys its key, which makes all of that content permanently unreadable:

- `AshEnterprise.Ingestion.SourceObject.raw_payload`, the raw landing;
- the canonical content projected from it: `Message.body`, `Conversation.subject` and `participants`,
  `CalendarEvent.title` and `location`;
- the copies of that content in the audit log. An audited write stores only the ciphertext (`changed_attributes`
  → `encrypted_*`), and the plaintext argument is recorded as `null` in `data`;
- the morning brief (`Agents.MorningBrief`), which stores the ids of the events it covers and renders `draft_text` on
  read, so each line reads `[shredded]` after its event's scope is shredded.

What survives: every row, every foreign key, every structural column (system, external id, stream, timestamps,
direction, who-did-what in the audit log), and the audit hash chain. Nothing in `audit_events` changes, so
`mix ash_enterprise.audit.verify` still passes. After a shred, a sealed value reads as
`%AshEnterprise.Erasure.Shredded{}`. It renders as `[shredded]` in templates, in strings and in JSON. It does not crash
and it is never `nil`.

## Scopes

A scope is `(kind, ref)`, unique, with exactly one key for its whole life:

| kind | covers | ref |
|---|---|---|
| `connection` | everything that came in through one linked account, or one tap pipeline | for a provider sync, the **linked account's id** (a uuid); for a configured tap, `pipeline:<name>` |
| `data_subject` | content belonging to one person | the subject's stable id |

Each row is sealed under exactly one scope. Shredding a `connection` scope does not reach a person's data that came in
through a *different* connection, and nothing lands under a `data_subject` scope yet (see "Not reached" below).

A row never changes scope. A landing whose `(external_system, external_id)` already exists under a different scope is
refused (`AshEnterprise.Ingestion.Changes.KeepErasureScope`; the provider syncs report it as `cross_scope_landing` and
cancel). Every provider sync namespaces its external ids by the linked account, so two accounts that can see the same
message or meeting land two rows, each erased with its own account.

### Provider syncs: one scope per linked account

Every record the Calendar, Gmail and Slack syncs fetch is landed by `AshEnterprise.Integration.Landing.Scoped`, sealed
under the scope `connection:<linked account id>`, and every canonical row projected from it (`CalendarEvent`,
`Message`, `Conversation`) carries the same `erasure_scope_id`. The ref is the linked account's uuid: opaque, never the
Nango connection id, an email address or a channel name, because a scope's ref and label are audited and outlive its
shred. The label is `linked account (<integration>)` and nothing else.

**Find a linked account's scope ref:**

```bash
devenv shell -- mix ash_enterprise.integration.accounts --email you@example.com
# 9b0f…  slack  work  active  connection ****a1b2  scope connection:9b0f… (active)
```

The last column is what `mix ash_enterprise.erasure.shred` takes. `mix ash_enterprise.erasure.scopes` lists the same
scope as `connection:<id>  active  linked account (slack)`. Note the ref down **before** unlinking: after an unlink the
scope is still listed, but only by that id and its integration.

The scope opens when the account is linked with `mix ash_enterprise.integration.link` (or at its first sync), so it is
shreddable before anything has landed. Gmail and Slack content lands raw (sealed) but is projected only behind a zone
gate, which denies by default (ADR 0042 admission is not wired).

### Operator setup

```bash
devenv shell -- mix ash_enterprise.seed --privileges-only
# then, in IEx: AshEnterprise.Platform.Seeder.regrant_administrator_privileges(org_id)
devenv shell -- mix ash_enterprise.integration.link --email you@example.com \
  --integration slack --connection-id <nango connection id> [--label work]
devenv shell -- mix ash_enterprise.integration.sync --linked-account <id> [--steps 3]   # dev only; counts only
```

The privilege catalogue now includes the Integration resources, and the regrant gives a tenant's Administrator what it
needs to link accounts, run syncs (`read` on the operation resources and on each vertical's `Sync`, the cursors) and
shred (`write` on `AshEnterprise.Erasure.Scope`). The link is made as the user named by `--email`: a linked account is
always owned by the person whose account it is. The connection id is never printed back in full.

The scheduler (`AshEnterprise.Integration.SyncScheduler`, Oban cron) enqueues one step per **active** linked account
per vertical every 5–10 minutes on the `:ingestion` queue. Each worker is unique per linked account, so overlapping
ticks collapse into the step already queued or running.

## Before you shred: stop new data arriving

Shredding stops nothing from arriving. A shredded scope refuses any further writes under it (checked again under a
lock inside each write's transaction, so a sync racing the shred is refused or reached, never left readable), and a
provider sync whose scope is shredded cancels before its first provider request (`scope_shredded`). Still, stop the
source first.

### Forgetting a linked account, in order

1. **Deactivate the linked account** (IEx: `Ash.Changeset.for_update(account, :deactivate, %{}, actor: owner,
   tenant: org_id) |> Ash.update!()`). The scheduler stops enqueuing it, and a step already queued cancels with
   `no_linked_account` without a request. Deactivating erases nothing; the content is still readable.
2. **Note the scope ref** (`mix ash_enterprise.integration.accounts --email …`): it is `connection:<linked account id>`.
3. **Delete the Nango connection** for the account (Nango dashboard, environment `dev`, integration `slack` /
   `google-mail` / `google-calendar` → the connection → delete), or `DELETE /connection/{connectionId}` (with its
   `provider_config_key`) against the Nango API. This also deletes the OAuth tokens Nango holds for it.
4. **Revoke the provider's grant:**
   - Slack: revoke the app's tokens in the workspace (workspace settings → Manage apps → the app → Remove app, or
     `auth.revoke` with the token). Removing the app from the VendorPM workspace stops any token that survived Nango.
   - Google: <https://myaccount.google.com/permissions> → the app → Remove access.
5. **Shred** the scope (next section). This is the step that destroys content.
6. **Unlink** the account (`LinkedAccount.unlink`), optional but tidy: it forgets the connection mapping and deletes
   the vertical's sync cursors (a Calendar cursor holds the calendar id, which for a primary calendar is the owner's
   address). The shredded scope stays as the tombstone, still named by the account's id.

For a tap pipeline, step 1 is removing or disabling the pipeline config.

`test/ash_enterprise/integration/erasure_e2e_test.exs` ("forgetting a linked account") runs this order.

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
  connecting a real account. Morning briefs composed before migration `20261012060423_erasure_review_fixes` stored
  their rendered text, so their `compose_brief` audit events hold event titles and locations in plaintext. The
  migration also refuses to run while `ingestion_source_objects` or the sealed canonical
  tables hold rows, because `erasure_scope_id` is `NOT NULL`. Those rows are reconstructible (re-run the tap, then
  `Projection.replay`), so empty them first. Their old audit events are the plaintext caveat above.
- **`Canonical.Person` rows.** Every organizer's and attendee's name and email address stays readable in
  `canonical_people`. They are not sealed: a person is shared across sources and upserts on email, so it cannot carry
  one connection's key. They are `sensitive?`, so the audit log records them as `null`, and removing a person is an
  ordinary row delete — but a shred does not do it. A `data_subject` scope with a blind-index identity is the intended
  fix; nothing writes under one yet.
- **The same record from two connections.** Landings are unique on `(external_system, external_id)`, not on the scope,
  and a landing under a second scope is refused rather than taking the row over. So a pair is erased only by the
  shred of the scope it first landed under. The provider syncs namespace every external id by linked account, so
  this does not arise for them; a new adapter must do the same.
- **Sync cursors.** A Calendar sync cursor stores the calendar id (a primary calendar's id is the owner's email
  address) in plaintext. It is bookkeeping, `sensitive?` and never audited, and it is deleted when the linked account
  is unlinked (step 6 above), not by the shred. Gmail and Slack cursors hold ids and positions only.
- **Scope refs and labels.** `kind`, `ref` and `label` are structural and are audited when a scope opens, so they
  outlive the shred. Use opaque ids (a linked account's uuid, a Slack team id), never an email address or a person's
  name. The provider syncs use the linked account's uuid and the label `linked account (<integration>)`.
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
  a debug log line, is outside the key's reach. OpenTelemetry spans carry action names and, as span status, the
  error message. Sealed attributes have no length constraint for that reason (Ash renders a failed constraint's value
  into the message), but other validation errors on content would still carry it. Verify before relying on it.
- **Oban job args and errors.** Tap jobs carry a pipeline name, not content, and a failed tap is recorded by exit
  status only (its output, which is its RECORD lines, is discarded). A future adapter that puts content in job args
  or in an error reason would put it beyond the shred. Pass ids; return structural errors.
- **OpenLineage / Marquez.** Facets carry structural names only (dataset and job names), and a FAIL event's
  `errorMessage` carries the structural reason `TapWorker` reduced it to. A dataset named after a channel or a person
  would be a leak. Keep names structural.
- **Anything derived outside these resources.** Embeddings, model outputs, agent transcripts and System One
  evidence built from shredded content are not sealed under the scope. Do not derive from raw content without
  carrying the scope id forward.
