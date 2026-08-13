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
| 0004 | Reactor over Oban Pro for orchestration | planned |
| 0005 | ash_admin and ash_a2ui: division of labour | planned |
| 0006 | daisyUI + SaladUI as the design system | planned |
| 0007 | Dialyzer runs non-blocking | planned |

## Writing a new one

Number sequentially, never renumber, never delete. A superseded ADR stays in place with its status updated and a pointer
forward — the reasoning that was wrong is often more useful later than the reasoning that was right.
