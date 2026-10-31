# ADR 0061 — Judgment surfaces ship with ash_judgments; a host binds them to its own resources

- **Status:** accepted (2026-10-31), implemented
- **Date:** 2026-10-31

## Context

The System One loop has every record and every person-gated act, and no screen:

- bandings in the `review` band waiting on a person's verdict;
- calibration runs that propose a band table, waiting on a certification;
- the certification and the publication themselves (ADR 0041);
- the facts each admission writes, with their status and provenance.

`AshEnterprise.SystemOne.ReviewQueue` reads the pending work and says so in its moduledoc: "data surface — no UI".
In practice, every act so far has been run from a script over `:erpc`. That includes certifying and publishing the
first three standards band tables on 2026-10-31.

The records are built from `ash_judgments` fragments, so any application using the package has the same gap. Luke
asked on 2026-10-31 for surfaces that are easy to bring into this application and into the applications built from it.

Two constraints shape the answer:

1. **ADR 0005:** A2UI surfaces are standalone `AshA2ui.Standalone` modules in the web layer, never `a2ui do` blocks
   inside resources. The domain layer must not depend on `ash_a2ui`.
2. **The resources are the host's.** A host builds `Banding`, `CalibrationRun`, `HumanVerdict` and the rest from the
   package's fragments on its own base resource, with its own policies and tenancy. A surface the package ships cannot
   name them. Some reads cross two of them: "a banding with no verdict for any of its observations" is an `exists`
   over the host's verdict resource, and Ash takes the related resource of an unrelated `exists` only as a literal
   module.

## Decision

### The surfaces ship in `ash_judgments`, as macros a host binds in its web layer

`ash_judgments` takes `ash_a2ui` as an optional dependency and ships five surface macros under `AshJudgments.A2ui`.
Each one compiles only when `ash_a2ui` is loaded. A host binds a surface to its own resource in its web layer:

```elixir
defmodule MyAppWeb.A2ui.VerdictsUI do
  use AshJudgments.A2ui.Verdicts, resource: MyApp.SystemOne.Banding
end
```

The macro expands to an `AshA2ui.Standalone` module in the host. So ADR 0005 holds, and ash_a2ui's verifiers check
every field and action the surface names against the host's resource when the host compiles.

| Surface | Over | Shows | Acts |
|---|---|---|---|
| `Verdicts` | the banding resource | bandings in `review` with no verdict, oldest first: family, question, the model's answer, the reason | record a verdict (the person's value and reason) |
| `BandTables` | the calibration-run resource | proposed tables without a certification: n, the threshold at α, ECE, Brier, the model | certify and publish |
| `Certifications` | the certification resource | the certifications in force, with who certified them | revoke |
| `Calibration` | the calibration-run resource | every run per family in order: n, n per class, ECE, Brier, the threshold at the family's α, the result | none |
| `Facts` | the facts resource | current facts per subject and predicate: value, holds, status, admission grade, the admission behind it | none |

### Every act is an action on the host's resource, under the host's policies

A surface offers only actions that exist on the resource it is bound to, and names them in its allowlist. That's the
MDM steward queue's pattern (ADR 0054). The package documents the contract each surface reads and acts through: the
read's name, the action's name and its arguments.

- **Where the work is the package's own,** the package supplies the implementation as a module the host's action
  names. Recording a verdict for each observation of a banding is the example.
- **Where a read crosses two host resources,** the host declares it, naming its own resource literally. The awaiting
  read is one filter:
  `band == :review and not exists(MyApp.HumanVerdict, judgment_id in parent(observation_ids))`.
- **Where the act reaches host machinery,** the host writes the action itself. Publication is the example: a generic
  action that renders the proposal's DMN, saves the draft in the host's decisions store, records the certification as
  the person and publishes, in one transaction, so a verifier refusal leaves no certification behind. It is an action,
  not ash_a2ui's `via`: `via` swaps the action for a function at click time, so the action's own policies would not
  guard the act.

The verdict, the certification and the revocation are human-only actions (ADR 0059). Each declares its effects
(ADR 0057) as a person's confirmed act: `kind: :execute`, `open_world?: false`, `approval: :confirm`,
`intent: :approve`. An agent's request for one goes through a governed invocation that the person approves
(ADR 0055), never as the person; the verdict is never an agent's (AST-136). A background job or an engine
call cannot run them, and the surface runs them as the person who clicks.

### This application mounts them, and keeps the cross-kind queue and question proposals as its own

ash_enterprise binds the five surfaces under `/app/judgments/*`, lists them in the launcher in a Judgments group, and
gives each an ACP command, so an agent can open one for the person in chat: the agent points, the person clicks. Two parts stay host
surfaces, because their records are the host's own:

- **question proposals** (S1-61, `SystemOne.QuestionProposal`);
- **the cross-kind review queue,** which also counts MDM matches (ADR 0054).

The queue links each kind to the surface that settles it. Every surface keeps its `/admin` equivalent (ADR 0005).

## Does it consume ActorContext?

Yes, through the actions, and only that way. A surface reads through the host resource's read action and acts through
its actions, as the person who opened it. So the grant union and the precomputed `ActorContext` apply exactly as they do
anywhere else, and the surfaces add no second security model. ash_a2ui re-checks each action's `visible_when` and its
allowlist on every invoke. The rows a person may not read never reach the surface.

## Consequences

- An application using `ash_judgments` gets usable screens from five small modules and a handful of host actions,
  where it used to need scripts.
- The package now has a UI dependency, but an optional one. CI's "compiles without the optional dependencies" job
  keeps a host without `ash_a2ui` working.
- The contract is the cost: a host must declare the named reads and actions, and a surface that names one the host
  lacks fails the host's compile. That failure is ash_a2ui's verifier doing its job. Each contract is written in the
  surface's moduledoc.
- Publication stays host machinery. The package never touches a decisions store: it renders and records, and the
  host publishes.

## Reversal

Each surface is a module of a few lines in the host's web layer. Removing one is deleting that module and its route,
and removing all of them is deleting `lib/ash_enterprise_web/a2ui/judgments/` and the routes under `/app/judgments`.
The host actions the surfaces use are ordinary actions and can stay, because scripts and the queue use them too. In the
package, `AshJudgments.A2ui` is one directory behind an optional dependency.

## Alternatives considered

- **Host-only surfaces in ash_enterprise.** This is less work now. But every application built from the template
  would copy the surfaces, and every other host of the package would write them again.
- **Surfaces declared on the fragments.** This would make every host's domain layer depend on `ash_a2ui`, which ADR
  0005 forbids. It would also put UI metadata on records the host owns.
- **`AshA2ui.Dynamic` surfaces assembled at runtime.** These are for surfaces an agent composes. A person-gated
  review screen should be compiled and verified.
