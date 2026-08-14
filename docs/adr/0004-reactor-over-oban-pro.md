# ADR 0004 — Reactor for transactional orchestration, Oban for durability

- **Status:** accepted
- **Date:** 2026-08-13

## Context

Enterprise applications need orchestration at two quite different timescales,
and conflating them is the usual mistake:

**Request-scoped, transactional.** Several writes that must succeed or unwind
together, with compensation for the ones that already happened. Provisioning a
tenant; reassigning a business unit and everything beneath it.

**Long-running, durable.** Processes measured in hours or weeks that must
survive deploys and node restarts. An approval waiting on a human; a nightly
reconciliation; a retry with backoff.

Open-source-only is a stated requirement ([thesis 6](../manifesto/06-reversibility.md)),
which removes Oban Pro's Workflows — the obvious answer to the second — from
consideration for the default path.

## Decision

**Reactor 1.0 for transactional orchestration. Oban for anything durable. They
are not alternatives and neither substitutes for the other.**

- **Reactor** (via `Ash.Reactor`) for multi-step operations inside a request:
  a DAG built from step arguments, concurrent where independent, with saga
  compensation on failure. In-process, no persistence.
- **`ash_oban`** for scheduled actions and data-condition triggers. Postgres is
  the durable substrate.
- **A step never spans the two.** A Reactor step may *enqueue* an Oban job; it
  may not *wait* for one.

That last rule is the operative content of this ADR, and it is not a matter of
taste.

## Why Reactor cannot be the durable layer

Reactor *appears* to support this. A step returning `{:halt, reason}` yields
`{:halted, %Reactor{}}`, and that struct can be passed back into `Reactor.run/2`
to resume. It is tempting to persist the halted struct and call it a workflow
engine.

It was tested against `reactor v1.0.6` rather than assumed, and it does not hold
up (see [`docs/plans/business-process-modelling.md`](../plans/business-process-modelling.md) §4
for the full write-up):

1. **Persisting a halted reactor works — but only for module-backed steps.**
   Across VM restart and recompile, those resume correctly.

2. **Inline steps fail catastrophically.** The DSL compiles `run fn ... end`
   into a **content-hashed generated function**
   (`run_0_generated_184ACD2713A85C64F83AF0031192EA65/2`), where the hash derives
   from the function body. Editing a pending step's body renames it, and every
   in-flight checkpoint referencing the old name dies with
   `UndefinedFunctionError`. **A deploy bricks in-flight work**, and the failure
   arrives long after the change that caused it.

3. **Halt is a checkpoint, not a park.** `{:halt, reason}` stores `reason` as
   that step's *result* and never re-runs the step. A gate returning
   `{:halt, :awaiting_approval}` resumes with `:awaiting_approval` as the gate's
   value — which is precisely the wrong semantics for a human decision, because
   the decision is never actually taken.

4. **There is a live bug.** When a halt originates inside a `compose`d
   sub-reactor, resuming does not resume the child: the downstream step receives
   `nil` and the run reports `{:ok, ...}` rather than `{:halted, _}`. Silent
   wrong answer, not a crash. Root-caused during research; unreported upstream at
   time of writing.

Points 3 and 4 are disqualifying on their own. Point 2 makes the failure mode
*deploys break running processes*, which is the worst available shape.

## Consequences

**Easier**

- Reactor is used for what it is genuinely excellent at — concurrent,
  dependency-resolved, compensating operations within a transaction — with no
  expectation it cannot meet.
- Durability comes from Postgres, the only thing in this stack that survives a
  node restart.
- No commercial dependency on the default path.

**Harder**

- Long-running processes with human steps have **no first-class support yet**.
  Composing them from `ash_state_machine` + `ash_oban` + policies is real work,
  and it is named as a gap in
  [thesis 7](../manifesto/07-what-we-do-not-have.md#3-approval-workflows--maker-checker).
- Two mental models rather than one.

## Reversal

**Oban Pro** remains the strongest commercial swap-in, and its case is now
*stronger* than [thesis 6](../manifesto/06-reversibility.md) records:

> **Oban Pro 1.7 (April 2026) shipped `await_signal/1`** — durable
> wait-for-human-approval with a deadline, holding no connection. That is
> precisely the primitive Reactor cannot provide, and it materially shortens the
> approval-workflow work.

Thesis 6's Oban Pro entry has been updated to record this.

Adopting it changes orchestration modules only; resources, policies and audit are
untouched, because no domain code depends on how a workflow is driven.

The alternative — a token-based process interpreter over Ash and Oban — is
designed in [`docs/plans/business-process-modelling.md`](../plans/business-process-modelling.md).
Both remain open.
