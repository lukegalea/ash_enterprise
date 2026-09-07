# 05 — Engine hygiene

Defects found during the research pass, independent of the event dimension. Each is small;
none should survive the phases it is nearest to. File references are to `deps/ash_bpmn`.

## Correctness

1. **Nested event definitions are silently ignored.** A `timerEventDefinition` inside a
   start event executes as a plain none-start (`compiler/graph.ex:328-330`); an
   `errorEventDefinition` inside an end event completes the instance successfully
   (`graph.ex:275-321`); multi-instance loop characteristics inside a task vanish. A
   diagram can say something the engine does not do, without an error. Fix: the compiler
   refuses any unrecognized child element on a supported node, with the element id — the
   existing refusal style, extended one level down. (Phase 1; the single most important
   item in this list.)

2. **Refusal is prefix-dependent.** The unsupported-child walk only tests `bpmn2:`-prefixed
   elements (`graph.ex:102-112`) while the normalizer also strips `bpmn:`
   (`xml.ex:253-256`), so `<bpmn:subProcess>` slips through the silent-ignore branch.
   Fix: normalize before classifying. (Phase 1.)

3. **Expiry routing ignores conditions and the declared default.** Timer expiry advances
   down the *first* outgoing flow (`runtime/timer_worker.ex:143-146`), unlike
   `complete_task!` which evaluates conditions and honors `default=` (`ash_bpmn.ex:664-697`).
   An expired task whose diagram routes `expired` differently is silently misrouted. Fix:
   expiry routes through the same gateway evaluation as completion — which is also the
   Phase 3 prerequisite for promoting expiry to a first-class boundary.

4. **Gateway semantics live in two places.** The facade re-implements flow evaluation
   after task completion and expiry (`ash_bpmn.ex:633-740`) instead of routing through the
   interpreter (`runtime/interpreter.ex:358-434`), so the two implementations can drift —
   and #3 is the drift, already happened. Fix with #3.

5. **Token consumption bypasses the action layer.** `complete_task!` consumes tokens via
   raw SQL `update_all` (`ash_bpmn.ex:842-865`), an acknowledged workaround for action
   validation ordering. The claim/consume state machine has a hole on the exact path
   processes use most. Fix: make the consume action tolerate the completion ordering
   (or an engine-scoped variant), and delete the SQL.

6. **`escalate` swallows every exception.** `rescue _ -> {:ok, :escalated}` in the timer
   worker (`timer_worker.ex:64-92`) — an escalation resolver that crashed looks identical
   to one that succeeded. Fix: record a `:escalate_failed` process event; the raise/noise
   debate is had once, in the PRD.

7. **`:timer_cancelled` is declared but never emitted** (`resources/process_event.ex:110`,
   no writer anywhere in `lib/`). Either emit it where timers are cancelled
   (`ash_bpmn.ex:214-217`, `449-452`) or delete the constraint value. Emitting is better:
   "was the escalation email for a task approved four days ago actually cancelled?" is a
   real audit question (usage rule 6's canonical incident).

## Consistency with documentation

8. **`my_tasks/2` is N+1** — loads all open tasks, then one candidate query per task
   (`ash_bpmn.ex:485-503`), while the README pitches "one indexed query". Fix: join on
   principal ids as the rule ("candidates are rows") already prescribes.

9. **Join release semantics are undocumented behaviour.** The advance worker releases a
   join when no active sibling tokens remain (`runtime/advance_worker.ex:199-205`) —
   pragmatic dead-branch reconciliation, but neither strict BPMN parallel-join nor an
   inclusive join. Write it down in DESIGN.md §6.2's terms now; decide deliberately
   whether it *becomes* inclusive-gateway semantics if that gateway is ever added.

## Forward-compatibility

10. **Snapshots do not record the FEEL engine version.** Conditions are stored as source
    text so in-flight instances keep evaluating across engine upgrades (`feel.ex:71-75`
    acknowledges the aspiration) — but the engine version that validated at publish is
    not recorded, and `binding="latest"` decisions can change under a running instance
    while definitions cannot. Fix: stamp `boxic_feel` version into the snapshot at
    publish (the `ash_decisions` snapshot already stamps its engines —
    `compiler.ex:512-608`); consider whether `latest` decision bindings in long-lived
    definitions deserve a publish-time warning.

11. **`AshBpmn.Runtime.DomainResolver.existing_module!/1` binary dotted-name lookup
    looks wrong.** Reported during Phase 2 implementation (ash_bpmn PR #6): the
    callable-ref resolver needed `Elixir.`-prefixed spellings to find module atoms
    (`String.to_existing_atom("A.B")` misses the alias atom), and this function appears
    to call `String.to_existing_atom/1` on the bare dotted name when a job carries a
    domain key in its args. **Unverified** — reproduce before fixing; if real, it
    affects every worker that resolves a domain from binary args.
