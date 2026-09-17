# 04 — `ash:call`: exposing actions to diagrams

Decision 2: actions become invokable from process diagrams only when the domain
explicitly marks them — the same opt-in posture `ash_ai` takes for actions agents may
call.

## The problem today

A service task carries exactly one binding: `<ash:taskConfig action="my_app.do_something"/>`
— an opaque string. The compiler *refuses* any other ash attribute on a service task's
config (`compiler/graph.ex:215-227`), the designer offers one free-text field
(`designer_live.ex:649-663`), and at runtime the string goes straight to
`Config.action_invoker!().invoke(action, ctx)` (`runtime/interpreter.ex:269-276`). The
host's `ActionInvoker` module owns the translation — string to resource, action, input
mapping — with nothing checked at publish time. A diagram can name an action that does
not exist; a rename silently breaks every diagram that spelled it the old way; a designer
has no way to know what they may type.

## The `ash_ai` precedent

`ash_ai` exposes actions to agents by **declaration on the domain**, not by reflection:

```elixir
defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshAi]

  tools do
    tool :read_posts, MyApp.Blog.Post, :read
    tool :publish_post, MyApp.Blog.Post, :publish
  end
end
```

Nothing is callable until it appears in that block. That is the property worth copying
exactly: **exposure is a decision, recorded in code review, not a default** — and the
declared set is introspectable, which is what makes a designer dropdown possible.

## The `ash_bpmn` equivalent

```elixir
defmodule MyApp.Finance do
  use Ash.Domain, extensions: [AshBpmn.Domain]

  callables do
    callable :approve_payout, MyApp.Finance.Payout, :approve do
      description "Approves a payout above threshold. Idempotent."
    end
    callable :release_funds, MyApp.Finance.Payout, :release
  end
end
```

and in the diagram, the `businessRuleTask` grammar applied to service tasks:

```xml
<bpmn2:serviceTask id="Task_7" name="Approve payout">
  <bpmn2:extensionElements>
    <ash:call ref="MyApp.Finance.approve_payout"/>
    <ash:inputs>
      <ash:input name="amount" from="subject.total"/>
    </ash:inputs>
    <ash:promote>
      <ash:signal name="approved_at" from="approved_at"/>
    </ash:promote>
  </bpmn2:extensionElements>
</bpmn2:serviceTask>
```

**Verified at publish time**, the way decision references and (in the app) trigger
matches already are: the ref must resolve against the declared callable set, or the
definition does not compile, with the ref named. A rename breaks the publish of every
diagram that used the old name — loudly, at the moment of renaming, which is the correct
moment. The designer's service-task panel becomes a dropdown of exposed callables (name
plus description), and `ash:inputs` becomes argument rows with the action's declared
arguments as the palette — the same introspection `ash_ai` uses to build tool schemas.

## Symmetry with the existing seams

| | `ash:call` (new) | `businessRuleTask` (existing) | `ActionInvoker` (existing) |
|---|---|---|---|
| Reference | domain-exposed callable, verified at publish | decision ref + binding, verified via `DecisionResolver.exists?/1` | opaque string, verified never |
| Inputs | FEEL `from` per action argument | FEEL `from` per declared input | invoker's own guesswork |
| Outputs | `ash:promote` scalars onto routing | `ash:promote` scalars onto routing | `{:ok, map()}` into assigns |
| Who executes | the action, with its validations and policies | the decision definition | the host module |

`ActionInvoker` remains for work that is not an Ash action — HTTP calls, file drops,
anything — and remains the seam `on_complete` approvals use. `ash:call` is not a
replacement for the invoker; it is the *majority case* made safe: the diagram names an
action, the action owns its semantics, and every other caller in the application goes
through the same action with the same policies. The architectural line is not crossed —
it is what makes the binding safe to declare.

## The contract a callable owes the diagram

1. **Idempotent under redelivery** — usage rule 12 already requires this of every
   `ActionInvoker` callback; an exposed action is under the same rule, and the
   `description` is where the author says so.
2. **Its arguments are the input palette.** Only declared action arguments may appear as
   `ash:input name=` values; anything else fails compile. Sensitive arguments are marked
   and the designer shows them as such, but they remain legitimate inputs — the action's
   own validations and policies are the guard, not the diagram's.
3. **Its return value is promotable.** Scalars, named by output — `from` names an output
   of the decision/action and defaults to the signal name; it is **not** a FEEL
   expression, matching the existing `businessRuleTask` promote semantics as verified
   during Phase 1 implementation (≤ 8 per node, the existing promote limits). Nothing
   else crosses back into the token — *tokens carry routing, not business data*.
4. **Its failure is typed.** An `{:error, _}` raise is retried by Oban and then fails the
   instance, or routes to an error boundary when the node declares one (route-only,
   decision 5). Exposed actions are encouraged — not required — to return classified
   Ash errors so boundaries can route on error classes rather than messages.

## What is deliberately not here

- **No automatic exposure, ever.** Reflective discovery over domain code interfaces is
  refused (decision 2); every callable is a reviewed line in a domain.
- **No diagram-side arguments beyond the action's declaration.** The palette is the
  action; the mapping is FEEL; there is no `ash:raw_input` escape hatch.
- **No output payloads onto tokens beyond promote scalars.** If a process needs a
  computed value, it promotes a signal or re-reads the subject.
