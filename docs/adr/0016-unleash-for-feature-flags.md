# ADR 0016 — Feature flags: FunWithFlags, not Unleash

- **Status:** proposed
- **Date:** 2026-08-18

> This ADR was opened to adopt Unleash and to record its OSS end-of-life as the load-bearing risk.
> Verification reversed the decision and corrected the risk. The filename records where the
> investigation started; the title records where it ended.

## Context

[Thesis 7 entry 11](../manifesto/07-what-we-do-not-have.md#11-feature-flags) states the gap exactly:
*"No `ash_feature_flags`. Use `FunWithFlags` or build it; there is no Ash-native answer, and policies
are not a substitute (they answer may you, not is this on)."* That distinction is why the authorization
model cannot absorb this. A policy answers whether an actor may perform an action; a flag answers
whether the code path exists this week. Conflating them produces a role named `beta_user` — a permission
that has to be revoked from every actor once the feature ships, through the same tables that govern real
access.

Unleash was the expected answer: self-hosted leader, in-SDK evaluation so no actor data leaves your
infrastructure, and an Elixir SDK exists. Four facts, all verified against primary sources on
2026-08-18, changed the answer.

**1. The end-of-life is real and it is not the server.** The 2026-12-31 EOL, with long-term support
from 2025-12-10, attaches to **Unleash Edge OSS**, whose README says verbatim: *"The open-source version
of Unleash Edge is in long-term maintenance mode, with end-of-life scheduled for December 31, 2026. We
recommend that customers migrate to Enterprise Edge."* The [availability
page](https://docs.getunleash.io/support/availability) still lists Open Source as a current edition of
the **server**, with no deprecation row and no announced EOL. The separate `unleash-proxy` is also
deprecated, EOL 2026-11-26. So the risk as originally stated — "the OSS community edition has a stated
end-of-life" — is **false of the server and true of the edge proxy**, and for a server-side Elixir
application Edge is not on the path anyway: backend SDKs evaluate in-process and do not need it.

**2. The server relicensed.** Apache-2.0 → **AGPL-3.0** at v8.0.0 (released 2026-06-09; announced
2026-06-02). Verified by reading `LICENSE` on `main`: plain AGPLv3, no dual-licence clause, no
enterprise carve-out in that file. Official Docker images and the SDKs keep permissive licences, and
pre-v8 releases stay Apache-2.0. Current release v8.1.0, 2026-08-05; repository actively developed.

**3. The OSS server is feature-capped.** Unleash's own OSS-vs-Enterprise comparison limits Open Source
to **one project and two environments**; Enterprise is unlimited. That is a harder constraint than a
licence for anyone with more than a staging and a production.

**4. The Elixir SDK is community-maintained and silently incomplete — and this is what decides it.**
Unleash's [SDK reference](https://docs.getunleash.io/reference/sdks) lists Elixir under *Community
SDKs*; the official backend SDKs are Go, Java, Node, PHP, Python, Ruby, Rust and .NET. The hex package
is `unleash` (not `unleash_ex`), **1.12.7 published 2026-08-10**, MIT, maintained by `afontaine` and
`ulissesalmeida`, sources on GitLab. Its recent releases are housekeeping; the last functional change
was 1.12.0 on 2024-12-19.

Reading the 1.12.7 source: **segments are ignored** — the strategy evaluator reads only
`strategy["constraints"]` — and **flag dependencies are dropped** by the feature parser, which handles
only name, description, enabled, strategies and variants. Neither omission raises. Both evaluate as
though the constraint were absent, so a flag gated behind a segment **returns `true` for users the
Unleash UI says are excluded**.

That is the same failure shape [ADR 0008](0008-typed-invertible-legacy-mappings.md) measured at the
database boundary: no error, plausible result, wrong. It is worse here, because the operator's evidence
that the flag is correctly targeted is a screen in a different system.

For comparison, on the same day: `fun_with_flags` **1.13.0 published 2025-03-23**, MIT, maintained by
`tompave`, **1,022,720 downloads in the last 30 days** against `unleash`'s **151**. Five gates —
boolean, actor, group, percentage-of-time, percentage-of-actors, with the two percentage gates mutually
exclusive on one flag. Persistence via Redis or **Ecto** (PostgreSQL, MySQL, SQLite) with a per-node ETS
cache, and cache invalidation over Redis PubSub **or `Phoenix.PubSub`** — so Ecto plus Phoenix.PubSub
needs no Redis at all. `fun_with_flags_ui` 1.1.0 (2025-03-24) is a Plug, mounted with `forward`.

One more licence note for the shortlist: **Flipt is no longer open source**, having relicensed GPL-3.0 →
the source-available Fair Core License on 2025-01-22. Still genuinely OSS in this category: Flagsmith
(BSD-3-Clause), Unleash (AGPL-3.0), flagd (Apache-2.0), GO Feature Flag (MIT).

## Decision

**`FunWithFlags`, with the Ecto adapter over `AshEnterprise.Repo` and `Phoenix.PubSub` for cache
invalidation, and targeting supplied from `AshEnterprise.Security.ActorContext` through protocol
implementations declared once.**

Unleash is rejected on the bar this repository applies to every external tool: *can it be handed a thin
generated declaration and delegate authorization back to `ActorContext`?* It cannot, and not by
oversight — Unleash is a product with its own user directory, its own RBAC over projects and
environments, its own change log and its own API tokens. Adopting it means a second security model to
keep synchronized with the one in [thesis 3](../manifesto/03-authorization-is-data.md), which is the
duplication that thesis exists to prevent and the same ground [ADR 0014](0014-superset-over-metabase.md)
rejects on the BI side. The AGPL relicence, the project cap and the Edge EOL are all real and all
secondary; the SDK returning `true` for excluded users is the fact that ends it.

FunWithFlags brings no security model at all, which is precisely the property being bought. It is an
evaluation engine and a store. Who may toggle a flag stays where every other access decision lives.

**The Ash leverage is in the targeting.** FunWithFlags resolves the actor gate through the
`FunWithFlags.Actor` protocol and the group gate through `FunWithFlags.Group`. Implementing those two
protocols once for the actor struct means every flag check anywhere gets tenant, business-unit and team
targeting with **no query and nothing passed at the call site**, because `ActorContext` already resolved
`organization_id`, `business_unit_id` and `team_ids` once per request in a plug for the policy engine
(`lib/ash_enterprise/security/actor_context.ex`). The percentage-of-actors gate needs a stable
identifier and `user_id` is one.

That is [thesis 4](../manifesto/04-batteries-are-inherited.md)'s move applied to a new concern: supplied
by declaring it in one place, not by remembering it at every call site. A flag check that must be handed
a targeting map is a call site that can be handed the wrong one — which is, in a different form, exactly
what the Unleash SDK does wrong.

## Does it consume ActorContext?

Yes, as its only source of targeting, and it never queries to get it. The two protocol implementations
read the precomputed struct and do nothing else — the same rule the policy checks obey.

**What it does not consume, and this is the cost.** FunWithFlags's Ecto adapter owns a plain Ecto schema
and its own table. That table is not an `AshEnterprise.Platform.Resource`, so it inherits no audit, no
ownership, no tenancy and no policies. Three consequences, none hypothetical:

1. **Flag toggles are not in the event log.** Enabling a feature for everyone is operationally
   significant and produces no `AshEvents` record and no correlation id, so it will not appear beside
   the changes it caused. Unleash has a change log for exactly this reason; that is one thing the
   product does better, and it is bought by keeping a second system.
2. **Flags are global, not per-tenant.** No `organization_id` on the table. Per-tenant rollout is
   expressible as a group gate keyed on the tenant, which works and is not the same as tenancy being
   structurally enforced.
3. **`fun_with_flags_ui` is a Plug with no authorization of its own.** It must be forwarded behind the
   application's own pipeline; mounting it unprotected hands every visitor a kill switch.

The honest summary: this closes gap 11 for *evaluation* and leaves the *governance* half open. An
`ash_feature_flags` making the flag definition an Ash resource — inheriting audit, tenancy and policies
— while delegating evaluation to FunWithFlags's gates would close both. It does not exist, and this ADR
does not commit to writing it.

## Consequences

**Made easy.** No new service, no second user directory, no network hop on a hot path, no AGPL
obligations to reason about. Ecto persistence means flags are migrated, backed up and restored with
everything else, and Phoenix.PubSub means no Redis is added to the deployment. Targeting is free at
every call site. Removal is a dependency line and a table.

**Made hard.** No audit trail on flag changes, no per-tenant flag storage, and a control panel only as
safe as the router entry above it. FunWithFlags also has no concept of environments — a flag is on or
off in whichever database it reads, so staging and production differ because the databases differ, which
is fine until production data is restored into staging.

**A maintenance signal, stated rather than glossed.** 1.13.0 shipped 2025-03-23; the last commit to
`master` was 2025-09-21, roughly eleven months before this ADR, and five pull requests opened between
2025-10 and 2026-05 sit unmerged without comment. There is no deprecation notice and no
looking-for-maintainer notice, and an unreleased CHANGELOG entry for 1.14.0 exists. For a library taking
a million downloads a month this reads as *finished and low-touch* rather than dying — but that is a
reading, and this line is here so the next person re-checks it instead of inheriting the judgement.
Elixir 1.19 / OTP 28 support is **unverified**.

**Foreclosed.** A vendor-managed flag UI with its own permissions, approval flow and change history. If
that is a procurement requirement this decision does not meet it, and no amount of protocol
implementation will.

## Reversal

Nothing is built. There is no `fun_with_flags` line in `mix.exs`, no adapter configuration, no
migration, and no protocol implementation.

**To adopt Unleash instead:** add `{:unleash, "~> 1.12"}` and run the AGPL-3.0 server with its own
PostgreSQL. Before doing so, resolve three things rather than discovering them: the OSS server's
one-project/two-environment cap; that Edge OSS reaches EOL 2026-12-31 so self-hosted Edge is not a
destination; and that the community Elixir SDK ignores segments and flag dependencies — so either avoid
both features entirely, or budget the SDK patch, which is where the real cost is. Then budget the second
security model as ongoing work: Unleash users, projects and environments must be provisioned and
deprovisioned alongside the application's own, and nothing keeps them in step.

**To swap persistence:** Redis instead of Ecto is a config change and a dependency swap. Worth doing
only if flag reads become hot enough to matter, which the ETS cache makes unlikely.

**To replace FunWithFlags after adoption:** the exposure is two protocol implementations and whatever
module wraps `FunWithFlags.enabled?/2`. Keeping every call site behind one platform module — rather than
calling `FunWithFlags` directly from LiveViews and actions — is what makes this a deletion instead of a
sweep, and is the [thesis 6](../manifesto/06-reversibility.md) seam this decision must carry.
FunWithFlags is **tier 2** by that document's criteria: real and widely deployed, single-maintainer,
watch the version.

**The signal to revisit:** an EOL or licence change for the Unleash *server's* OSS edition rather than
for Edge; the Elixir SDK gaining official status or segment support; or an `ash_feature_flags` appearing
that makes the flag definition an Ash resource. The last would close the half of gap 11 that stays open
here. **OpenFeature** would be the vendor-neutral escape from all of this and is not yet one: the
official Elixir SDK is `open_feature` 0.1.3 (2025-06-24), pinned to spec v0.7.0 while the current spec
is v0.9.0, and absent from OpenFeature's own SDK compatibility matrix. Adopting it today means
maintaining it.
