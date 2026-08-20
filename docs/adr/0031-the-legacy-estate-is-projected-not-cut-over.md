# ADR 0031 — The legacy estate is projected, not cut over

- **Status:** accepted
- **Date:** 2026-08-20

## Context

The request was specific and it sounded small: a UI generated for the **new** schema, receiving the
**inserts made into the legacy table**, updating **live**. Three clauses, and the third one already
worked — [`AshEnterpriseWeb.A2uiLive.LegacyUsers`](../../lib/ash_enterprise_web/live/a2ui_live.ex) has
been live over `strangler.users` since step 3 of
[`../plans/ash-strangler-in-reference-app.md`](../plans/ash-strangler-in-reference-app.md). What was
new is the first clause. "The new schema" means a table this application owns, with real columns and a
real index, rather than a view whose columns are a `SELECT` list.

In the plan's vocabulary that is **step 7, Cutover**, and it is the step that makes the new table the
source of truth while the old application keeps reading `legacy.users`-as-a-view. So the honest way to
read the request was as a request for step 7, and the honest thing to do first was to find out what
step 7 costs.

**It costs more than the request implies, and the mapping says so itself.** At `:read_from_new`
`ash_strangler` flips the view: the legacy name becomes a view *over the new table*, with `INSTEAD OF`
triggers, so the old application's `SELECT * FROM users` keeps working. That requires every mapping to
run backwards, and `AshStrangler.Verifiers.VerifyReverseMappable` refuses the phase otherwise — it
rejects the `:key`, `:constant`, `:unmapped` and `:default` combinators from the check and then refuses
anything left classified `invertible: :no` or `:semi`.
[`AshEnterprise.Legacy.User`](../../lib/ash_enterprise/legacy/user.ex) has three such mappings, each
carrying the mandatory `because:` that makes it one:

- **`full_name`** — `expr((first_name || "") <> " " <> (last_name || ""))`, and the reason is quoted
  verbatim in the resource: *"Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."*
- **`legacy_state`** — deliberately one-way, because the legacy state machine belongs to the old
  application.
- **`lifecycle_status`** — five legacy values onto two, so *"passive, pending, suspended and deleted
  all collapse onto `:inactive`"* and there is no single value to write back.

The verifier's own moduledoc names `full_name` as its worked example, which is a good sign that the
mapping and the tool agree about what is hard here. Its remedy is also stated: *"carry those legacy
columns across unchanged as well"* — that is, the new table has to **hold** `first_name`, `last_name`
and `state` rather than derive them. That changes the shape of the target resource, which is the
opposite of what the migration is for, and usage rule 20 calls `:read_from_new` **a one-way door**. A
phase change made to satisfy a demo is a phase change that cannot be taken back.

There is a second, quieter cost. `legacy.companies.id` reaches this resource as nothing at all:
`company_id` exists on the twin, no mapping consumes it, and `owning_business_unit_id` is a
`constant` pointing at the root business unit — because *"`company_id` was never a security boundary"*
(§4.3) and making it one silently is the mistake that section exists to prevent. That is step 5 of the
plan, the step the plan itself describes as having **the highest blast radius in any real migration**,
and steps 4 and 6 sit in front of it. Step 7 is not one commit away; it is four.

So the question became: is there something that delivers all three clauses of the request, in the
direction the mapping is already proven in, without spending the one-way door?

## Decision

**Project the legacy estate into a table this application owns, one way, and keep both surfaces live
side by side. Do not cut over.**

Data flows legacy → new and only that way. That is the direction the mapping already proves: the
compatibility view computes `full_name`, `legacy_state` and `lifecycle_status` forward every time it is
read, and nothing about a forward projection needs an inverse. The invertibility problem that blocks
step 7 does not arise, because nothing here ever writes back.

Four pieces, all small:

**[`AshEnterprise.Accounts.ProjectedUser`](../../lib/ash_enterprise/accounts/projected_user.ex)** — an
ordinary platform resource over `projected_users`, a table created by `mix ash.codegen` like any other.
`ownership: :business_owned`, `audit?: true`, `api_type: :both`. Nothing in it is strangler-aware.

**[`AshEnterprise.Legacy.Projection`](../../lib/ash_enterprise/legacy/projection.ex)** — a second
`Ash.Notifier` on `Legacy.User`, which now declares
`notifiers: [Ash.Notifier.PubSub, AshEnterprise.Legacy.Projection]`. `AshStrangler.Listener` already
holds the `LISTEN` connection and already re-reads the changed row *through Ash*, so the notification it
dispatches carries mapped values rather than raw legacy columns. The projector consumes that
notification and upserts. A second listener would duplicate the hard part and could disagree with it.

**`mix ash_enterprise.legacy.project`** — the backfill, because the projector reacts to *changes* and a
row that has not changed since the projector started has never produced a notification. A live
projector with no backfill shows an empty table that fills up one edit at a time, which looks exactly
like a broken feature. `AshStrangler.Backfill` is deliberately not used: it backfills columns *within* a
legacy table, which is step 4. This copies rows *out* of one, and the estate is nine users.

**`/app/directory`**, over `AshEnterpriseWeb.A2ui.ProjectedUserUI`, beside `/app/legacy-users` over the
view. Both live. The comparison is the deliverable.

### Why the projected row keeps the view's derived id

`ProjectedUser.id` is a supplied `:uuid` primary key — `writable? true`, no default — and the projector
passes `row.id` straight through from the read model. So the same person carries the same id on both
surfaces and can be followed between them without a lookup table.

That works only because the UUIDv5 derivation is deterministic in SQL *and* in Elixir, which is the
property [ADR 0008](0008-typed-invertible-legacy-mappings.md) chose it for and §4.1 of the plan argues
at length. A test asserts the equality rather than leaving it incidental, because it is the one
property that makes "two surfaces over the same rows" a true statement rather than a claim about
layout.

It also, incidentally, satisfies `ash_strangler`'s usage rule 21 — *"the resource needs a stored
`legacy_id` before cutover"*, since the uuid derivation runs one way and a reverse view cannot recover
the integer key. `legacy_id` is an `allow_nil? false` column here. Step 7 is not built, but the one
piece of it that has to be established *before* it is now established.

### Audit becomes possible, and that is the point rather than a side effect

`Legacy.User` sets `audit?: false`, and the reason is written into the resource: the writes worth
auditing are the legacy application's, and they are invisible to any notifier Ash could install.
Claiming a trail over them would be worse than not claiming one. §4.8 of the plan works the mechanism
through in detail and reaches the decisive line — *"the notify path is good enough for cache invalidation
and LiveView reactivity, and not good enough for compliance"* — and §6.4 lists the general form,
*"you cannot audit writers you do not control"*, among the things this exercise proves that a greenfield
application cannot.

**Two places the plan guessed differently, recorded so the documents agree.** §4.8 proposed that
`SystemActor` gain a **`:legacy`** member, so a synthesized event from the notify path would say
`system_actor = "legacy"`. That is not what shipped: no legacy write is audited at all — `audit?: false`,
for §4.8's own delivery reason — and the member that exists is **`:projection`**, describing a write this
application really made. The distinction §4.8 wanted to preserve is preserved; the row it lands on is a
different row. And §4.11 predicted legacy `state` would map as a **`decode`** onto `state_code` — *"one
declared bijection"* — which is impossible against a two-valued `lifecycle_status`; the addendum to the
plan works that one through.

The projection's write is a different thing. It is an ordinary Ash create, so it produces an ordinary
audit event, hash-chained like everything else ([ADR 0020](0020-tamper-evident-audit-log.md)),
tenant-scoped like everything else ([ADR 0022](0022-audit-log-is-tenant-scoped.md)). The actor is
`AshEnterprise.Platform.SystemActor.projection/0` — deliberately **not** a person, because the change
was really made by a process this application cannot see, and borrowing the name of whoever happened to
be signed in would put a false name in the provenance columns. `ProjectionTest` asserts the events exist
for `AshEnterprise.Accounts.ProjectedUser` and that every one carries
`metadata["system_actor"] == "projection"`.

What the trail says is *"the projector wrote this, sourced from legacy id 7."* That is materially less
than *"Ana Whitfield changed her surname at 14:02"* and it is exactly what happened, which is the only
standard an audit log should be held to.

### The notification is real here, and synthesized there

This is the sharpest difference between the two surfaces and it is worth stating as a property rather
than a detail.

On the legacy surface no Ash action ran, so the listener has to **synthesize** a notification — and
because `Ash.Notifier` dereferences `notification.action.name` unconditionally, that synthesized action
needs a name. It gets `:legacy_write`, which the resource does not declare. That is why `Legacy.User`
uses `publish_all` (matching on the action's *type*) rather than `publish` (matching on its *name*),
which would silently never fire. `AshStrangler`'s usage rule 30 records this as a general property of
strangled read models.

On the projected surface the write is a plain create, so `Ash.Notifier.PubSub` fires unremarkably.
`publish :project, ["created"]` would work. `publish_all` is kept only so both resources' topics have
the same shape and `AshEnterpriseWeb.A2ui.Surfaces.topics/1` can read either.

The claim this supports is visible in the two `use AshA2ui.LiveRenderer` blocks: **identical options
over a different UI module.** `A2uiLive.ProjectedUsers` subscribes to `projected_users:*` because the
resource declares those publications, not because anything in it knows a legacy database exists. It
cannot tell a projected write from a create made by a person in the admin UI — which is the property
that makes the projection worth having at all.

### `email` still carries no unique identity, and the reason got sharper

The read model deliberately declares no identity on `email`: `index_users_on_email` is neither unique
nor case-insensitive, and the seed data contains a collision, which is a data-quality defect the new
model surfaces and the old one tolerated.

On the projected table the argument is stronger, not weaker. Two seeded rows differ only by case —
`Dana@corp.example` and `dana@corp.example` — and `email` is a `:ci_string`, so a unique identity here
would consider them one person and the upsert would **silently drop somebody**. That is a *new* loss,
introduced by the new model, on top of the defect it inherited, and it is strictly worse than carrying
both rows and showing the collision. `legacy_id` is the upsert key instead, because it is the one the
source actually guarantees. A test asserts both Dana rows project and names both logins, because "the
projection does not lose people" is the property that matters and it is not self-evident from reading
the resource.

The identity arrives at step 4 — the expand step — behind a migration that fails loudly if the data
still violates it.

### `lifecycle_status` is reached by running the transition, not by writing the attribute

`AshEnterprise.Platform.Resource` gives every lifecycle-bearing resource an `AshStateMachine` with
`initial_states [:active]` and one named update action per transition — `:deactivate` and `:activate` —
so that the audit log records *"deactivate"* rather than an anonymous update. `initial_states [:active]`
therefore **forbids creating a row already inactive**, and that is correct: a state machine whose
initial state is an argument is not a state machine.

So `Projection.align_lifecycle/2` upserts the row and then, if the legacy state is anything other than
`"active"`, runs `:deactivate` through the platform's own action. The five-onto-two collapse the mapping
declares as lossy is consequently recorded twice on the projected surface: as two columns that agree
(`legacy_state` beside `lifecycle_status`, both on screen), and as **a transition an auditor can find**.
That is more than the read model can offer, where the collapse is a derivation computed on every
`SELECT` and recorded nowhere.

## Does it consume ActorContext?

**On the read path yes, ordinarily. On the write path no, deliberately, and it is a bypass rather than a
gap.**

`/app/directory` is `AshA2ui.LiveRenderer` with `actor_fn` returning `socket.assigns[:current_user]` and
`tenant_fn` returning `AshEnterprise.Security.ActorContext.tenant(...)` — byte for byte what
`/app/legacy-users` and the four non-live surfaces do. `ProjectedUser` is instantiated on
`AshEnterprise.Platform.Resource`, so it inherits ownership, tenancy, soft delete, the audit hook and
the additive policy union with no per-resource wiring. Nothing about it is special.

The projector's own write runs `authorize?: false` with `actor: SystemActor.projection()` and
`tenant: Estate.organization_id()`. That is the same shape as the seeder and the process engine, and the
same argument applies: there is no role model that could grant a `pg_notify` callback permission to
write, and inventing one would be a second authorization path to get wrong. The actor is still named, so
the audit log distinguishes *"the projector did this"* from *"we do not know who did this"* — which is
the whole reason `SystemActor` exists rather than a nullable `user_id`.

**One consequence of the platform's own design bit hard here, and it is worth recording as a standing
cost rather than as an incident.** A new resource is invisible to an administrator until the privilege
catalogue is regenerated. `/app/directory` rendered zero rows with the entire chain working perfectly —
trigger firing, listener re-reading, projector writing, `projected_users` full — because `privileges`
held no rows for `AshEnterprise.Accounts.ProjectedUser`, so the Administrator role granted nothing over
it and the policy union was empty. `Seeder.regrant_administrator_privileges/1` returns the number of
grants *added*, and it returned 0, because it only grants privileges that **exist**:
`seed_privileges/0` has to run first. Measured on a fresh database: 248 privileges written, then 8
regranted per tenant — one per `AccessRight` verb, which is exactly one new resource's worth.

That is the price of deriving the catalogue from the resources that exist at seed time, which
`Seeder`'s own moduledoc argues for on the grounds that *"the dangerous direction of drift is a missing
privilege, because it silently makes some access ungrantable."* The argument is right and the failure
mode is nasty: it presents as a broken feature, not as a stale grant.

## Consequences

**What this makes easy.** An audited, tenant-scoped, policy-governed table of the legacy estate's people
that is current within a notification round-trip, without touching the legacy schema, without an
`INSTEAD OF` trigger, and without spending the one-way door. Every derived surface comes free because
`ProjectedUser` is an ordinary resource: `ash_admin`, GraphQL, JSON:API, MCP, the A2UI table, the
privilege catalogue. And a genuinely comparable pair — the same nine people, over a view and over a
table, both live, both on screen — which is the demonstration §6.3 of the plan asks for, that
*"derivation survives an undesigned schema."*

**What this makes hard.**

- **It is eventually consistent, and the lag is a column rather than a footnote.** `projected_at` is
  `allow_nil? false` and is rendered on the surface, because the projection happens on commit through a
  notification and a surface that hid the delay would be claiming a guarantee the design does not make.
  Watching the two surfaces update a beat apart is the honest picture.
- **A row that fails to project is silently absent until the backfill is re-run.** There is no retry and
  no dead-letter queue. `Projection.log_failure/2` says so in the log message itself — *"there is no
  retry"* — and a test captures the log and asserts on that text, because "did not raise" alone would
  also pass if the failure were swallowed without a trace. The reconciliation job that would close the
  gap is **step 6** of the plan, and this is not that.
- **Containment lives in the notifier and is not optional.** A notifier that raises takes the listener's
  process with it, and the listener holds the only `LISTEN` connection — so one bad row would stop
  reactivity on *every* surface, including the read model's. Hence `project_row/1` returns
  `{:error, reason}` (the backfill wants something to report) while `notify/1` rescues and logs. The
  asymmetry is deliberate and both halves are tested.
- **The projector has to ignore its own writes, before that matters.** `notify/1` matches on
  `%{ash_strangler: %{origin: :legacy}}`. Today every notification on `Legacy.User` is legacy-origin,
  because the resource declares no write actions at `:read_from_legacy` — but at `:dual_write` it gains
  them, and a projector that fed its own output back would loop. The guard is tested now, while the
  phase makes it untestable-by-accident rather than after it starts mattering.
- **There is a second table of people, and `Accounts.User` is not it.** Projecting into the
  authentication resource would mean writing a fabricated `hashed_password` — `allow_nil? false` — into
  a security-relevant column, and §4.6 of the plan excludes password material from the migration
  deliberately because the legacy hashes are a different scheme and re-hashing needs plaintext nobody
  has. Two resources is the lesser evil, and `ProjectedUser`'s moduledoc says the honest name for it is
  a projection until step 8.

**What this explicitly is not.** A cutover. The legacy database is still the system of record,
`projected_users` is derived, the phase is still `:read_from_legacy`, and **nothing here reduces the
work step 7 will eventually need** — the three `read_only?` mappings are still not invertible, steps 4,
5 and 6 are still unbuilt, and the reverse view still has no way to produce `first_name`. What this buys
is the demonstration, at a fraction of the risk. It should not be read as progress along the phase
model, because it is orthogonal to it.

### Three things found by running it, which are the reason to trust the rest

Each was found by executing something rather than by rereading code, which is the lesson
[`../plans/README.md`](../plans/README.md) says these documents exist to teach.

**1. The backfill and the live projector disagreed.** The task originally rebuilt the attribute map
itself and called the upsert directly — so it skipped the lifecycle transition, and a legacy user in
`suspended` or `passive` sat in `projected_users` marked `:active`. Whether a given row was correct
depended on whether anyone had edited it since the projector started. Invisible in review, obvious in
one `SELECT`. Fixed by making `Projection.project_row/1` the only entry point, with both callers going
through it and a comment at the call site saying why. This is the ordinary fate of a rule expressed in
two places, and it is why `project_row/1` is public API rather than a private helper.

**2. An ordering trap that points both ways.** `mix ash_enterprise.legacy.setup` must run *before* the
migrations, because the strangler view cannot be created against a database where `legacy.users` has
never existed. The projection must run *after* them, because `projected_users` is Ash-owned. Wiring the
projection into `legacy.setup` — where it looks like it belongs, next to the rest of the legacy
plumbing — produced nine `relation "projected_users" does not exist` errors on a fresh database, each
one reported as a **refused row**. One refusal is a data-quality finding worth printing; nine refusals
for the same structural reason is a mistake wearing a finding's clothes. It is now sequenced after
`ash.setup` in the `setup` and `ecto.setup` aliases, and the task opens with an `ensure_table!/0` guard
that raises and explains both orderings. The `test` alias deliberately does *not* project, because every
test that cares seeds the estate inside its own sandbox transaction.

**3. A new resource is invisible until the privilege catalogue is regenerated.** Written up under
*Does it consume ActorContext?* above, because it is a property of the platform rather than of this
change.

### And one pre-existing finding this change did not introduce

`/app/legacy-users` shows nothing to `admin@example.com`. The legacy rows belong to the `legacy`
organization, and both surfaces are tenant-scoped like every other resource here, so the example
tenant's administrator correctly sees an empty table — on both surfaces. The demo has to sign in as
`admin@legacy.example`.

That is correct behaviour and it is confusing, because **an empty table looks exactly like a broken
feature**. `scripts/screenshots/capture-live.mjs` therefore defaults `EMAIL` to `admin@legacy.example`
and carries a comment explaining why, and its own failure list distinguishes *"projected_users is empty
— run `mix ash_enterprise.legacy.project` first"* from *"reached `legacy.users` but never reached
`projected_users`"* so that a capture cannot pass by photographing an empty page. The capture makes the
insert with `psql` rather than through the application, deliberately: a demo where the application
writes its own row and then notices it proves nothing.

### The evidence

`test/ash_enterprise/legacy/projection_test.exs` — **12 tests**, `async: false`. Seven over
`project_row/1` (every row projects; the derived id is carried; lifecycle aligns through the state
machine; both Danas survive; a soft-deleted legacy row stays out; the upsert is idempotent *and*
re-writes rather than no-oping; a row inserted after the backfill projects), three over `notify/1` (a
listener-shaped notification projects; a non-legacy-origin one is ignored; a failing one logs instead of
raising), and two asserting that the projected table is an ordinary platform resource (tenant-scoped and
business-owned; **and audited**, with every event carrying `system_actor == "projection"`).

The `pg_notify` half of the chain is deliberately **not** exercised there: it needs a committed
transaction and a running listener, and the sandbox gives neither. `Legacy.ReadModelTest` asserts the
trigger and the topic wiring; the end-to-end path is asserted by the capture script, which fails the run
if the inserted login never reaches `projected_users`.

### Alternatives rejected

| Option | Why not |
|---|---|
| **Step 7, cutover** — the literal reading of the request | `VerifyReverseMappable` refuses `:read_from_new` over three `invertible: :no` mappings, and its remedy is for the new table to *carry* `first_name`, `last_name` and `state` rather than derive them — which changes the target resource into a copy of the legacy one. Usage rule 20 calls the phase a one-way door. Steps 4, 5 and 6 are unbuilt, and step 5 is the plan's own highest-blast-radius step. |
| **Step 6, dual write** | Closer, and still the wrong direction: it needs `INSTEAD OF` triggers on the view (§4.10), which cost upserts, `RETURNING` and `WITH CHECK OPTION`, and it makes the new table a *writer* of legacy data. Nothing in the request asked to write legacy. |
| A **materialized view** over `strangler.users` | No audit trail, no policies, no `Ash.Notifier`, and `REFRESH` is a whole-relation operation on a schedule — so the live clause of the request would be answered by polling. It would also not be *"the new schema"* in any sense a reader would accept: it is the same view with a cache. |
| A **second `AshStrangler.Listener`** feeding the projector directly | Duplicates the part that is actually hard — re-reading the changed row *through Ash* so mapped values, policies and tenancy apply — and gives two things that can disagree about what a legacy row means. A notifier is the seam that already exists. |
| Project into **`Accounts.User`** | `hashed_password` is `allow_nil? false` and §4.6 excludes password material deliberately. Projecting would mean writing a fabricated hash into a security-relevant column. Two resources is the lesser evil; step 8 is where they become one. |
| Give `ProjectedUser` a **unique `email`**, as a well-modelled table ought to have | It would silently drop one of the two Danas — a new loss introduced by the new model, on top of the defect it inherited. The identity belongs at step 4, behind a migration that fails loudly on data that still violates it. |
| Set `lifecycle_status` **as an attribute** on the upsert | `initial_states [:active]` forbids it, correctly, and working around it would produce an audit trail with no transition in it. Running `:deactivate` costs one extra update per non-active row and buys a record an auditor can follow. |
| Let the notifier **raise** on a bad row, so failures are loud | It would take the listener's process with it, and the listener holds the only `LISTEN` connection — so one bad row stops reactivity on every surface. Loudness has to come from the log, and a test asserts the log rather than merely silencing it. |

## Reversal

**Cheap, and genuinely so, because nothing depends on it.** Delete
`lib/ash_enterprise/accounts/projected_user.ex` and its `resource` line in `AshEnterprise.Accounts`,
`lib/ash_enterprise/legacy/projection.ex`, `lib/mix/tasks/ash_enterprise.legacy.project.ex`,
`lib/ash_enterprise_web/a2ui/projected_user_ui.ex`, the `A2uiLive.ProjectedUsers` module and its
`/app/directory` route, and `test/ash_enterprise/legacy/projection_test.exs`; drop
`AshEnterprise.Legacy.Projection` from `Legacy.User`'s `notifiers` (back to `[Ash.Notifier.PubSub]`);
remove `ash_enterprise.legacy.project` from the `setup` and `ecto.setup` aliases; run `mix ash.codegen`
to drop `projected_users`. An hour, and `/app/legacy-users` is unaffected throughout — the read model
never learned that anything was consuming its notifications.

Two things do not reverse. The **audit events** already written stay in the log, attributed to
`projection`, describing rows in a table that no longer exists — which is the correct behaviour for an
append-only log and is worth knowing before deleting the table. And `SystemActor.projection/0` should
**stay** even if the projector goes: the list is closed and auditable precisely because entries are not
removed when the code that used them is, and historical rows reference the string.

`AshEnterpriseWeb.A2uiLive.Cue` is shared with the legacy surface and stays. It was extracted when the
second live surface arrived, for the ordinary reason: two copies of a component whose interesting
properties are all non-obvious would drift.
