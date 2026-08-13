# Thesis 3 — Authorization is data, not code

> `(role, privilege, depth)` rows in a table, evaluated as a pure union of grants. No deny rules. No exceptions.

This is the thesis that most changes how the code looks, so it comes before the easier ones.

## The failure mode we are avoiding

Almost every application starts authorization the same way:

```elixir
if user.role == "admin" or record.user_id == user.id do
```

This is authorization as **code**. It has three properties that make it unsurvivable at enterprise scale:

1. **It cannot be inspected.** "Who can see this invoice?" is answerable only by reading every branch that touches
   invoices. Nobody can answer it for an auditor, and nobody can answer it for a customer.
2. **It cannot be changed by anyone but a developer.** Real enterprises reorganize. A new region, a new subsidiary, a
   contractor who may see three accounts and no others — each becomes a ticket, a deploy, and a regression risk.
3. **It drifts.** The check in the list view, the check in the detail view, the check in the CSV export and the check in
   the nightly job start identical and end different. The export is where the breach comes from.

The alternative is authorization as **data**: rows in tables that describe who may do what, and one engine that
evaluates them. Admins edit rows. Developers edit the engine, rarely.

## The model we adopt

We implement the Dataverse (Dynamics 365 / Power Platform) security model. Not because it is fashionable — it is not —
but because it is the most thoroughly refined published answer to this exact problem, it has survived thirty years of
real deployments across every regulated industry, and it is precisely specified in public documentation.

Its shape is small enough to state completely:

**Ownership.** Every record has an owner, which is a *user or a team* (polymorphic), plus a denormalized owning business
unit. Tables are declared at creation time as either *user-owned* or *organization-owned*, and this cannot change.

**Business units.** A hierarchy, rooted in exactly one node. Every user belongs to one. Every record is owned by one.

**Privileges.** Eight verbs: `Create`, `Read`, `Write`, `Delete`, `Append`, `AppendTo`, `Assign`, `Share`.

> `Append` and `AppendTo` are the pair people always get wrong. `Append` is "I may be attached to something else" and
> lives on the child; `AppendTo` is "something may be attached to me" and lives on the parent. Linking two records
> requires both.

**Depth.** Each privilege is granted at one of five access levels, totally ordered, each subsuming the one below:

| Access level (UI) | Depth (API) | Means |
|---|---|---|
| Organization | `Global` | Every record, everywhere |
| Parent: Child Business Unit | `Deep` | My business unit and everything under it |
| Business Unit | `Local` | My business unit |
| User | `Basic` | Records I own, or my teams own, or that are shared with me |
| None | — | Nothing |

**Security roles** are named bags of `(privilege, depth)` pairs. Users hold roles directly, and inherit them through
membership of owner teams.

**Sharing** is a separate, explicit ACL: `(principal, record, rights bitmask)`, with inherited rights tracked separately
so cascades can be undone cleanly.

**Hierarchy security** grants managers access to their reports' records — read/write for direct reports, read-only
further down the chain, bounded by a configurable depth.

**Column security** applies on top of row access, and only on top: a profile can grant read, write, or *read-unmasked*
on individual columns of records you can already see.

## The property that makes it implementable

Here is the sentence that determines the entire implementation, verbatim from Microsoft's documentation:

> *"A key concept of Dataverse security to understand is all privilege grants are accumulative with the greatest amount
> of access prevailing. If you gave broad organization level read access to all contact records, you can't go back and
> hide a single record."*

**There are no deny rules.** Authorization is a pure union of grants. Access is granted if *any* path grants it, and
paths never subtract.

This is not a limitation to work around — it is what makes the model tractable. A system with both grants and denies has
no canonical evaluation order, and every new rule potentially interacts with every existing one. A pure union is
order-independent, trivially parallelizable, and comprehensible one grant at a time.

It also maps onto Ash exactly. Ash policy checks are evaluated top to bottom and the first decisive result wins, so a
sequence of `authorize_if` clauses *is* a union:

```elixir
policies do
  # Each clause is one grant path. Any one of them succeeding is sufficient.
  policy action_type(:read) do
    authorize_if AshEnterprise.Security.Checks.RoleGrant     # role x privilege x depth
    authorize_if AshEnterprise.Security.Checks.SharedWith    # explicit ACL
    authorize_if AshEnterprise.Security.Checks.HierarchyGrant # manager / position chain
  end
end
```

**Corollary, and it is a load-bearing rule in this codebase:** never use `forbid_if` for row access. A single
`forbid_if` breaks the additive model and reintroduces order-dependence. `forbid_if` is legitimate only for concerns
that are genuinely not row access — a globally disabled account, a decommissioned tenant.

## Why this is worth the effort

Because of what falls out of it once it exists:

- **"Who can see this record?"** is a query, not an investigation.
- **Reorganizing** is inserting business unit rows, not a deploy.
- **The export, the API, the batch job and the LLM** cannot disagree with the UI, because they call the same actions and
  the same policies. Ash enforces at the action layer, not the controller layer, so there is no bypass to forget.
- **Read authorization filters rather than forbids.** Ash's default for read actions is to *narrow the query* rather
  than raise, which means inaccessible rows are invisible instead of "403 Forbidden" — the difference between a list
  that works and a list that leaks its own existence.

## The cost, stated honestly

Two things get harder, and pretending otherwise would be dishonest.

**Performance.** Naively, every policy evaluation wants to know the actor's teams, their business unit's entire subtree,
their full privilege map, and their reporting chain. Evaluated per-check, per-row, this is ruinous. Microsoft's own
documentation warns that sharing is "less performant" and recommends capping hierarchy security at ~50 users under a
manager.

Our answer is `AshEnterprise.Security.ActorContext`: all of it is computed **once per request**, in a plug, and carried
on the actor. Policy checks read precomputed sets and never issue queries. This is a hard architectural rule — a policy
check that queries is a bug.

**Comprehension.** This model is genuinely more intricate than `if user.admin?`. A developer must understand depth
semantics before writing a role.

That is what the conformance suite is for. `test/security/conformance_test.exs` enumerates the truth table directly:
for every combination of ownership type, privilege, depth, and actor placement, it asserts the expected verdict via
`Ash.can?/3`. It is not a test of our implementation so much as an executable copy of the specification — and it is the
first thing to read when the model surprises you.

## Further reading

- `lib/ash_enterprise/security/` — the checks
- `test/security/conformance_test.exs` — the truth table
- [Security concepts in Microsoft Dataverse](https://learn.microsoft.com/en-us/power-platform/admin/wp-security-cds)
- [Ash policies guide](https://hexdocs.pm/ash/policies.html)
