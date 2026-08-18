# ADR 0019 — API versioning is a presentation contract, not a schema fork

- **Status:** proposed
- **Date:** 2026-08-18

## Context

`AshEnterprise.Accounts` exposes three resources over JSON:API and four over GraphQL from the same
resource modules (`lib/ash_enterprise/accounts.ex`). Exposure is opt-in per resource via `:api_type`,
and the routes are declared once. That is the arrangement the whole platform depends on: one action,
one policy set, one audit trail, and — per [thesis 3](../manifesto/03-authorization-is-data.md) — no
second code path the export or the API can disagree with the UI on.

The first external consumer that cannot take a breaking change ends that arrangement, and there are
only three ways it usually ends.

**Accretion.** Never rename, never remove, add a field beside the old one. This is the cheapest thing
to do and it is why mature APIs carry `name`, `display_name` and `displayName` on the same object. The
resource accumulates attributes that exist only because a client from three years ago reads them, and
nothing in the codebase records which is which.

**Forking the resource.** `Accounts.V1.BusinessUnit` and `Accounts.V2.BusinessUnit`. Now the policy
set, the ownership declaration, the audit configuration and the tenancy block exist twice, and
[thesis 4](../manifesto/04-batteries-are-inherited.md)'s guarantee — that these arrive by inheritance
and cannot be forgotten — holds for each fork separately and for the pair not at all. The version that
gets a policy fix is the one someone remembered.

**Branching in the web layer.** A `case version do` inside a controller or a view module. This is
authorization-as-code's sibling: the mapping is not inspectable, it is not in one place, and the list
endpoint, the detail endpoint and the CSV export start identical and end different. That failure is
described in [thesis 3](../manifesto/03-authorization-is-data.md) for authorization; nothing about it
is specific to authorization.

Neither `ash_json_api` nor `ash_graphql` has a versioning DSL (verified against the versions in
`mix.lock`, 2026-08-18). GraphQL's official position is that you should not version at all — deprecate
fields and let clients migrate — which is coherent for GraphQL, where the client names the fields it
wants, and does not transfer to JSON:API, where the document shape *is* the contract and a renamed
member is a break whether or not anyone asked for it.

## Decision

**One resource, one schema, N presentation contracts.** A proposed first-party extension,
`ash_api_versioning`, declares version deltas as data on the resource, the same way `ash_strangler`
declares legacy mappings ([ADR 0008](0008-typed-invertible-legacy-mappings.md),
[ADR 0009](0009-strangler-and-bpmn-are-first-party.md)). The design is written up in
[`../plans/ash-api-versioning.md`](../plans/ash-api-versioning.md); this ADR records why it is shaped
that way.

Four commitments.

**1. No new database objects. Ever.** A version delta may not emit a table, a view, a materialized
view, a trigger, an index or a migration. This is not a guideline, it is the property that makes the
extension a different tool from `ash_strangler` rather than a syntax variant of it. Strangler's cost is
DDL against a relation the package does not own: a compatibility view, `INSTEAD OF` triggers, an
expression index, a resumable backfill and a drift reconciler, every one of which has to be generated,
migrated, locked and reconciled. A presentation contract is function application in the render and
parse path. **Lose the no-DDL property and there is no argument left for a second extension.**

**2. Deltas are declared on the resource, not in the web layer.** One declaration feeds JSON:API,
GraphQL, the CSV export and anything else that renders. Declare once, derive the rest — the same
discipline ADR 0008 argues for, applied at the other boundary.

**3. Invertibility is checked at compile time.** This is the borrowed idea, and it is borrowed from
ADR 0008 specifically because that ADR *measured* what its absence costs. A forward direction written
as one opaque transform and a backward direction written as another, with nothing comparing them,
produced this: a single `UPDATE` through the view assigning **only the email** rewrote `passive`,
`pending` and `deleted` to `suspended` — three of five lifecycle states, no error, correct row count.

The same shape is available at an HTTP boundary and is worse there, because no database object exists
to inspect afterwards. A v1 client `PATCH`es a document containing only `email`; the v1 `parse`
direction for `status` runs against the reconstructed document and collapses four states into one. So:
a version delta that declares a `render` transform for an attribute reachable by a *writable* action,
without a matching `parse`, **refuses to compile**. Read-only members opt out explicitly and, as in
ADR 0008, the opt-out carries a mandatory `because:` string that is quoted verbatim in the runtime
error a client sees when it tries to write one.

Two consequences of JSON:API's own semantics fall out and are worth stating, because they are the
`INSTEAD OF UPDATE` problem again in a different notation. JSON:API defines a `PATCH` as partial —
members absent from the document must be left alone — so `parse` runs only over members actually
present, never over a reconstructed full document. And a delta may not make a member's *absence*
meaningful, because absence is already taken.

**4. The boundary is an error message, not a convention.** When the invertibility check fails on a
change that is genuinely not representational — the v1 field's values came from a column that no longer
exists, or from a table that was split — the compiler must not emit "cannot invert transform". It emits
a named diagnostic pointing at `ash_strangler`, naming the attribute and saying that a structural
change needs a compatibility view and cannot be expressed as a rendering. The line between the two
first-party tools is stated by the tool that hits it rather than discovered by the person who guessed
wrong.

## Does it consume ActorContext?

Not meaningfully, and it should not. Version selection is a property of the request — a header, a URL
segment, a client registration — and never of the actor. Nothing in
`AshEnterprise.Security.ActorContext` is an input to which contract a response is rendered under, and
making it one would mean two clients with identical requests receiving different document shapes for
authorization reasons, which is a leak dressed as a feature.

There is exactly one interaction, and it runs the other way. Field policies remove fields from a
response *before* rendering. A version delta that renames or derives a field the actor may not see must
therefore render nothing at all, not `null` and not a computed default — a delta that can reconstitute
a field field policies dropped is a field-policy bypass. That is one verifier and one ordering
constraint: deltas apply strictly downstream of the authorizer, over the fields that survived it.

## Consequences

**Made easy.** A resource keeps one schema, so the policy set, the audit configuration, the ownership
declaration and the tenancy block are written once and cannot diverge per version. The version matrix
is data, so `mix ash_api_versioning.diff v2 v3` is a projection rather than a documentation exercise —
which is the artefact that actually gets handed to a client. Adding a contract costs a block on one
resource and no migration.

**Made hard.** Deltas compose in sequence, Stripe-style: a request pinned to the oldest supported
contract runs the whole chain. The cost is per-request and grows monotonically with the number of
versions, because nobody deletes a delta — a delta can only be removed once every client on that
contract is gone, and finding out whether they are gone is an operational problem the extension does
not solve. Budget for a sunset policy before the third version, not after.

The extension also has to be honest about what a "representational" change is, and that boundary is not
crisp. A flattened address rendered as a nested object is representational. An enum whose spelling
changed is representational. An enum that gained a member v1 clients cannot express is not — and the
`parse` direction has nowhere to put it. Commitment 4 is what stops those cases being resolved by
whoever is writing the delta at the time.

**Foreclosed.** Version differences that are not expressible over the current schema. That is
deliberate and it is the whole shape of the decision: the moment a version can carry its own storage,
this is `ash_strangler` with a second DSL, and the correct move is to use `ash_strangler`.

## Reversal

Cheap now, because nothing depends on it: there is no `ash_api_versioning` line in `mix.exs` and no
`api_versions` block in any resource. Abandoning the decision before adoption is a matter of not adding
either.

**To abandon after adoption:** delete the `api_versions do … end` blocks from the resources that carry
them and pin the routes in `lib/ash_enterprise/accounts.ex` (and any later domain) to the current
document shape. Every delta then has to be hand-translated into whichever of the three options in
Context is chosen — most likely view modules under `lib/ash_enterprise_web/`, which reintroduces the
drift the extension exists to prevent. The declarations are not retained anywhere, so this is
retyping, not a config flag. That cost is deliberate, for the reason ADR 0008 gives: a kept
compatibility path is a second design to maintain.

**To drop the compile-time invertibility check while keeping the extension:** delete the verifier and
the `parse` requirement, and version deltas become render-only. Cheap to do, and it converts the
extension into something safe for read-only APIs and unsafe for writable ones. The signal that this is
the right trade would be an API surface that is genuinely read-only — at which point the check costs
authoring friction and prevents nothing.

**To fold the extension into `ash_strangler` instead:** the expensive one. Strangler's mappings target
a legacy *relation*; these target an Ash resource's rendered representation, and the reference frames a
transform must be printed in (view body, trigger body, reverse view) have no analogue here — there is
no SQL. Budget a rewrite of the entity definitions rather than a merge. The signal would be commitment
1 failing repeatedly in practice: if real version deltas keep needing database objects, there was only
ever one tool.
