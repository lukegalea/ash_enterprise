# Thesis 1 — Model your domain, derive the rest

> Declarative wins specifically where concerns cross-cut, and that is exactly where enterprise pain lives.

## The claim, stated narrowly

"Declarative is better than imperative" is not a useful statement. Plenty of declarative systems are worse than the
imperative code they replaced, usually because they made the easy 80% terse and the remaining 20% impossible.

The narrow claim is this: **declarative descriptions win when one fact must produce many consequences.**

An imperative codebase expresses a fact by writing its consequences out, one at a time, in the places they apply.
"Invoices are owned by a user" becomes a column in a migration, a field in a struct, a check in the controller, a clause
in the list query, a column in the CSV export, a filter in the report, and an assertion in the tests. Seven edits, all
of which must agree, forever.

A declarative codebase states the fact once and generates the consequences. The consequences cannot disagree with each
other, because they have one source.

The ratio of consequences to facts is what determines whether this pays off. In a small CRUD application it is close to
one, and declarative machinery is pure overhead. In enterprise software it is large — and it is largest for exactly the
concerns listed in [the index](00-index.md): ownership, hierarchy, audit, lifecycle, tenancy, exposure.

## What Ash actually derives

An Ash resource is not an ORM model with annotations. It is a description complete enough that the following are
*generated* rather than written:

| From the resource description | Ash derives |
|---|---|
| attributes, relationships, identities | the Postgres schema **and the migration to get there** (`mix ash.codegen`) |
| actions | the code interface, the transaction boundaries, the validation pipeline |
| actions + `AshJsonApi` | a spec-compliant JSON:API, **plus its OpenAPI document** |
| actions + `AshGraphql` | the GraphQL schema, queries, mutations, subscriptions, Relay support |
| actions + `AshAi` | LLM tool definitions with JSON schemas, exposed over MCP |
| resource + `AshAdmin` | a working admin UI, with no per-resource configuration |
| resource + `AshPaperTrail` / `AshEvents` | version tables or a central event log |
| resource + `AshStateMachine` | guarded transitions **and a Mermaid diagram of them** |
| policies | enforcement at the action layer — for *every* caller, including the ones written later |
| everything | ER diagrams, class diagrams and policy flowcharts (`clarity` + `ash_diagram`) |

The migration point deserves emphasis because it inverts the usual relationship. In most stacks the database schema is
the source of truth and the code mirrors it, so the two drift and the migration is written by hand. In Ash the resource
is the source of truth and the migration is *computed as a diff* against the current state. `mix ash.codegen --check`
then makes drift a build failure rather than a production incident — which is why it runs in CI and in a Claude Code
hook in this repository.

## Where the leverage actually comes from

Not from terseness. A resource file is not dramatically shorter than the schema plus controller it replaces.

The leverage is that **policies are enforced at the action layer, not the transport layer.**

This is the single most consequential architectural property of Ash for enterprise work. In a conventional Phoenix
application, authorization lives in the controller or the LiveView. It follows that:

- The GraphQL endpoint added in year two needs its own authorization.
- The CSV export needs its own.
- The nightly reconciliation job needs its own, and typically skips it "because it runs as the system".
- The MCP server exposing the app to an LLM needs its own — and this is the one that will be written fastest and
  reviewed least.

Each is a separate implementation of the same rules, and the security incident comes from whichever one was written
last.

In Ash, `Ash.read(Invoice, actor: actor)` consults the resource's policies regardless of who is calling. The REST API,
the GraphQL resolver, the LiveView, the batch job, and the LLM tool call all pass through the same gate, because the
gate is *below* all of them. [Thesis 5](05-agents-are-users.md) is a direct consequence: an agent is safe to expose not
because we wrote careful agent-specific guardrails, but because there was no path that bypassed the existing ones.

## The honest cost

**The learning curve is real.** Ash has its own vocabulary — resources, domains, actions, changes, preparations,
calculations, aggregates, policies, checks — and the mapping to Ecto concepts is not one-to-one. A developer fluent in
Phoenix is not immediately productive.

**Errors surface at a distance.** Spark builds resources through heavy macro expansion, and it cannot always point at
the source line responsible. A misplaced option in a DSL block produces an error about the block. This also degrades
Dialyzer's usefulness, which [thesis 7](07-what-we-do-not-have.md) discusses rather than glosses over.

**Escaping the abstraction costs more than not having it.** When a query genuinely needs hand-written SQL, you are
writing a manual action or a custom expression, which is more work than it would have been in bare Ecto. Ash provides
these escape hatches and they work, but the cost is real and it is paid at the worst moment — under deadline, on the
hard query.

**The generated surfaces are opinionated.** The derived JSON:API is a *good* JSON:API, not the one your existing
integration partner already parses.

The bet is that these costs are paid once and early, while the cross-cutting benefits compound with every resource
added over years. That bet is bad for a small application with a short life. It is the reason this repository exists for
the other kind.

## Why this is a *reference* application rather than a library

Because the derivation is only as good as the description, and the descriptions are yours.

Nothing here can be `mix deps.get`-ed. What is provided is a worked example of descriptions that are complete enough to
derive from: a base resource that declares the cross-cutting facts once ([thesis 4](04-batteries-are-inherited.md)), an
entity model borrowed from people who have already made the mistakes ([thesis 2](02-schema-commons.md)), and an
authorization model expressed as data rather than branches ([thesis 3](03-authorization-is-data.md)).

Clone it, delete what you do not need, and keep the shape.
