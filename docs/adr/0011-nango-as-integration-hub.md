# ADR 0011 — Nango as the integration hub, wrapped as Ash actions

- **Status:** accepted (2026-10-12; built for Google Calendar, Gmail and Slack, see the implementation note)
- **Date:** 2026-08-18
- **Amended (deviations recorded):** 2026-10-09 — see [Dogfood deviations](#dogfood-deviations-2026-10-09) at the end of this document.
- **Implementation note:** 2026-10-12, at the end of this record

## Context

Outbound integration is an M×N problem. For every pair of (this application, their API) somebody writes OAuth
setup, token storage, refresh-before-expiry, rate-limit backoff, pagination, webhook receipt and webhook
signature verification. None of it is domain logic, all of it is security-sensitive, and the copy written for
the eleventh provider is the one with the refresh race in it.

The failure mode this repository actually cares about is not the volume of code. It is that integration code
conventionally grows its own **integration log** — a table recording "we called Salesforce at 14:02" that is
separate from the audit log, has no correlation id, and answers a different question from
`AshEnterprise.Audit.EventLog`. That is [thesis 5](../manifesto/05-agents-are-users.md)'s confused-deputy
argument pointed outward: a second code path with a second record of what happened.

### Verified 2026-08-18

| | Nango | n8n | Windmill |
|---|---|---|---|
| Licence | **Elastic License 2.0**, single licence, no dual | **Sustainable Use License v1.0**, plus a separate n8n Enterprise License for paths matching `.ee` | **Tri-licensed**: Apache-2.0 *or* AGPLv3, "plus a proprietary license for certain enterprise features" |
| Latest release | v0.71.4, 2026-08-10 | 2.36.0, 2026-08-18 | v1.792.1, 2026-08-18 |
| Last commit | 2026-08-18 | — | — |
| Scope | provider edge: auth, proxy, syncs, webhooks; 900+ APIs | visual workflow automation | script-first automation, auto-generated UIs, flow editor |

Two findings materially changed this decision and both cut against the obvious write-up.

**The free self-hosted edition covers auth and the proxy only.** Nango's own self-hosting guide describes it as
"a limited free self-hosting option… intended for lightweight deployments that need Auth and Proxy, without the
managed features." Functions, **syncs**, **webhooks** and the MCP server require Enterprise self-hosting or
Nango Cloud. So the feature an `ash_nango` extension would most naturally be built on — one Ash action
generated per Nango *sync* — is precisely the gated one. *Whether "Enterprise self-hosting" is a paid contract
or merely a licence key could not be determined from the pricing page and is recorded as unverified.*

**Nango no longer sells itself as a unified API.** Their current writing argues *against* category-normalized
models, contrasting explicitly with Merge.dev: "custom fields, custom objects, and provider-specific features
cannot be represented in the normalized schema." So "write the contract once per category (CRM, accounting)"
is not what this tool does in 2026. It removes the N of transport and auth; the M of schema mapping stays ours.

n8n and Windmill solve the **adjacent** half and are not substitutes. Nango sits at the provider edge —
credentials, tokens, transport. n8n and Windmill are orchestration glue: they sequence steps across systems.
This repository already has an orchestrator with compensation semantics (`Reactor`, ADR 0004) and a durable
queue (Oban), so the orchestration half is answered and the provider-edge half is not. Adding n8n or Windmill
would introduce a second workflow engine whose steps run outside every policy in this codebase — which fails
the selection bar outright, before licensing is even discussed.

## Decision

**Adopt Nango for the provider edge only — connection auth and the proxy — and generate one Ash action per
declared provider operation. Sync logic lives here, as Ash actions over Oban, not as Nango syncs.**

This inverts the obvious design, and the reason is the licence gate: building the integration layer on Nango
syncs makes the load-bearing component the paid one, and a template must not have its central mechanism behind
a tier its reader may not have.

An `ash_nango` extension takes a declaration in **this** repository:

```elixir
nango do
  provider :salesforce
  operation :fetch_accounts, method: :get, path: "/services/data/v60.0/query", returns: AccountPayload
end
```

and generates a generic Ash action per operation whose run step is a Nango proxy call. What that buys is the
whole of [thesis 5](../manifesto/05-agents-are-users.md)'s argument applied to an outbound call:

> An `ash_ai` tool is not a new code path. It is a *declaration that an existing action may be called by a
> model.*

Extended here: **an external integration is a declaration that an existing action may be invoked against a
remote system — not a parallel code path.** The consequences follow mechanically rather than by discipline.
The policy engine decides *which actor may trigger which provider operation*, using the same
`(role, privilege, depth)` rows as everything else. The call appears in `AshEnterprise.Audit.EventLog` with
the request's correlation id, because `AshEnterprise.Platform.Changes.StampCorrelation` applies to it like any
other platform action. **There is no integration log**, because there is nothing left for one to record.

## Does it consume ActorContext?

**The generated actions do, completely. Nango itself does not, and cannot.**

The generated action is an ordinary Ash action on an ordinary platform resource, so
`AshEnterprise.Security.ActorContext` is consulted exactly as it is for a database read: precomputed grants,
set membership, no query in a policy check. Nothing about the action being outbound changes the authorization
path, which is the entire benefit.

Nango is on the far side of that gate and holds provider credentials keyed by a *connection id*. It has its own
idea of who may use a connection, and we do not attempt to mirror ours into it. One rule makes that safe:

**The connection id is never an action argument.** It is derived inside the action from
`ActorContext.tenant(actor)` before the proxy call is made. If a caller could name the connection, the policy
engine would be authorizing the *operation* while the caller chose *whose credentials to spend* — a confused
deputy with extra steps, and precisely the shape thesis 5 exists to prevent. A generated action that accepts a
connection identifier from input is a bug, not a configuration option.

**The residual, which wrapping cannot fix.** Nango's own dashboard and API are a second access surface over the
same credentials: anyone holding the Nango secret key can invoke any connection directly, bypassing every
policy in this repository. That is not containable by design, only by operations — the secret key is a
production secret of the same class as the database password, and the Nango UI is not exposed to anyone who is
not an operator. Recording it because "we wrapped it in Ash actions" would otherwise read as a stronger claim
than it is.

## Consequences

**Made easy.** Token refresh, rate-limit backoff, pagination and webhook signature verification stop being
per-provider code. Adding a provider is a declaration plus credentials. Every outbound call is authorized,
audited and correlated by virtue of being an action, and `Ash.can?/3` answers "may this user trigger a
Salesforce push" the same way it answers every other question — which also means the agent console at `/agent`
gets integration actions with no additional work, gated by the same human-approval flow as any other mutation.

**Made hard.** ELv2 is **not OSI-open**: it forbids providing the software to third parties as a hosted service.
This is the first deliberate break with the open-source-only requirement recorded in
[thesis 6](../manifesto/06-reversibility.md), and it is the reason this is **tier 3** — confined to one
directory, removable by deletion. It is not a detail to discover later.

The M×N saving is smaller than the category framing implies. Because Nango has abandoned unified models and
because syncs are gated, we save the transport and auth axis and keep the schema-mapping axis. Roughly: the N
goes away, the M does not.

Self-hosting Nango is another service and its own datastore to operate and back up — *the exact backing
services were not verified and should be confirmed before adoption.* And the free tier's boundary is a
**product decision made by somebody else**, which may move; a design that stays inside auth-and-proxy is
deliberately positioned so that a narrowing of the free tier costs nothing new.

**Foreclosed.** Nothing structural — the whole surface is one extension plus one config block. What is
foreclosed by *choice* is Nango-hosted sync logic: the sync loop lives in Oban here, and adopting Nango syncs
later would mean moving business logic out from behind the policy engine, which is a direction this
architecture does not travel.

### Alternatives rejected

| Option | Why not |
|---|---|
| Write per-provider clients with `Req` | Correct for one or two providers and the reason to revisit this ADR if the count stays small. At ten it is ten OAuth refresh implementations, and the audit story has to be built by hand anyway. |
| **n8n** | Fair-code, not open source; `.ee` paths need a paid Enterprise licence. More importantly it is a second workflow engine whose steps execute outside every policy here — the exact second-security-model anti-pattern this group of ADRs is filtering for. Solves orchestration, which `Reactor` already solves. |
| **Windmill** | The most permissively licensed of the three (Apache-2.0 or AGPLv3 for the open parts) and technically attractive. Same structural objection as n8n: it is an orchestrator, not a provider edge, and this repository has an orchestrator. |
| A commercial unified API (Merge.dev and similar) | Genuinely does normalize per category, which is the thing Nango no longer claims. Closed and paid; and by Nango's own argument the normalized schema drops custom fields, which in enterprise CRM data is usually where the value is. |
| Generate one Ash action per Nango **sync** | The design the tooling most naturally suggests, and rejected because syncs are gated. Building a template's central mechanism on a paid tier makes the template untrue for most readers. |

## Reversal

**To abandon Nango but keep the action surface:** the generated actions are ordinary Ash actions. Replace the
`ash_nango` extension's proxy call with a `Req` call per provider and hand-roll token refresh. The resources,
policies, audit entries, code interfaces and agent tools are untouched, because none of them know how the
action reaches the network. Budget roughly a day per provider, and the OAuth refresh path is where the time
goes.

**To abandon the whole integration layer:** delete `lib/ash_enterprise/integrations/`, drop the `ash_nango`
dependency from `mix.exs` and `.formatter.exs`, remove the config block holding the Nango base URL and secret
key. Nothing in `lib/ash_enterprise/accounts/`, `security/` or `audit/` imports it — tier 3 code may not be
imported by tier 1 or tier 2 code, so this is a deletion rather than a refactor. An afternoon.

**The signal to reverse** is the free tier narrowing to exclude the proxy, or the provider count staying below
about three — at which point per-provider `Req` clients are less machinery for the same result, and this ADR
should be superseded rather than defended.

## Dogfood deviations (2026-10-09)

Recorded during the Productivity OS Dogfood program (PROD-4/E4; extraction ticket AST-155). Two deliberate
deviations from the decision above; neither weakens the confused-deputy rule.

1. **Per-user connection derivation.** This ADR derives the connection id from `ActorContext.tenant(actor)`
   — a per-tenant connection model for multi-tenant enterprise hosts. The dogfood program derives it from the
   actor's **linked-account resource** instead: a personal productivity OS has one human actor with several
   of their own accounts (work Gmail, personal Gmail), so the unit of credential ownership is the *user
   account*, not the tenant. The invariant is unchanged and remains absolute: **the connection id is never an
   action argument**; it is resolved inside the action from the actor. Enterprise hosts adopting the extension
   keep the tenant derivation as the default.

2. **~~Auth edge only for v1~~ — superseded 2026-10-12.** This deviation said the v1 verticals would use Nango
   for OAuth and token custody only and poll provider APIs directly. They do not: the verticals as built call
   the provider through Nango's proxy, via declared operation actions, exactly as the Decision prescribes (see the
   implementation note). The deviation is kept here as history.

Extraction sequencing: the extension is built from the first concrete vertical, not speculatively — exercise
once, then promote (or stay in-repo with a recorded justification).

## Implementation note (2026-10-12)

Built in the Productivity OS Dogfood program (E4), and running against live Google Calendar, Gmail and VendorPM Slack
connections in the dogfood instance.

- **Provider operations are declared, and the generated action is the call path.** The
  `AshEnterprise.Integration.Nango` extension (`lib/ash_enterprise/integration/nango/`) turns each `operation` into an
  Ash action whose run step is `Nango.RunOperation`. Declared today: `GoogleCalendar` (`list_calendars`,
  `list_events`), `Gmail` (`get_profile`, `list_history`, `list_messages`, `get_message`) and `Slack`
  (`list_conversations`, `conversation_history`, `user_info`). `Nango.Proxy` holds the only HTTP client (`Req`) on
  the integration path. Nothing calls a provider API directly.
- **The connection id is never an argument.** `RunOperation` resolves it from the actor's own active
  `Integration.LinkedAccount` for the integration, read under the actor's policies and tenant (deviation 1). A
  `linked_account_id` argument can only choose among the actor's own accounts, so one person can link several
  accounts for one provider. A system actor owns no linked account and so resolves none. `connection_id` is readable
  only through the owner-scoped `:for_operation` and `:mine` reads (a field policy), and a connection can be linked
  once in the whole deployment (`identity :unique_connection`, across all tenants).
- **Sync logic stays in Ash.** `Integration.SyncScheduler` runs on Oban cron (calendar every 10 minutes, Gmail and
  Slack every 5, queue `:ingestion`). It enqueues one step per active linked account. A cursor resource per
  vertical holds the resume point. A 429 snoozes the step with the provider's `Retry-After` and costs no retry.
  `Integration.SyncBlock` stops polling an account after a terminal cancel: a revoked token, a deleted connection,
  a shredded scope or an inactive owner.
- **Landed data is shreddable per account.** Every linked account has its own erasure scope (`connection:<linked
  account id>`, ADR 0024). Raw provider records land as sealed `Ingestion.SourceObject` rows, and Calendar
  projects into `Canonical.CalendarEvent` with sealed title and location. Gmail and Slack land as sealed source
  objects only: projection waits on zone admission ([ADR 0042](0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md),
  not built), so their zone gates deny by default. See `docs/runbooks/crypto-shredding.md`.
- **Operator tooling** (dev): `mix ash_enterprise.integration.link`, `.accounts` and `.sync` (counts only, never
  content).

Not built: webhooks (everything polls), Nango-side syncs (deliberately: sync logic stays in Ash), and promoting the
extension out of this app into its own package (AST-155).
