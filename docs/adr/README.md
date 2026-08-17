# Architecture Decision Records

Each ADR records one fork in the road: what was decided, what the alternatives were, and — most importantly — **what
would have to change for the decision to be reversed**. That last section is what [thesis 6](../manifesto/06-reversibility.md)
demands, and it is the part worth writing carefully.

The manifesto in `../manifesto/` argues the position. These record the specific choices made while implementing it.

## Format

```markdown
# ADR NNNN — Title

- **Status:** proposed | accepted | superseded by ADR-NNNN
- **Date:** YYYY-MM-DD

## Context
What forced a decision. Include the verified facts, with dates -- ecosystem
claims go stale fast and a reader in a year needs to know what was true when.

## Decision
What we chose, stated so someone can act on it.

## Consequences
What this makes easy, what it makes hard, what it forecloses.

## Reversal
The concrete exit: which files change, and how much work it is.
```

## Index

| ADR | Title | Status |
|---|---|---|
| [0001](0001-cdm-as-frozen-hybrid-corpus.md) | The CDM is a frozen, hybrid, vendored corpus | accepted |
| [0002](0002-ash-events-over-paper-trail.md) | AshEvents as the default audit layer, AshPaperTrail opt-in | accepted |
| [0003](0003-attribute-multitenancy.md) | Attribute-based multitenancy plus business-unit hierarchy | accepted |
| [0004](0004-reactor-over-oban-pro.md) | Reactor for transactional orchestration, Oban for durability | accepted |
| [0005](0005-admin-and-a2ui-division-of-labour.md) | ash_admin and ash_a2ui: division of labour | accepted |
| [0006](0006-design-system.md) | daisyUI 5 + Phoenix core_components as the design system | accepted |
| [0007](0007-dialyzer-non-blocking.md) | Dialyzer runs, and does not gate | accepted |
| [0008](0008-typed-invertible-legacy-mappings.md) | Legacy mappings are typed expressions with proven inverses | accepted |

## Writing a new one

Number sequentially, never renumber, never delete. A superseded ADR stays in place with its status updated and a pointer
forward — the reasoning that was wrong is often more useful later than the reasoning that was right.
