# The Ash Enterprise Manifesto

This directory is the argument. The code is the evidence.

## The problem

Enterprise software is not hard because any individual feature is hard. Issuing a purchase order, approving a
requisition, closing a period — taken alone, each is a form and a state transition. A competent developer ships any one
of them in an afternoon.

Enterprise software is hard because of what is true of *every* feature simultaneously:

- Every record has an **owner**, and ownership is polymorphic (a person or a group).
- Every record sits in an **organizational hierarchy**, and who can see it depends on where they sit relative to it.
- Every change must be **audited** — who, what, when, from where, in which transaction, with the before and after.
- Every record has a **lifecycle**, and illegal transitions must be impossible rather than merely discouraged.
- Every record may need to be **shared** with someone outside the normal access rules, without widening those rules.
- Some **columns** are more sensitive than the rows that contain them.
- Everything is **multi-tenant**, or will be within eighteen months.
- Everything must be reachable by **REST, GraphQL, a CSV export, a nightly batch job, and now an LLM**.
- Nothing may be **hard deleted**, and everything must be **restorable**.
- All of it must be **observable** in production at 3am by someone who did not write it.

There are two ways to respond to that list. The industry's default is to write each concern into each feature, and then
to hire people whose full-time job is noticing where it was written inconsistently. The result is the familiar
enterprise codebase: a large volume of code in which the business logic is a small, hard-to-find minority.

## The thesis

> **The cross-cutting concerns of enterprise software are declarable. Declare them once, derive them everywhere, and
> what is left over is the actual business.**

This is Ash's own claim — *model your domain, derive the rest* — taken seriously and pushed to its conclusion. Ash
resources are not ORM models. They are a machine-readable description of a domain, complete enough that the migrations,
the REST API, the GraphQL schema, the admin UI, the LLM tool definitions, the audit trail, and the authorization rules
are all *derived* rather than written.

The claim this repository tests is that the derivation covers enough ground to be decisive at enterprise scale, and
that where it does not, the gaps are nameable and small.

## The seven theses

| # | Thesis | In one line |
|---|---|---|
| [1](01-model-your-domain.md) | **Model your domain, derive the rest** | Declarative wins specifically where concerns cross-cut, and that is exactly where enterprise pain lives. |
| [2](02-schema-commons.md) | **The schema commons** | Do not invent your nouns. Adopt a mature published model — but adopt it as a frozen corpus, not a dependency. |
| [3](03-authorization-is-data.md) | **Authorization is data, not code** | `(role, privilege, depth)` rows in a table, evaluated as a pure union of grants. No deny rules, no exceptions. |
| [4](04-batteries-are-inherited.md) | **Batteries are inherited, not installed** | One base resource. Audit, telemetry, ownership, tenancy and soft-delete arrive by inheritance, not by discipline. |
| [5](05-agents-are-users.md) | **Agents are users** | The LLM gets the same action layer and the same policies as the web UI. Not a parallel path with parallel bugs. |
| [6](06-reversibility.md) | **Reversibility** | Every alpha, unpublished, or commercial dependency is isolated behind a named seam, with the exit documented. |
| [7](07-what-we-do-not-have.md) | **What we do not have** | The honest list. A reference architecture that hides its gaps is marketing, not engineering. |

## What this repository is

A **base template**. It is meant to be cloned and grown, not depended upon. It ships:

- A reproducible development environment (`devenv.nix`) — Postgres with pgvector, the pinned BEAM toolchain, one command.
- A **platform layer**: one base resource carrying the cross-cutting concerns, and the policy checks that implement a
  full hierarchical access-control model.
- Four working domains covering identity, access control, audit, and reference data — derived from a published
  enterprise schema rather than invented.
- A repeatable, documented **process** for adopting the next slice of that schema when a new problem domain arrives.
- Admin UI, an agent console, API surfaces, and diagram-driven introspection — all derived from the same resources.
- The tooling that lets an AI coding agent work on it accurately: dependency-derived usage rules, MCP servers, and
  skills.

## What this repository is not

It is not a product, not a framework, and not a library. There is nothing here to `mix deps.get`. Copying and deleting
is the intended mode of use.

It is also not a claim that Ash is the right choice for every system. It is a claim about a specific class: systems with
many entities, complex authorization, hard audit requirements, and a long life. For a three-table CRUD app, everything
here is overhead.

## How to read this

Read thesis 1 and 3 first — they carry the weight. Thesis 4 is the mechanism that makes 1 and 3 practical. Theses 2, 5
and 6 are consequences. Thesis 7 is the one to read before making a commitment.

The manifesto argues the position. Five documents outside this directory record what came of it, and reading only the
theses gives you the argument without the score.

| Then | For |
|---|---|
| [`../QUESTIONS.md`](../QUESTIONS.md) | The 28 questions every enterprise application answers, and which ones this repository actually answers — shipped, partial, planned, or open. The ledger against which the theses are claims. |
| [`../ROADMAP.md`](../ROADMAP.md) | Where the planned and open rows go, in what order, and the one selection rule every item had to clear. |
| [`../adr/`](../adr/README.md) | The specific forks, why each was taken, and — the part worth reading — what would have to change to reverse it. |
| [`../HANDOFF.md`](../HANDOFF.md) | For picking the work up: the environment traps, and the findings that were expensive to discover and are written down nowhere else. |
| [`../plans/`](../plans/) | The long-form designs behind the larger pieces — including the parts that building them disproved, which are left in place rather than tidied away. |
