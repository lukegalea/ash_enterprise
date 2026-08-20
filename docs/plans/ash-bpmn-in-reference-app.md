# Plan — AshBpmn and AshDecisions in the reference application

- **Status:** **BUILT.** A process runs here, started by an audited write rather than by a button, and
  five captures of it are in `docs/screenshots/`. Both authoring surfaces are wired — bpmn-js for
  processes, dmn-js for decisions ([§4.12](#412-the-javascript-surface-and-what-was-shipped-late)). Three
  things named in the design did not land and are marked where they appear: any way to *evaluate* a
  decision from the editor, the medium-risk manager branch
  ([§5](#5-the-demonstration-step-by-step)), and an export for in-flight instances
  ([§7](#7-what-this-does-not-prove)).
- **Date:** 2026-08-20
- **Depends on:** [`business-process-modelling.md`](business-process-modelling.md) for the argument,
  [`event-triggered-processes.md`](event-triggered-processes.md) for the trigger and binding design, and
  [`decisions-and-feel.md`](decisions-and-feel.md) for the decision layer.
- **Closes:** the debt [ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md) has carried since it
  was written — two first-party packages declared part of the platform, marketed on the site, scored in
  the roadmap, and present in neither `mix.exs` nor `lib/`.
- **Structured after** [`ash-strangler-in-reference-app.md`](ash-strangler-in-reference-app.md), which is
  the same shape of document about the other half of ADR 0009: why the reference app needs the thing,
  what the thing is, where it collides with the platform, and what the demonstration proves and does not.

---

## 1. Why the reference app needs a running process at all

`ash_bpmn` had a test suite, a designer, a documentation site and a demo application of its own. None of
that answers the question this repository exists to answer.

The manifesto's claim is not that a process engine can be written in Elixir. It is that **the
cross-cutting concerns are declarable once and derived everywhere**, and a workflow engine is the single
hardest test of that claim available, because a workflow engine is conventionally the place where all of
them are re-implemented:

- It has its own **identity** model, because tasks are assigned to somebody.
- It has its own **authorization** model, because approvals are permissions.
- It has its own **audit trail**, because who approved what is the whole point.
- It has its own **tenancy**, because a workflow belongs to a customer.
- It has its own **versioning**, because a running instance must not change shape underneath itself.

[ADR 0015](../adr/0015-approvals-stay-in-ash.md) rejected Camunda and Flowable on exactly that ground:
*"a workflow engine is a second identity, assignment and authorization model."* Rejecting them is easy.
The claim that has to be earned is that a process engine built *inside* the platform inherits all five
instead of restating them — that a process instance is an ordinary owned, tenant-scoped, audited,
soft-deletable record, and that *who may approve* is a role grant evaluated by the same union of grants
as *who may read*.

A package suite cannot demonstrate that. `ash_bpmn`'s own tests run against a bare `use Ash.Resource`
with no platform base, no `ActorContext`, no hierarchy, no audit chain and one tenant. **Every single
defect in [§4](#4-where-it-collides-with-the-platform) was invisible to those tests, which passed
throughout.** That is the argument for the composition being the demonstration rather than a nicety on
top of one.

There is a second reason, and it is the sharper one. Before this work, a process here would have had to be
started by a developer wiring a button to it. *"A developer connected this action to that process"* is a
claim that was already true of `AshBpmn.Changes.RequireApproval`. *"Something happened in the business,
so a process began"* is the claim that was not, and it is the one an enterprise buyer is actually asking
about.

## 2. The scenario: a privileged access request

The demo is **the authorization model approving changes to itself**, and the self-reference is deliberate
rather than cute. It means the demo needs no invented domain — no fictional invoices, no purchase orders
that exist only to be approved. It uses `Security.Role`, `Security.UserRole`, `Security.Privilege`,
`Accounts.BusinessUnit` and `Accounts.User`, all of which are load-bearing elsewhere in the repository
and none of which were added for this.

One new resource: **`AshEnterprise.Security.AccessRequest`** on the platform base, `ownership:
:user_owned`, with a `create :submit` action. It carries **no** `RequireApproval` change. That omission is
the demonstration: the process starts from the *event*, not from the action. It also keeps the package
README's single-gate example honest for anyone who wants that instead — the two mechanisms coexist and the
repository shows the harder one.

Two published baselines live as reviewed artifacts, which is the same posture as
`priv/legacy/schema.sql`:

**`priv/dmn/access_request_risk.dmn`** — one decision, `RiskTier`, one `UNIQUE` decision table:

| Requested role tier | Justification length | → RiskTier |
|---|---|---|
| `"privileged"` | – | `"high"` |
| `"elevated"` | `< 40` | `"high"` |
| `"elevated"` | `>= 40` | `"medium"` |
| `"standard"` | `< 40` | `"medium"` |
| `"standard"` | `>= 40` | `"low"` |

DMN 1.5 (`https://www.omg.org/spec/DMN/20230324/MODEL/`), `expressionLanguage` FEEL, `inputValues` on the
tier column and `outputValues` on the output — the latter is not decoration, it is what a `PRIORITY`
policy would order by and what makes an unexpected output value a publish-time error rather than a
surprise.

**`priv/bpmn/access_request_grant.bpmn`** — one start event, one `businessRuleTask`, one
`exclusiveGateway`, two `userTask`s, three `serviceTask`s, two end events, fourteen sequence flows, and a
full `bpmndi:` section. Every gateway condition is FEEL with `language="feel"` declared:
`routing.risk_tier = "high"`, `routing.risk_tier = "medium"`, `task.outcome = "approved"`.

The `ash:` extension elements are where the architectural line is drawn on the diagram itself:
`ash:decision ref="access_request.risk" binding="latest"`, `ash:inputs`, `ash:promote` with
`ash:signal name="risk_tier" from="RiskTier"`, `ash:taskConfig action="grant_role"`,
`ash:candidates`/`ash:candidate kind="manager_of"`, `ash:exclusions`/`ash:exclusion
who="subject.created_by_id"`, and `ash:timer kind="escalate" hours="24"`. None of them contains a rule or
a query; each names a host callback.

> **A latent defect in that file, found while writing this.** Four `conditionExpression` elements carry
> `xsi:type="bpmn2:tFormalExpression"` and the document **never declares `xmlns:xsi`**. It is therefore
> not namespace-well-formed XML. It parses today because the compiler reads it with `:xmerl` in
> non-namespace-aware mode and bpmn-js tolerates the unbound prefix, so nothing complains — which is
> precisely the profile of a defect that surfaces the first time somebody validates a shipped diagram
> against the BPMN XSD, or opens it in a stricter tool. Recorded rather than quietly fixed, because *how*
> it stayed invisible is the more useful half.

## 3. How it gets published and seeded

Baselines are **code, not UI**. Publishing into the platform organization is impossible from the web:
there is no route to it and no action reachable by a human actor. Two mix tasks, in this order:

```
mix ash_enterprise.bpmn.publish    # priv/dmn/* then priv/bpmn/*, into the platform org
mix ash_enterprise.bpmn.setup      # triggers per tenant, three requests, a fork, and a drain
```

**Decisions publish before processes**, because a `businessRuleTask` is verified against the decision it
names at publish time — `AshBpmn.Compiler.Verify` calls the configured resolver's `exists?/1`. Publish them the
other way round and the process refuses with the decision reference in the error, which is the correct
behaviour and an annoying way to discover an ordering.

Both tasks are **idempotent by `content_hash`**, which matters more than it sounds: without it every
deploy mints a new version of every definition, tenants drift against a baseline that never actually
changed, and the version numbers stop meaning anything. This is the same choice `seed_legacy_estate`
makes and the opposite of `seed_tenant`, which refuses to re-run on purpose.

**The seed must drain the queue between steps.** Oban runs asynchronously in dev, so a seed that submits
and exits leaves every instance parked on its start node — and every screenshot then shows an idle system
that technically works, which is the difference between a demo and a picture of one. `drain/1` runs the
sweep worker synchronously and then `Oban.drain_queue(queue: …, with_recursion: true)` for **both**
`:bpmn` and `:default`.

**And the cursor must be established before anything is submitted.** A trigger cursor created at sweep
time starts at the tenant's current high-water mark, which is correct — a trigger fires on what happens
after it exists, and starting at zero would replay a tenant's entire history and start a process for
every matching event that ever happened. It is wrong for a seed, which submits and *then* sweeps: every
seeded request would land behind the cursor and dispatch nothing. `SweepWorker.ensure_cursor/1` runs
first, which is what publishing a trigger normally does.

## 4. Where it collides with the platform

Twelve resources arrive here: six from `ash_bpmn`, two from `ash_decisions`, and four written here
(`Trigger`, `TriggerCursor`, `TriggerDispatch`, `Binding`). **All twelve sit on
`AshEnterprise.Platform.Resource`** — the package ones through `:base`/`:base_opts` on the resource
macros, the local ones by `use`ing it directly. That is the claim. What follows is what it cost.

Every subsection below is a real failure that reached a running system, and **all of them were invisible
to the package test suites**, which passed at every point.

### 4.1 The engine's authority is a bypass, and declaration order decides whether it works

`ash_bpmn` used to pass `authorize?: false` at roughly ninety internal call sites. It does not any more:
`AshBpmn.Scope.engine/2` sets `context: %{private: %{ash_bpmn?: true}}` and every generated resource
declares one policy recognising it:

```elixir
bypass AshBpmn.Checks.AshBpmnInteraction do
  authorize_if always()
end
```

That is a better design for a reason worth stating precisely: the engine keeps the **human** actor.
Ownership, provenance and the audit entry still name the person who approved, which is exactly what an
`engine_actor` configuration would have destroyed. `config :ash_bpmn, engine_actor:` exists and is
rejected here for that reason.

**But a bypass in Ash covers only the policies declared *after* it.** Ash folds a resource's policies
into one boolean expression in which a bypass contributes a disjunct over what follows. A base resource
emits its policy set from `use` — ahead of anything the package adds. So a work item on
`AshEnterprise.Platform.Resource` reaches the engine's bypass *second*, the base's restrictive policies
have already had their say, and **the engine is forbidden**.

The fix is three lines in the right place. `AshEnterprise.Security.Policies` declares, in this order:

1. `bypass AshBpmn.Checks.AshBpmnInteraction`
2. `bypass AshDecisions.Checks.AshDecisionsInteraction`
3. `bypass AshEnterprise.Security.Checks.SystemActor`
4. …then the role model.

The precedent for prepending was already there: the `authentication?:` option prepends
`AshAuthentication.Checks.AshAuthenticationInteraction` for exactly the same reason. Declaration order
*is* policy order for a set injected by `use`, and that is the sort of fact that has to be written in the
file rather than remembered.

**One `authorize?: false` remains in `ash_bpmn`, deliberately.** `AshBpmn.Scope.subject/2` reads the
*host's* subject record, which no `ash_bpmn` policy governs — an engine scope there is simply a denied
read, because the context flag is recognised only by the policy the resource macros generate. It keeps
`authorize?: false` and says why, so it does not look like the ninety that were removed. A test fails the
build if a second one appears.

### 4.2 A work item has no owner until someone claims it

`HumanTask` was modelled `:user_owned`, which the platform base implements as a non-null `owner_id`. The
engine could not create one.

The modelling error is the interesting part, not the constraint. **An open approval is unassigned on
purpose** — that is what makes it claimable by any of its candidates. Inventing an owner at creation
would mean either the requester, whom maker-checker explicitly excludes, or an arbitrary candidate to
whom the task does not yet belong.

So `HumanTask` is `:organization_owned`, and access is governed by `TaskCandidate` rows: materialised at
task creation, with the exclusions applied **by subtraction during candidate resolution**, never as a
`forbid_if`. A task list is then one indexed query joined on the actor's principal ids. That is
[thesis 3](../manifesto/03-authorization-is-data.md)'s mechanism reused rather than an exception carved
for workflow, and it is why non-negotiable 2 survived contact with the single feature most likely to
break it.

### 4.3 `ctx[:tenant]` is nil on several engine paths

Three host callbacks assumed a tenant in the engine context and produced three different symptoms, none
of which said "no tenant":

- a null `organization_id` rejected by a database constraint;
- a decision evaluation written invisibly to the tenant that caused it;
- a candidate query that returned nobody, so a task existed with no one able to claim it.

`AshEnterprise.Process.EngineContext` derives the tenant once, from records the engine has already
loaded, and every callback goes through it. The general shape is worth naming: **a multitenant platform
receiving callbacks from a tenant-agnostic engine will get nil tenants on some paths, and the failures
will be diverse and silent.** One derivation module is the cheap answer; assuming the context is the
expensive one.

### 4.4 A system actor the policy set had never heard of

A service task called host actions as `AshBpmn.SystemActor` — the package's own notion of a machine
caller. `AshEnterprise.Security.Policies` has never heard of it. The action was **forbidden, silently,
mid-process**: the instance simply stopped advancing.

This is the generic hazard of a package that ships an actor type. There are two ways out and only one is
right: teach the platform about the package's actor (a second system-actor concept, which is a second
thing to keep in step) or have the package use the host's (`AshEnterprise.Platform.SystemActor`). It uses
the host's.

### 4.5 Authority and accountability are different columns

`start_instance/2` derived `started_by_id` from `actor.id`, so starting a process as a system actor
raised. Fixed upstream, and the sentence that came out of it is the reusable one: **authority and
accountability are different columns.** The actor is who may do this; `started_by_id` is who is answerable
for it, and for an event-triggered process those are genuinely different entities.

Which is the same reason an event-triggered process runs as a named trigger system actor with the human
in `started_by_id` and the correlation id carried through. A process outlives a session, and a session's
authority must not outlive it — rebuilding the requester's `ActorContext` would give the instance their
grants for days, surviving their offboarding. The context is also genuinely gone by sweep time, and
rebuilding it costs five queries and produces a *different* context. **Human decisions inside the process
are still attributed to the human**, because claiming and completing a task arrive on a real request.

### 4.6 A baseline needs a tenant, and there is no way to have no tenant

`:base` plus `tenant?: true` raises by design, and the platform base makes `organization_id`
`allow_nil? false`. So a NULL-tenant baseline row is **impossible**, and relaxing that to serve one
resource would weaken the tenancy invariant for every resource in the application.

The answer is a real `Organization` row, `unique_name: "platform"`, with no business units, no roles and
no sign-in, excluded from tenant listings, memoised in `:persistent_term`. It is the only cross-tenant
read in the design and it lives in one named function rather than as `tenant: nil` sprinkled through the
engine.

Two things the tests corrected rather than confirmed, both worth carrying:

- **`identity :one_per_tenant, []` cannot be expressed that way.** Ash rejects an empty key list, so
  "unique on the tenant column" has to be said the other way round: `[:organization_id]` with
  `all_tenants? true`. Same index, only the spelling the DSL accepts. And Postgres treats NULLs as
  distinct, so the NULL-tenant cursor row is *not* actually protected by it — which the moduledoc says
  rather than implies.
- **"The platform organization has no users" is not a checkable claim.** `Accounts.User` is
  `tenant?: false`, so users are not scoped to an organization at all and the query returns every user in
  the system. The assertion is on business units and roles, which are scoped.

### 4.7 The definition loader, and the silent failure that proves the seam

A tenant's instance is pinned to a definition that lives in the *platform* organization. Without a host
callback to load it, the instance could not find its own definition — and the symptom was that the token
claimed successfully and the process sat at its start node **with no error anywhere**.

That is exactly the silent failure a named seam exists to prevent, arrived at by not configuring the
seam. `AshEnterprise.Process.DefinitionLoader` is three of the four host callbacks' shape:
`AssignmentResolver`, `ActionInvoker`, `DecisionResolver`, `DefinitionLoader`. Each is a place the graph
declines to decide something, and each is a place a missing configuration must be a loud error rather
than a stall. `AshBpmn.Config.decision_resolver!/0` raises instructively when unset for the same reason.

### 4.8 Audit, and the choice not to audit

Not all twelve resources carry the audit hook, and the choice is about signal rather than cost.

| Resource | Audited | Why |
|---|---|---|
| `Definition` (process and decision) | yes | Someone changed how the business works. |
| `HumanTask` | yes | Someone approved something. |
| `Binding` | yes | Rebinding a workflow is exactly what an auditor should find in the log. |
| `Instance` | yes | A process started, and against what. |
| `Token` | **no** | Engine bookkeeping. Thousands of rows saying nothing `ProcessEvent` does not say better. |
| `ProcessEvent` | **no** | It *is* the engine's log. Auditing it would be auditing an audit. |
| `Evaluation` | **no** | Same: it is append-only evidence in its own right. |
| `TriggerCursor`, `TriggerDispatch` | **no** | Cursor is position; dispatch is its own append-only ledger. |

The rule underneath the table is that **two logs which overlap will disagree**, and the one that
disagrees more quietly is the one that gets believed. `ProcessEvent`, `Evaluation` and `TriggerDispatch`
each record what the audit log structurally *cannot* — a token moving, a decision answering, an event
being considered and declined — and none of them duplicates a row change.

`TriggerDispatch` earns its place on a second ground. One row per `(trigger_id, event_id)`, written in
the same transaction as the instance start, so duplicates are provably impossible under partial failure —
and, more valuably, it answers **"why did this process start?"**, which is the question an auditor
actually asks and the one no row-change log can answer.

### 4.9 The queue configuration that never reached job insertion

`Oban.Worker.new/2` takes the queue from the worker's **compile-time** options. `ash_bpmn`'s workers
declared none so that host configuration could decide — but a `queue/0` override does not affect
insertion. So every job went to `:default` while the `:bpmn` queue configured here sat empty: the
isolation the configuration exists to provide, absent, with the jobs running perfectly somewhere else.

Fixed upstream. The residue is in the seed, which drains both `:bpmn` and `:default` because jobs
enqueued before the fix sit on the latter — a small, honest piece of migration debris.

### 4.10 Nothing rescued orphaned jobs

A node dying mid-advance leaves its job `executing` forever: `drain_queue` will not take it and no other
node will claim it. For a *durable* process engine that is the one failure mode that must not be
possible. `Oban.Plugins.Lifeline` is now configured. Found by killing a seed run and watching three
instances stick.

### 4.11 The privilege catalogue is derived from the resources that exist

Adding `AccessRequest` created privileges nobody held. The catalogue for an already-provisioned tenant
may not have them at all, so the Administrator role silently stopped reaching the new resource — and the
symptom is a forbidden write on a resource the administrator can plainly see in `ash_admin`.

There was no idempotent path to fix it, because re-running the tenant seed refuses on purpose.
`Seeder.regrant_administrator_privileges/1` is that path, and it is deliberately **only** for the
Administrator role: widening a customer's own roles automatically would be the platform quietly changing
who can do what, which is the opposite of what an authorization-as-data model is for.

This is a general consequence of deriving a privilege catalogue from the resource set: **adding a
resource is a migration of the authorization data, not only of the schema.**

### 4.12 The JavaScript surface, and what was shipped late

`assets/package.json` went from five dependencies to seven — `bpmn-js ^18.0.0` and `dmn-js ^17.10.1` —
`assets/package-lock.json` from 25 packages to 88, and `assets/node_modules` is now **86 MB**, of which
bpmn-js is 6.8 MB and dmn-js 7.5 MB. Hand-written JavaScript went from 159 lines to **165** in
`assets/js/app.js`, all six of them imports and a hook registration; the bundle esbuild emits is 9.3 MB
with a 568 KB stylesheet beside it. Both libraries earn it: a BPMN canvas and a DMN decision table have no
server-rendered equivalent, and hand-rolling either would be more JavaScript than importing both. This is
still a repository whose *authored* client code is a rounding error and whose *installed* client tree
tripled.

Three build changes are load-bearing rather than tidy, and the second stops the build outright:

1. **`NODE_PATH` must include `assets/node_modules`.** The hook lives in `deps/ash_bpmn/priv/js/` and
   imports `bpmn-js`; Node resolution walks up from the *importing* file, so without it esbuild searches
   `deps/ash_bpmn/node_modules` upwards and never reaches the assets directory.
2. **The icon font needs dataurl loaders.** `bpmn-embedded.css` references `bpmn.woff/woff2/ttf/eot/svg`
   by relative path, and the existing args carry `--external:/fonts/*` with no font loaders, so the build
   **errors** on the unresolved `.woff`. Inlined as data URLs, which the CSP's `font-src 'self' data:`
   already permits.
3. **Every package shipping LiveViews needs its own `@source` line** in `assets/css/app.css` — now two of
   them, `deps/ash_bpmn/lib` and `deps/ash_decisions/lib`. See the finding below: this is the one that
   presents as a working editor that looks broken.

And one that is silent: esbuild emits a second stylesheet at `priv/static/assets/js/app.css` because the
hooks import CSS. `root.html.heex` linked only `/assets/css/app.css`, so the designer rendered as
unstyled boxes — **worse than a broken script**, because it looks like a bad diagram rather than a
missing file.

Two more findings from the same pass:

- **Tailwind was not scanning `deps/ash_bpmn`.** `@source(none)` means nothing is scanned unless it is
  named, so every class in the package's shipped LiveViews resolved to nothing: the canvas had no height
  and the whole editor looked broken rather than unstyled. The lesson transferred: `deps/ash_decisions/lib`
  was named in the same pass that wired the DMN editor, rather than after debugging it a second time —
  which is the only kind of evidence that a finding was actually learned.
- **The CSP needed no change, which is worth recording so it is not re-litigated.**
  `style-src 'self' 'unsafe-inline'` covers diagram-js's inline styles, `font-src 'self' data:` covers the
  loaders, `img-src 'self' data: blob:` covers the icon-font palettes, and nothing here spawns a Worker.
  The one thing that *would* force a change is a "test this expression" button calling a remote FEEL
  service — it must not; FEEL evaluation is server-side over the LiveView socket.

**The watermark is a licence obligation with two consequences here.** bpmn-js and dmn-js both carry the
bpmn.io licence: the source displaying the "Powered by bpmn.io" attribution must not be changed and it
must stay fully visible and unoverlapped. So Tailwind preflight and the design system must not collapse
`.bjs-powered-by`, **and screenshot cropping must not cut it off** — a real hazard, since the capture
crops to the designer root. The capture script waits on `.bjs-powered-by` as its readiness signal
precisely because it is both the proof the editor booted and the thing the licence requires; the honest
caveat is that a missing selector currently only warns rather than failing the run.

**The decision editor landed last, and the catalogue is where the interesting decision is.**
`/app/decisions/:key/editor` mounts `AshDecisions.Web.EditorLive`, dmn-js is registered as the
`AshDecisionsEditor` hook, and `/app/decisions` is no longer read-only: a baseline row offers
**"Customize"** and a customized row offers **"Open editor"**. Three things about that arrangement are
argued in [`decisions-and-feel.md`](decisions-and-feel.md) §4 rather than repeated here — that forking is
an explicit act on a button rather than a side effect of opening an editor, that the view tabs are
server-rendered on purpose, and that a new draft's template is DMN 1.3 because 1.3 is what dmn-js can
open.

The one that matters *here*, because it is a property of the platform rather than of the package: **a
design in which opening an editor forked the baseline would have quietly broken the load-bearing default**
that absence of a binding means "follow the baseline"
([`event-triggered-processes.md`](event-triggered-processes.md) §8). Every visit would have become a
customization, onboarding would accumulate rows nobody asked for, and never-customized would stop being
distinguishable from customized-then-reverted. The fork is also attributed to the signed-in administrator
rather than a system actor, because forking a rule set is a person's decision and the audit entry should
name them.

> **Two gaps remain in the authoring story, and both are ours.** There is **no way to evaluate a decision
> from the editor** — no panel for sample inputs, no view of which row fires — so an author edits a table,
> publishes it, and has never watched it answer; the first real evaluation of a new rule happens inside a
> live process. And there is still **no FEEL editor**: `@bpmn-io/feel-editor` is MIT, arrives transitively
> with dmn-js, and is unused, so the most error-prone text in a decision table is typed into a plain
> input. Until the first of those exists, "a business analyst changes a threshold without a deploy" is
> half demonstrated: they can change it, and they cannot try it.

### 4.13 The advisory lock the design specified is not there, and that is the correction

[`event-triggered-processes.md`](event-triggered-processes.md) §3 specifies one writer per tenant holding
a `pg_advisory_xact_lock` and walking the cursor, on the sound reasoning that the audit table cannot be
marked so there is no per-row state to reconcile against. `grep` for `pg_try_advisory` or
`pg_advisory_xact_lock` under `lib/` returns nothing outside the *documentation* of the lock `ash_events`
itself takes. **There is no lock in the sweep.**

It was removed because the design failed in two ways when built, both worth carrying:

- **One transaction around the batch means one bad event takes the batch.** A database error anywhere in
  a Postgres transaction *aborts* it, so catching the exception changes nothing — a service task that
  raised took an entire sweep with it, instance and all. Found by watching exactly that happen. Each
  event now dispatches in its own transaction.
- **A session-scoped lock needs connection affinity that a pooled repo does not promise.**

What makes it correct without a lock is three things stacked, and the middle one is the arbiter: Oban's
`unique` on `{worker, tenant}` means a second sweep is usually not enqueued; if two do run,
`TriggerDispatch`'s `[:trigger_id, :event_id]` identity is written **in the same transaction as the
instance start**, so the loser's insert conflicts and its instance rolls back with it; and the cursor
makes completeness independent of either, because an event missed by a racing sweep is still behind some
cursor.

The `SweepWorker` moduledoc still describes the lock design. It is the one piece of prose in this area
that has gone stale, and it is recorded here rather than fixed silently because *"the design document and
the module docstring both describe a lock that the code beneath them does not take"* is the exact shape of
thing that costs somebody a day in six months.

### 4.14 The nav wraps, and the screenshots are 1440 wide

Six top-level nav items plus four more wrap below about 1400px, and every documentation capture is taken
at 1440×900. So a wrapped nav would appear in every screenshot. The four new pages are grouped under one
dropdown. A trivial fix, recorded because the *reason* is not obvious from the code and the next person
adding a page will hit it.

## 5. The demonstration, step by step

1. **Submit.** `AccessRequest.submit` — one audited write, one `audit_events` row with a `sequence` and a
   hash-chain link.
2. **Match.** The trigger `access_request.submitted` matches `{AshEnterprise.Security.AccessRequest,
   :create, "submit"}`. Structurally, in an ETS index keyed on `{resource, action_type}`, so an audited
   write on a resource no trigger watches costs nothing.
3. **Guard.** FEEL, in-process, no I/O: `string length(data.justification) > 30`.
4. **Route.** The DMN decision `access_request.risk` is evaluated with `requestedRoleTier` and
   `justificationLength`, and returns `RiskTier`.
5. **Run.** The process `access_request.grant`: the `businessRuleTask` `AssessRisk` invokes the decision
   and promotes `RiskTier` onto the token as the signal `risk_tier`; the `exclusiveGateway` reads
   `routing.risk_tier` in ordinary FEEL; a `userTask` materialises candidates from `manager_of` with
   `subject.created_by_id` excluded by subtraction and a 24-hour escalation timer; a `serviceTask` calls
   `UserRole.assign` through the invoker — an ordinary Ash action, ordinary policies, ordinary audit row.
6. **Diverge.** One tenant forks `access_request.grant`, so the catalogue has a real drift subject and the
   designer opens a real diagram rather than a blank template.

Nine tests assert those steps, and **every one of them was an argument in a document before it was a
passing assertion**, which is the thing the plans exist to make possible.

**Two seeding facts, stated because the moduledoc is wrong about them.** The task's own documentation
claims "four requests to four different states"; the code submits **three** per tenant and its fourth
listed item is the fork, which is a definition rather than an instance. And with the guard at
`> 30` characters and the DMN boundary at `< 40`, all three seeded requests route to `low` or `high` — so
**no seeded request lands on the `medium` manager branch**, and that branch of the diagram is exercised
by tests but not by anything a screenshot can show. Both are small and both are the kind of drift between
a comment and its code that this section exists to catch.

**A promoted signal may not have to share a name with the decision's output**, and finding out that it
did was the point. `RiskTier` and `risk_tier` are two vocabularies owned by two different people — the
analyst who drew the decision table and the analyst who drew the process — and forcing them to agree
couples two documents that should only agree on a *reference*. `ash:signal from=` separates them.

## 6. What this proves that a button-wired process cannot

Five things, in descending order of worth.

1. **That a process instance is an ordinary record.** Twelve resources on the platform base means audit,
   telemetry, ownership, tenancy, soft delete and the policy set arrive by inheritance. The claim is
   falsifiable and was nearly falsified four times — §4.1, §4.2, §4.3, §4.6 are each a place the platform
   and the engine disagreed, and each was resolved by changing the engine or the modelling rather than by
   exempting the resource. **An exemption would have been the interesting negative result**, and there
   is not one.
2. **That maker-checker survives without a deny rule.** [Non-negotiable
   2](../manifesto/03-authorization-is-data.md) forbids `forbid_if` for row access, and segregation of
   duties is the canonical reason people write one. Doing it by subtraction at candidate resolution —
   §4.2 — is the whole argument, and it is now a running approval rather than a paragraph.
3. **That "something happened, so a process began" is achievable over an append-only log.** The audit
   table cannot be marked, so it has no per-row state to reconcile against. A cursor walked once per
   tenant is what makes dispatch complete, and `TriggerDispatch`'s identity — written in the same
   transaction as the instance start — is what makes it safe under concurrency. Neither of those is
   available to a system that reacts to notifications.
4. **What a host callback boundary actually costs.** Four seams (`AssignmentResolver`, `ActionInvoker`,
   `DecisionResolver`, `DefinitionLoader`) keep the graph from deciding, authorizing or querying. §4.7 is
   the price: a seam that is not configured fails *silently* unless it is written to raise, and one of the
   four was not.
5. **That two first-party packages can be adopted without becoming the platform.** Both remain tier 3
   under [thesis 6](../manifesto/06-reversibility.md). Removing them is deleting a domain module, a
   `live_session`, six routes, a LiveView directory and two dependencies — not refactoring anything.

## 7. What this does not prove

- **That in-flight state is recoverable.** There is **no export**, in either package. `mix
  ash_decisions.export` was named in the design as a day-one requirement precisely so that ADR 0009's
  admission — *"In-flight process instances are lost; there is no export"* — would not be repeated
  knowingly. It was not built. The mitigating facts are real but partial: the authored XML is a column,
  so every definition survives a `COPY`, and all instance state is ordinary Postgres rows in this
  application's own tables rather than an engine's private schema. That means the data is not *lost*. It
  does not mean there is a migration path to another engine, and the difference is the whole content of
  the claim.
- **That a business user can change a rule *correctly*.** Both designers are shipped, so the editing half
  is real. The verifying half is not: nothing in the UI evaluates a decision against sample inputs, so an
  author cannot see the table fire before publishing it, and there is no FEEL editor to catch a malformed
  unary test as it is typed (§4.12). Add that the compiler does not parse input entries at publish time
  and that `matched_rule_ids` is always empty, and the loop is open at both ends: the author cannot try
  the rule, and the audit trail afterwards cannot say which row of it fired.
- **Scale.** Three instances per tenant across two tenants. One sweeper per tenant — deduplicated by Oban
  uniqueness rather than by a lock (§4.13), in batches of 500 — is a throughput ceiling, and the ceiling
  is unmeasured. So is the cardinality bound on
  candidate materialisation, which
  [`business-process-modelling.md`](business-process-modelling.md) §10.1 already called the single most
  likely thing to be redesigned after first contact — it has now had first contact and has not been
  measured under load.
- **That the process survives a deploy.** Definitions are immutable and instances pin them, so the *shape*
  survives. What a snapshot does not pin is behaviour: an action a live instance names can be changed or
  deleted and the snapshot will not notice. §10.3 of the same document said so and nothing here closes
  it.
- **Expressiveness.** One process, five rules, one tenant customization, chosen by us and mapped to a
  model we also chose. A second unrelated process — ideally one nobody here designed — is what would test
  the executable subset.

## 8. What remains

In the order they are worth doing:

1. **Evaluate a decision from the editor.** The largest remaining gap between what a decision layer
   claims and what this one does, and the smallest to close: `AshDecisions.Evaluator.evaluate/3` already
   takes `record: false` precisely so a designer probe does not write an evidence row.
2. **Publish-time overlap and completeness analysis.** [`decisions-and-feel.md`](decisions-and-feel.md)
   §7. Designed, argued, and not built; the technique is already proven next door in `ash_strangler`.
   Together with the item above it is the difference between an author guessing and an author knowing.
3. **Wire `@bpmn-io/feel-editor`.** MIT, already in `node_modules` as an unused transitive dependency of
   dmn-js, and it covers the one part of a decision the compiler does not fully validate at publish time.
4. **An export.** For decision definitions first, because it is easy, and then the harder conversation
   about in-flight instances.
5. **A seeded request on the `medium` branch**, so the manager approval path appears in a capture rather
   than only in a test.
6. **Declare `xmlns:xsi`** in the shipped BPMN document, and add a compiler check that refuses an unbound
   namespace prefix so the class of defect cannot recur.
7. **Capture the DMN editor and the DRD**, and replace the two stale captures. There is no `dmn-*.png`
   in `docs/screenshots/` at all, so the newest surface in the application is the one with no picture of
   it. `bpmn-designer-user-task.png` and `bpmn-viewer-running.png` are
   still captures of `ash_bpmn`'s own `dev/` application — different chrome, different theme, different
   nav, no tenant. `docs/README.md` says `screenshots/` "holds real captures of the running application",
   and by that standard these are captures of a different one.

## Capturing it, and why the capture has to be able to fail

The first attempt at documenting this produced a perfectly sharp, correctly cropped, high-resolution
screenshot of a stacktrace, and filed it as documentation. That is not a hypothetical hazard; a Phoenix
error page screenshots very happily.

So `scripts/screenshots/capture.mjs` is written to **refuse to produce an image of a broken page**, and
the distinction it encodes is the useful part: predicting a Content-Security-Policy outcome from its
directives is verifying the *part*, and loading the page and reading what the browser actually says is
verifying the *outcome*. The script does the second. It signs in, because every surface here is behind
`live_user_required`; it reads the browser console and exits non-zero on any message naming a CSP
refusal; and it checks the rendered body for the signatures of a Phoenix error page.

It found three real defects that no test had:

- **The task list crashed.** `principal_ids: {Module, :fun, []}` was stored with `Macro.escape/1`, but a
  macro option arrives as AST — so escaping stored the AST *of that AST*, and the module reached
  `apply/3` as an unexpanded alias tuple. `ArgumentError: 2nd argument: not an atom`, with nothing naming
  the option. Fixed upstream; `ash_bpmn`'s own suite passes a literal list and takes the other clause
  entirely, which is why its tests were green.
- **The designer rendered nothing**, for the two stacked reasons in §4.12 — a missing `bpmndi:` section
  and Tailwind not scanning `deps/`.
- **The sign-in page had always had a CSP violation.** The default authentication banner points at an
  image on `ash-hq.org`, which `img-src 'self' data: blob:` refuses. Every visitor had seen a broken
  image and the only report was in a console nobody read. Overridden to a local icon rather than widening
  the policy: a sign-in page that fetches from a third party is a beacon on the one page an
  unauthenticated visitor is guaranteed to load, and the CSP is right to refuse it.

The procedure is recorded in [`../README.md`](../README.md) rather than only in `docs/HANDOFF.md`, because
a capture procedure that lives only in a handoff document is a fact one session deep.

## Further reading

- [ADR 0029 — process and decision configuration is tenant data](../adr/0029-process-configuration-is-tenant-data.md)
  and [ADR 0030 — events trigger processes through a dispatched cursor](../adr/0030-events-trigger-processes.md) — the
  two decisions §4.6 and §4.13 are the consequences of.
- [`ash-strangler-in-reference-app.md`](ash-strangler-in-reference-app.md) — the other half of ADR 0009,
  same shape of document.
- [`decisions-and-feel.md`](decisions-and-feel.md) — the decision layer's design and its honest limits.
- [`event-triggered-processes.md`](event-triggered-processes.md) — triggers, cursors, baselines and
  bindings, with the Postgres measurements the dispatch guarantee rests on.
- [`business-process-modelling.md`](business-process-modelling.md) — the original argument, and the
  correction appended to it.
- [thesis 7 §3](../manifesto/07-what-we-do-not-have.md#3-approval-workflows--maker-checker) — what is
  still missing, stated as a gap.
