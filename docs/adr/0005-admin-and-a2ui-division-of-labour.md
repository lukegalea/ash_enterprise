# ADR 0005 — ash_admin and ash_a2ui: division of labour

- **Status:** accepted
- **Date:** 2026-08-13

## Context

This application has two derived UI layers that overlap, and the overlap is the
point of the decision:

**`ash_admin` (1.3, MIT, ~457k downloads)** — mount it in the router and every
resource is browsable and editable, with zero per-resource configuration.

**`ash_a2ui` (unpublished, git dependency, pre-1.0)** — a Spark DSL producing
A2UI protocol payloads from resource metadata. UI as *data*: the server sends a
description of a surface and the client renders it from a catalog it already
trusts, which is what makes it safe for an agent to drive.

Both derive from the same resources. Keeping both needs a reason.

## Decision

**`ash_admin` at `/admin` is the safety net. `ash_a2ui` at `/app/*` is the
product surface. Every A2UI screen has an admin equivalent.**

- **`/admin`** — complete, unstyled, every resource including Security and
  Audit. Auth-gated. The tool you reach for when something is wrong and you need
  to see the actual rows.
- **`/app/*`** — curated surfaces for the base domains, with server-enforced
  query allowlists (`search_fields`, `sortable`, `filters`, `page_size`) and
  field selection that is a security decision, not a layout one.

Surfaces live in `lib/ash_enterprise_web/a2ui/` as `AshA2ui.Standalone` modules,
**never as `a2ui do` blocks inside resources**.

## Why standalone modules

This is the load-bearing part.

`ash_a2ui` is tier 3 ([thesis 6](../manifesto/06-reversibility.md)) —
unpublished, SHA-pinned, pre-1.0, no example applications. Inline blocks would
make **the domain layer depend on it**, and removing it would mean editing every
resource.

With standalone modules, removing it is deleting a directory, three routes and a
dependency. Nothing in `lib/ash_enterprise/` knows it exists. And because every
screen has an `/admin` equivalent, the application keeps working while a
replacement is built.

A second benefit: resources generated from the CDM corpus stay regenerable,
because the generator never has to preserve hand-written UI metadata.

## Why not Backpex

`ash_backpex` exists, and Backpex is the more polished admin *product*. It is
rejected on architecture rather than quality: Backpex is **Ecto-schema driven**.
On an Ash codebase that means maintaining a parallel schema layer and losing Ash
policies at the admin boundary — precisely the transport-specific authorization
bypass [thesis 1](../manifesto/01-model-your-domain.md) exists to prevent.

## Consequences

**Easier**

- A new resource is administrable immediately, with no work at all.
- The A2UI layer can be pre-1.0 without that being a project risk, because the
  fallback is always present.
- Both layers run the resource's own read actions with the signed-in actor, so
  both are filtered by the same policies. A user with no grants sees an empty
  table, not a 403.

**Harder**

- Two UI layers to keep in mind. Mitigated by neither being hand-written.
- `/admin` exposes Security and Audit, so it must stay behind authentication and
  an appropriate grant. The audit log has its own policy requiring a global read.
- The A2UI DSL's compile-time field verification rejects private attributes. That
  is a feature — it caught `confirmed_at` on the user surface, and a hand-written
  template would have shipped a blank column — but it means some fields need a
  public calculation to surface. The audit log has none at all, which is why
  there is no A2UI audit surface.

## Reversal

**Dropping ash_a2ui:** delete `lib/ash_enterprise_web/a2ui/`,
`lib/ash_enterprise_web/live/a2ui_live.ex`, the `:a2ui_surfaces` live_session,
the npm packages and the `app.js` wiring. Point navigation at `/admin`. No
resource changes.

**Dropping ash_admin:** remove the router import and scope. Loses the safety net,
so do this only once the A2UI surfaces cover the security and audit domains —
which today they do not.
