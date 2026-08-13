# Thesis 6 — Reversibility

> Every alpha, unpublished, or commercial dependency is isolated behind a named seam, with the exit documented.

## Why a reference architecture has to say this out loud

A template's job is to make good defaults easy. Its failure mode is to make bad defaults *permanent* — because the
person who cloned it in year one is not the person discovering in year three that a core dependency was abandoned, is
now paid, or never reached 1.0.

Ash's ecosystem is unusually healthy, but it is not uniform. Some packages are load-bearing infrastructure with millions
of downloads. Others are one maintainer's good idea from eight months ago. Depending on both is fine. Depending on both
*the same way* is not.

So every dependency here is placed in one of three tiers, and the tier determines how much of the codebase is allowed
to know about it.

## The tiers

**Tier 1 — bet on it.** Stable, widely deployed, core-team maintained. Used directly and idiomatically throughout,
with no abstraction layer. Wrapping these would be pure cost.

`ash` · `ash_postgres` · `ash_phoenix` · `ash_json_api` · `ash_graphql` · `ash_authentication` ·
`ash_authentication_phoenix` · `ash_admin` · `ash_oban` · `ash_archival` · `ash_paper_trail` · `reactor` · `igniter` ·
`spark` · `usage_rules` · `phoenix` · `oban`

**Tier 2 — production-viable, watch the version.** Real and useful, but younger or thinner than tier 1. Used directly,
but the version is pinned tightly and the ADRs name what we would do without them.

`ash_ai` · `ash_events` · `ash_state_machine` · `ash_money` · `ash_rate_limiter` · `ash_cloak` · `cinder` ·
`opentelemetry_ash` · `ash_credo` · `ash_ops`

**Tier 3 — isolated behind a seam.** Alpha, unpublished, unmaintained, or commercial. Confined to one directory or one
route. Removing any of these must be a deletion, never a refactor.

`ash_a2ui` (unpublished, git dep) · `clarity` (self-described alpha) · `ash_diagram` · everything commercial

The rule that makes the tiers real: **tier 3 code may not be imported by tier 1 or tier 2 code.** Dependencies point one
way. A resource never knows that `ash_a2ui` exists.

## The seams, specifically

### `ash_a2ui` — unpublished, pre-1.0

The declarative-UI layer is not on hex; it is a git dependency pinned to a SHA, with no example applications and an API
its own README says may change.

That is an acceptable risk *only* because of where it sits. A2UI surfaces live in `lib/ash_enterprise_web/a2ui/`, use
`AshA2ui.Standalone`, and are **separate modules from the resources they describe**. This is why the plan rejected the
alternative of putting `a2ui do ... end` blocks inside resource files: inline UI metadata would have made the domain
layer depend on a pre-1.0 package, and removing it would mean editing every resource.

The exit: delete `lib/ash_enterprise_web/a2ui/`, drop the routes. Every screen it renders has an `ash_admin` equivalent
already, so the application keeps working while a replacement is built.

### `clarity` — alpha, and it maps your whole domain

Clarity is genuinely excellent — navigable ER, class, and policy diagrams derived from live introspection — and its
README says, verbatim, that it is in an alpha state where things may break.

It is mounted **in `:dev` only**. Nothing at runtime depends on it, no module imports it, and it renders a complete map
of the domain model, which is not something to expose in production even behind a login. The exit is deleting one router
line.

### The commercial options we did not take

Open-source-only was a requirement, and it is worth recording that it cost less than expected — and where it did cost
something:

| Commercial option | What we use | What we give up |
|---|---|---|
| **Oban Pro** — durable Workflows, Smart Engine | `Reactor` 1.0 + plain Oban | Reactor's saga orchestration is in-process; it does not survive a node restart mid-workflow. For long-running durable processes, Pro is genuinely better. The seam: orchestration lives in Reactor modules, which Pro workflows could replace one at a time. |
| **Oban Web** — job dashboard | `ash_admin` over the Oban tables + LiveDashboard | A real loss. Job introspection is meaningfully worse. |
| **Fluxon UI** — dense form components | daisyUI 5 + SaladUI 1.0 | Autocomplete, date-range and tags inputs are better in Fluxon. But Fluxon is a closed hex package, so **Claude cannot read or modify its source** — a material cost in an agent-driven codebase, and the reason this was not a close call. |
| **AppSignal** — turnkey APM | OpenTelemetry + `opentelemetry_ash` | `ash_appsignal` is more polished than `opentelemetry_ash` (0.1.x, thin). OTel keeps us vendor-neutral; expect to write more collector configuration. |
| **Tidewave Web** — in-browser agent | Tidewave MCP (free, Apache-2.0) | Only the paid tier's browser automation. The MCP server — the part that matters — is free. |

Each is a swap-in, not a rewrite, because each is confined: orchestration to Reactor modules, components to the web
layer, telemetry to one tracer module and one config block.

## The general rule

Before adding a dependency, answer two questions in the ADR:

1. **What breaks if this is abandoned tomorrow?**
2. **Is the answer confined to a directory I can delete?**

If the second answer is no, the dependency needs a seam before it needs a version number.

This is not a prediction that these packages will fail. Most will not. It is an acknowledgment that a template is copied
by people who will not read its git history, and that the cost of a seam is paid once while the cost of entanglement is
paid forever.

## Further reading

- `docs/adr/` — the per-decision record
- [thesis 7](07-what-we-do-not-have.md) — the gaps no dependency currently fills
