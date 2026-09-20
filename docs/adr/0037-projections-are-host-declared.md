# ADR 0037 — Projections are host-declared, from a vocabulary the library owns

- **Status:** accepted
- **Date:** 2026-09-20

## Context

A canvas object carries a list of *projections*: the ways a person can be shown
this thing. [ADR 0034](0034-canvas-dev-surface.md) named the vocabulary —
`:inspect`, `:browse`, `:view`, `:create`, `:edit`, `:act`, `:diagram`,
`:history` — and `ash_a2ui` derived each object's list from the shape of its
Ash actions: a read makes it browsable, a create makes it creatable, and so on.

That derivation covers everything CRUD can describe and cannot reach the rest.
`:diagram` and `:history` were in the vocabulary from the beginning and nothing
ever emitted either, for a reason no amount of work on the resolver would have
fixed: **whether a thing is drawable is not a property of the resource.**
`AshEnterprise.Bpmn.Definition` and `AshEnterprise.Accounts.BusinessUnit` have
indistinguishable action shapes. What differs is that this application ships
bpmn-js and points it at one of them. The library cannot know that, and the
resource does not record it.

So two declared kinds sat in the contract as documented intent with no producer.
That is a specific and recurring defect shape in this codebase — something
spelled correctly, present in every structural artefact, and reaching nothing —
and it is worth fixing at the seam rather than working around at the call site.

The second half of the problem was downstream. The canvas inspector rendered a
link only when a resource had a declared A2UI surface, so reachability depended
on whether a resource's page happened to be a derived table. The whole process
layer is deliberately built the other way: a diagram is bpmn-js, an approvals
list is an indexed candidate query. Every BPMN and decision resource therefore
appeared as an object with nowhere to go, while the application had a page for
each of them.

## Decision

**The host declares which projections apply; the library owns what they mean.**

`AshA2ui.Canvas.Registry.projections/2` is optional, receives the target
(resource module or record struct) together with the library's derived list, and
returns the list the object should carry. Three distinctions are deliberate:

- **`nil` means "no opinion"** and keeps the derived list, so a host can answer
  for one resource without re-deriving every other resource's list itself.
- **`[]` means "none"**, which is a different statement and must not silently
  fall back to the derivation.
- **The result is filtered against the declared vocabulary.** A host chooses
  among the kinds; it cannot add one. An invented kind is dropped and the
  legitimate entries around it survive, because rejecting the whole list would
  cost a host its valid projections over a typo.

In this application the callback declares `:diagram` on `Bpmn.Definition` and
`Decisions.Definition` and nothing else, and the inspector renders one link per
projection that has a destination — so the badges and the links come from the
same list.

## Does it consume ActorContext?

**Yes, and only through the part that was already doing so.**

Projections and capabilities are computed together in the same resolution, and
capabilities are the half that asks: record-level capabilities call `Ash.can?/3`
with the scene's actor and tenant, which is `ActorContext` reaching the canvas
by the ordinary route. This ADR does not change that and does not widen it.

What `projections/2` itself receives is a resource module or a record struct and
a list of atoms — no actor, deliberately. A projection says what *kind* of
showing is possible for this sort of object, not whether the person looking may
do it; that second question is the capability list beside it, and it is already
answered per actor. Keeping the actor out of this callback is what stops a host
from accidentally reimplementing authorization in a display hint, where it would
be neither audited nor enforced.

The consequence to state honestly: a projection badge is **not** an access
decision, and must never be read as one. `:edit` appearing on an object means
the application can show an edit surface for that kind of thing, and the
capability list is where "and you may" is recorded.

## Consequences

**A projection is now a claim the application can be held to.** Because badges
and links derive from one list, a projection with no destination renders as a
badge and nothing else, which is the honest depiction of a claim nothing serves.
That is a visible invariant rather than a documented one.

**Two claims were deliberately not made**, and the restraint is the point:

- `:diagram` is *not* declared on `Bpmn.Instance`, though a running instance is
  the most diagram-like object here. A single instance is drawn at
  `/app/instances/:id`; no route draws instances in general, so claiming it at
  resource level would make the object model say something untrue.
- `:history` stays unemitted. `Bpmn.ProcessEvent` is literally a process's
  history and nothing renders it as one yet. A projection nothing can open is
  the defect this callback exists to fix, not to relocate.

**The vocabulary stays a closed set, and that is a constraint on us.** When a
genuinely new kind of projection appears, the right move is to add it upstream
with a meaning the experience compiler shares — not to let hosts mint kinds and
discover later that two applications spell the same idea differently.

**Audience gating still has one home.** The registry already decides what
exists; it now also decides how each thing may be shown. Both are the questions
a tenant-facing canvas will have to answer, and they are in the same module.

## Reversal

Tier 3, and smaller than most. Deleting `projections/2` from
`AshEnterprise.Canvas.Registry` returns every object to the derived list — the
library treats a missing callback and a `nil` return identically — and the
inspector falls back to rendering only the destinations it can still resolve.
No data, no schema, no payload shape depends on it: projections are computed per
request from compile-known metadata.

Upstream, the callback is additive and optional, so a host that never implements
it encodes exactly as it did before this ADR.
