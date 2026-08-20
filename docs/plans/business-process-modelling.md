# Plan — Business process modelling

- **Status:** **DEFERRED.** Not scheduled. Do not start this work until the current phases are complete — the security
  conformance suite, the CDM adoption process, and the tier-3 seams named in
  [thesis 6](../manifesto/06-reversibility.md). This document exists so that when the question is asked (and on an
  enterprise reference architecture it is always asked), the answer is already reasoned rather than improvised.
- **Date:** 2026-08-13
- **Replaces the guidance in:** `docs/BPMN.md`, which is a raw research transcript for a *different* application. See
  [Appendix A](#appendix-a--what-docsbpmnmd-proposes-and-why-it-does-not-transfer).
- **Depends on:** ADR 0004 (Reactor over Oban Pro for orchestration), still `planned`.

---

## Why this document exists

[Thesis 7](../manifesto/07-what-we-do-not-have.md#3-approval-workflows--maker-checker) already names the gap:

> There is no Ash extension for the single most requested enterprise workflow pattern: an action that requires a second
> person's approval before it takes effect, with delegation, escalation, and an audit trail of who approved what.

That entry says "compose it" and admits the composition "is genuinely more code than the rest of the security model
combined." This document is the design for that code — and, more importantly, the argument for how far *past* approvals
to go.

"Business process modelling" and "BPMN" are not the same request, and conflating them is how this kind of project fails.
BPMN is a notation with an OMG specification and thirty years of enterprise-architecture baggage. Business process
modelling is a set of capabilities enterprises actually need. The second is the requirement; the first is one possible
answer to it, and mostly a bad one for a system shaped like this.

---

## 1. What enterprise BPM actually has to cover

Stated as capabilities, not as diagram elements. This is the requirement list every subsequent section is measured
against.

| # | Capability | Why it is hard |
|---|---|---|
| 1 | **Long-running processes** | Weeks to months. Survives deploys, restarts, and the departure of the person who started it. |
| 2 | **Human tasks and task lists** | A durable work item with an assignee, a due date, an outcome, and a queue view. |
| 3 | **Assignment resolution** | "The requester's manager", "anyone in Procurement for this business unit", "the team that owns the record". Resolved against a live org chart, not a hard-coded user id. |
| 4 | **Approvals and maker-checker** | Segregation of duties: the person who made the change may not be the person who approves it. This is a *negative* rule, and our authorization model has no negative rules (§4.4). |
| 5 | **Timers, reminders, escalation, expiry** | "Remind at 24h, escalate to the manager at 48h, auto-reject at 7 days." Timers must be cancellable when the task completes early. |
| 6 | **Delegation and reassignment** | Out-of-office, workload rebalancing, and the audit consequence: the delegate acted, the delegator is accountable. |
| 7 | **Exclusive and parallel gateways** | Branching on data; fan-out to concurrent branches; join semantics that do not deadlock when one branch dies. |
| 8 | **Compensation** | Undoing committed work when a later step fails. Different from a database rollback, because the work was committed and may be external. |
| 9 | **Process versioning with in-flight instances** | Deploy v4 while three hundred instances of v3 are mid-flight. The hardest problem in the field (§7). |
| 10 | **Audit and traceability** | Who decided what, when, on which version of which process, with what visible to them at the time. |
| 11 | **Correlation** | An external event ("the invoice was paid") advancing the right instance out of thousands. |
| 12 | **Operator visibility** | "Where is requisition 4471 stuck and why" answered by someone who did not write the process. |

Note what is *not* on this list: a visual editor for business analysts. That is a frequently-stated desire, and §8 argues
it is usually a request for *legibility* (can I read what the system does) rather than *authorship* (can I change what
the system does). Those have very different costs.

---

## 2. What BPMN 2.0 actually is, and the subset that matters

BPMN 2.0.2 is an OMG specification of **532 pages**, plus an XML interchange format and execution semantics. (Its PDF
cover is dated December 2013 while the OMG's specification page records adoption in January 2014; both are primary and
they disagree. 2.0.2 itself states that it *"contains a minor change to Clause 15"* — the WS-BPEL mapping, which nobody
implements any more.) The survey cited below counts **267 distinct element variants** in it, 244 of them relevant to
process collaboration. Almost nobody implements it fully, and almost nobody uses it fully.

The empirical case is unusually well evidenced, and it is worth citing the strong version rather than the famous one.

Compagnucci, Corradini, Fornari and Re surveyed **39,695 unique real-world BPMN models** across seven collections
(*Business & Information Systems Engineering* 66(1):43–66, 2023, open access). Findings:

- **59 of the 244 collaboration-relevant elements appear in none of the 38,863 collaboration models.** Not rarely —
  never.
- The average model uses **8 distinct element types**; 84% use between 4 and 14.
- **Exactly six elements appear in more than half of all models**: sequence flow (97.4%), end event (81.7%), start
  event (78.6%), normal task (73.2%), expanded pool (56.8%), lane (52.1%).
- Activities + sequence flows co-occur in 93% of models, + events in 91% ("the core combination"), + gateways in 66%.
- Verbatim on what is *not* used: *"call activities, ad-hoc subprocesses, and in general, all the elements with
  compensation, loop, and multiplicity markers… typed and marked elements are rarely used regardless of the model
  types."*

This replicates zur Muehlen and Recker's much-cited 2008 study (CAiSE, 120 models, BPMN **1.x** and its 50 constructs)
almost exactly — they found an average of 9 distinct constructs per model and *"less than 20% of its vocabulary is
regularly used"* — on a corpus roughly 320× larger, fifteen years later. Cite the 2023 paper; the 2008 one is about a
superseded version of the notation and is routinely misquoted.

The OMG itself concedes the point by defining conformance sub-classes, of which **Common Executable** is the reduced
element set for engines that execute rather than merely draw. A detail worth knowing before anyone promises
"conformance": **`manualTask`, `scriptTask`, `businessRuleTask` and `complexGateway` appear in none of the three
sub-classes.** Three of BPMN's eight task types sit outside every named conformance subset.

The practically-load-bearing subset is small:

- start / end events
- user task, service task
- exclusive gateway (XOR), parallel gateway (AND) and their joins
- timer boundary events (the escalation mechanism)
- message events (correlation)
- sub-process
- lanes (which are *presentation*, not execution semantics — a common and expensive misunderstanding)

Everything else — event-based gateways, complex gateways, ad-hoc sub-processes, transaction sub-processes, the full
event taxonomy — is specification surface that real deployments avoid.

**DMN** (Decision Model and Notation, `formal/24-01-01`), by contrast, has been a genuine success. A DMN decision table
with FEEL expressions is a legitimately good artifact: it is legible to a finance controller, versionable, and testable.
Camunda supports DMN in both 7 and 8 precisely because it earned its place. Two notes for whoever implements §9 phase 3:
the spec now **actively discourages the S-FEEL subset** (*"few if any complete decision models can be defined using
S-FEEL… developers and users are therefore encouraged to use and implement the full FEEL specification"*), and FEEL is
specified to have **no implementation-defined semantics and no side effects** — which is precisely what makes a decision
table safely evaluable as data.

**CMMN** (Case Management) did not. Careful here, because the usual claim is wrong: **Camunda never issued a formal CMMN
deprecation notice** — its Support Announcements page does not mention CMMN at all. What happened was a slow de-facto
removal: a 2020 blog post saying CMMN would be *"maintained but not fully supported"* and a post-mortem titled *"How
CMMN never lived up to its potential"*; the Modeler's `disable-cmmn` flag defaulting to `true` in 4.5.0 (Jan 2021); an
issue in 2022 recording the editor as *"no longer maintained, and currently crashing"*; and finally a November 2025 PR
removing *"the long broken CMMN support in the modeler."* Camunda 8 contains zero occurrences of the string.

The sharpest datum is the CMMN 1.1 specification's own copyright page: every contributing organisation's copyright is
frozen at **2011**, and **neither Camunda nor Flowable — the only two vendors who ever shipped a CMMN engine — appears
on it.** Compare DMN 1.5, whose contributor copyrights run to 2023. Treat CMMN as a dead standard.

**The conclusion for us:** the valuable part of BPMN is a small vocabulary and a set of execution semantics, both of
which are describable in a Spark DSL in a few hundred lines. The expensive part is XML interchange and conformance
claims, which buy nothing unless you are swapping process definitions with another vendor's engine — a requirement we do
not have and should not invent.

---

## 3. Ecosystem survey (verified 2026-08-13)

### 3.1 Elixir/BEAM

There is **no viable BPMN engine on the BEAM.** Two exist and both are abandoned:

| Package | Latest | Last published | Downloads (all time) | Verdict |
|---|---|---|---|---|
| [`bpmn`](https://hex.pm/packages/bpmn) (Hashiru BPMN) | `0.1.0-dev` | 2017-10-21 | ~1,540 | Dead. Never left `-dev`. |
| [`bpxe`](https://hex.pm/packages/bpxe) | `0.4.1` | 2021-01-21 | ~1,350 | Dead. |
| [`rodar`](https://hex.pm/packages/rodar) | `1.4.4` | 2026-03-28 | **82** | Current, Apache-2.0, and essentially unadopted. |
| [`bpe`](https://hex.pm/packages/bpe) (synrc) | `11.4.16` | 2026-04-14 | ~121,000 | Erlang, ISC, genuinely executes BPMN XML. **KVS/Mnesia storage only — no Postgres, no Ecto, no Ash.** Its hex description text does not match its README, so treat the package identity as unverified. |

There is also no Elixir client for Zeebe. The `camunda-community-hub` maintains community clients for Java, Go, C#,
Node, Python, PHP and Delphi — **not Elixir.** There is no official Temporal Elixir SDK either; Temporal ships Go, Java,
TypeScript, Python, .NET, PHP and Ruby, and the Elixir Forum threads on the subject are several years of "someone should
build this."

**There is no Elixir library for human tasks, approvals, or maker-checker.** Searching hex for `approval` returns a
golden-file *approval testing* library and two unrelated packages. This is the gap thesis 7 names, and it is
ecosystem-wide rather than specific to us.

`Ash.Flow` — Ash's own earlier BPMN-flavoured flow DSL — was extracted from core and soft-deprecated, verbatim from its
README: *"Ash.Flow will be supported for the foreseeable future, but we are working to replace it with `Reactor`, and an
accompanying extension, `Ash.Reactor`."* That is a data point worth taking seriously: the Ash core team looked at a
monolithic flow DSL and chose composition of smaller focused tools instead. This plan agrees with that judgement for
step orchestration, and departs from it only for the parts Reactor structurally cannot hold (§4.2).

**A 2026 cohort of durable-execution libraries now exists, and none of it is usable here.** `gen_durable` (0.2.15,
BSD-3, ~60 days old, solo author, zero stars) is the best-engineered — FSM-as-a-row, `{:await, names, next, state,
timeout: :timer.hours(48)}`, signal-by-correlation-key, durable signal inbox with dedup — and is precisely the
escalation primitive §6.4 needs. `durable` (0.1.0-**rc**) has the richest human-in-the-loop API (`wait_for_approval/2`,
`wait_for_form/2`). Both ship their own Postgres queue, duplicating Oban. `gust` (Apache-2.0, 362 stars) is the
healthiest by community metrics but is an Airflow replacement for data pipelines — wrong shape. `sage` has had no
release since 2022 and is in-memory like Reactor. And one licence landmine worth naming: **`journey` is
`LicenseRef-Journey`, non-OSI and source-available**, requiring a commercial key above a revenue threshold *explicitly
including internal business applications*, with a runtime phone-home. That is a legal review, not a `mix.exs` line.

The pattern is consistent: several credible attempts, all young, all solo-maintained, none Ash-aware, none with an
authorization model. This is the state of the art we would be building against, and it argues for owning the small
amount of machinery we actually need rather than adopting a dependency that will be abandoned before our first
reorganisation.

### 3.2 External engines

| Engine | Licence | Production cost | Elixir integration |
|---|---|---|---|
| **Camunda 8 / Zeebe** | Proprietary (Camunda Self-Managed Non-Production *or* Enterprise). Since 8.6 (Oct 2024) **all core components require a commercial licence for production use.** Only the Connector SDK and REST connector are Apache-2.0. | Paid. | None. Build your own gRPC or REST client. |
| **Camunda 7 CE** | Apache-2.0 | **End of life October 2025** (final release 7.24). Enterprise edition extended to April 2030. | None. |
| **Operaton / CIB seven / Fluxnova** | Apache-2.0 forks of Camunda 7 CE, post-EOL | Free, young, small communities | None. JVM service. |
| **Flowable** | Apache-2.0, actively maintained (8.0.0, Feb 2026). **Engines and REST only — see below.** | Free | None. JVM service. |
| **Activiti** | Apache-2.0 | Effectively dead: last GA on Maven Central is **6.0.0 (May 2017)**; 7/8/9 are published only to a vendor's private Nexus | None. |
| **jBPM** | Apache-2.0 | The embeddable engine is frozen at **7.74.1.Final (Jul 2023)**. "Apache KIE jBPM" 10.x is a different, Kogito-derived engine, and KIE is still an Apache **podling**. | None. |
| **Temporal** | MIT (server), commercial cloud | Free self-hosted, heavy ops | No official SDK |

**The Camunda 8 licence change is decisive and it invalidates the recommendation in `docs/BPMN.md`,** which states that
"Self-Managed is free/open-source under the Camunda Community License." That was true before 8.6 and is not true now.
[Thesis 6](../manifesto/06-reversibility.md) records that open-source-only was a requirement for this repository.
Camunda 8 fails it.

**Flowable's open-source story is also worse than it looks, and this matters if anyone proposes it as the Apache-2.0
answer.** Flowable 7 removed **all UI applications** — Modeler, Task, Admin, IDM — from open source, along with the Form
and Content engines. The `modules/flowable-ui` directory exists in the `flowable-6.8.1` tag and does not exist on `main`.
The stated reason is that those apps used unsupported AngularJS; the replacement React modeller is **cloud-only**, and
Flowable staff have confirmed on their own forum that the self-hosted option is a Docker image requiring an enterprise
licence. The BPMN, CMMN and DMN engines and the full REST layer remain genuinely Apache-2.0 — but **open-source Flowable
7+ ships no self-hostable BPMN modeller.** Anyone choosing it for the visual editor would end up embedding `bpmn-js`
themselves anyway (§8), at which point the JVM buys much less than it appeared to.

**Engines do exist outside the JVM, and the shape of them is instructive.** `paed01/bpmn-engine` (Node, MIT, actively
maintained), `bpmnServer/bpmn-server` (TypeScript, MIT), `nitram509/lib-bpmn-engine` (Go, MIT — *explicitly* a BPMN
subset) and SpiffWorkflow (Python, LGPL-3.0, `Development Status :: 4 - Beta`). None is on the BEAM, so none is usable
here. But two things follow. First, a *subset* engine is demonstrably a tractable amount of work for a small team, which
is what §5.1 Option C proposes. Second, SpiffWorkflow's own documentation is the clearest available warning about which
half is hard: *"Spiff's implementation of Service Tasks is abstract, so while they will be parsed, the library provides
no built-in mechanism for executing them"*, and likewise for Data Stores. **Parsing BPMN is the easy half. Executing it
against a real domain is the half nobody hands you.**

### 3.3 What we already depend on

Versions from `mix.lock`, verified against vendored source in `deps/`:

`ash 3.31.3` · `reactor 1.0.6` · `ash_state_machine 0.2.13` · `ash_oban 0.8.12` · `oban 2.23.1` (Basic engine,
`pro?: false`) · `ash_events 0.7.0`

---

## 4. What our stack covers, precisely — and where each one stops

This section is the load-bearing one. Vague claims about what Reactor "can do" are how this project goes wrong, so each
finding below was verified against the vendored source, not recalled.

### 4.1 `ash_state_machine` 0.2.13

**Covers:** a declared set of states, a declared set of legal `(action, from, to)` transitions, compile-time
verification that transition actions exist, a policy check (`valid_next_state`) usable in `Ash.can?`, and a generated
Mermaid state diagram.

**Stops at:**

- **One state attribute per resource.** The `state_machine` section takes a single `state_attribute` (default `:state`).
  There is no second machine, no parallel region, no hierarchical/nested state.
- **This matters more here than elsewhere, because ours is already spent.**
  `AshEnterprise.Platform.Resource` adds `AshStateMachine` to every resource with `lifecycle?: true` (the default), and
  `AshEnterprise.Platform.Transformers.AddSystemAttributes` binds it to `lifecycle_status` — the CDM
  `statecode`/`statuscode` pair. A business process's state therefore **cannot** live in a second `state_machine` block
  on the same resource. This alone forces the process instance to be a separate resource, which turns out to be the right
  answer anyway (§5.2).
- No timers, no concurrency, no branching. A state machine says which transitions are legal; it does not say what should
  happen next or when.

### 4.2 `reactor` 1.0.6

Reactor is more capable than it is usually given credit for, and less durable than the marketing around "saga
orchestration" implies. Both halves matter.

**Covers:** a dependency-resolved DAG of steps with automatic concurrency; `compensate/4` and `undo/4` for saga
semantics; `switch` (conditional branching), `group`, `around`, `map`, `compose` (sub-reactors), `recurse`, `wait_for`,
`guard`, `where`; a `Reactor.Middleware` behaviour with `init`, `halt`, `complete`, `error` and per-step `event`
callbacks; and a Mermaid renderer.

**It can halt and resume.** A step returning `{:halt, reason}` causes `Reactor.run/4` to return
`{:halted, %Reactor{state: :halted}}`, and that struct can be passed back into `Reactor.run/2` to continue:

```elixir
# deps/reactor/lib/reactor.ex
@type state :: :pending | :executing | :halted | :failed | :successful
@spec run(...) :: {:ok, any} | {:ok, any, t} | {:error, any} | {:halted, t}
def run(reactor, ...) when is_reactor(reactor) and reactor.state in ~w[pending halted]a do
```

**Stops at persistence — but the truth here is more interesting than "it cannot be done", and getting it exactly right
matters, because someone will try.** There is no persistence layer: no `Reactor.Persistence` behaviour, no
`Reactor.resume/4`. `Reactor.Executor.State` is documented in-source as *"run-time only information."* Async steps run
on a local `Task.Supervisor` — single-node. Searching the repository's entire issue history for `durable`, `durability`,
`serializ` and `checkpoint` returns zero results in each case. The halted struct is:

```elixir
defstruct context: %{}, description: nil, id: nil, inputs: [], intermediate_results: %{},
          middleware: [], plan: nil, return: nil, state: :pending, steps: [], undo: []
```

You *can* `:erlang.term_to_binary/1` that and rehydrate it. This was verified empirically at tag `v1.0.6`, not reasoned
about. Three findings, and the third is the one that decides the design:

1. **Module-backed steps survive.** `step :approve, MyApp.ApproveStep` serialises as a module name and resumes correctly
   across a real VM restart *and* across a recompile of that module. `Jason.encode/1` fails — `term_to_binary` is the
   only option, so the snapshot is opaque and uninspectable.
2. **Inline steps do not, and fail catastrophically.** The DSL compiles `run fn ... end` into a **content-hashed
   generated function** — `&MyReactor.run_0_generated_184ACD2713A85C64F83AF0031192EA65/2`, where the hash derives from
   the function body. Edit the body of a step that has not run yet, deploy, and resume:
   `UndefinedFunctionError: function MyReactor.run_0_generated_184ACD.../2 is undefined`. **Any edit to a pending inline
   step permanently bricks every in-flight checkpoint**, with no migration path, because the old body no longer exists
   anywhere.
3. **Halt is a checkpoint, not a park.** `{:halt, reason}` stores `reason` **as that step's result** and never re-runs
   the step. A gate returning `{:halt, :awaiting_approval}` leaves `intermediate_results: %{gate: :awaiting_approval}`;
   on resume the gate does not re-execute even with changed context, and downstream steps receive `:awaiting_approval`
   as its value. Modelling a human decision therefore requires reaching into the struct and overwriting
   `intermediate_results` by hand — undocumented struct manipulation, on a field with no compatibility guarantee.

There is also a **live bug**: when a halt originates inside a `compose`d sub-reactor, resuming does not resume the child.
The downstream step receives `nil` and the run reports `{:ok, ...}` rather than `{:halted, _}`. Root cause is in
`Reactor.Step.Compose` — with `support_undo?: true` (**the DSL default**) a halted sub-reactor is stored as a
`%Reactor{}`, which has a `return` field but no `:result` key, so the `extract_result` clause fails to match and falls
through to a catch-all returning `{:ok, nil}`. Silent wrong answer, not a crash. Unreported upstream as of this writing;
worth filing.

[Thesis 6](../manifesto/06-reversibility.md) states the practical consequence correctly: *"Reactor's saga orchestration
is in-process; it does not survive a node restart mid-workflow."*

**So the honest position is not "persisting Reactor is impossible" — it is "persisting Reactor requires a discipline
the DSL does not enforce, to buy a checkpoint whose semantics are wrong for human tasks."** You would have to ban inline
steps by convention, accept an opaque binary blob as your process state, hand-mutate an undocumented field to model an
approval, and work around a silent-nil bug in composition. There is prior art —
[`ash_durable_workflow`](https://github.com/sunprema/ash_durable_workflow), the only Ash-native attempt, which drives
`Reactor.run(..., max_iterations: 1, async?: false)` in a loop and `term_to_binary`s the halted struct into a row. It is
two commits, has no licence, is not on hex, and its README's claim to survive deploys was empirically falsified by
exactly the inline-step hash problem above. Read it as a 150-line reference; do not depend on it.

The `Reactor.Middleware` `halt/1` callback is nonetheless a real seam — it is where a persistence layer *could* snapshot
context. But context is not the problem; the step references and the halt semantics are.

**Conclusion:** Reactor is the right tool for *what happens inside one process step* — a multi-step side effect with
compensation, completing in seconds, inside one job. It is the wrong tool for *the process itself*, which must outlive
the BEAM process, the node, and the deploy.

### 4.3 `ash_oban` 0.8.12 + `oban` 2.23.1

**Covers:** durability. Jobs are Postgres rows; they survive everything. Two shapes:

- `triggers` — a cron scheduler (default `"* * * * *"`, i.e. per-minute) streams records matching a `where` expression
  and enqueues one worker job per record. This is the *sweep* pattern: "find everything that has been stuck for two
  days and act on it."
- `scheduled_actions` — plain cron for generic actions.

**One-off timers do work,** which is a common misconception in the other direction. `AshOban.build_trigger/3` passes
unrecognised options through to `Oban.Worker.new/2`, so `schedule_in:` and `scheduled_at:` are available:

```elixir
AshOban.run_trigger(task, :escalate, schedule_in: 48 * 60 * 60, actor: actor)
```

That is a real timer with second granularity, cancellable via `Oban.cancel_job/1` if the job id is recorded.

**Stops at:** everything above a single job. Oban has no notion of a graph, a token, a join, a parent process, or a
compensation history. `config :ash_oban, pro?: false`.

**The Oban Pro entry in [thesis 6](../manifesto/06-reversibility.md) is now understated and should be revisited when
this work is scheduled.** That table records the loss as "durable Workflows, Smart Engine". Since then, **Oban Pro 1.7
(2026-04-30) shipped Signals**, and `Oban.Pro.Worker.await_signal/1` is very nearly the exact primitive this entire
document is about:

```elixir
case await_signal(wait_for: {24, :hours}) do
  {:ok, %{decision: "approved"}} -> charge_card()
  {:ok, %{decision: "rejected"}} -> {:cancel, :rejected}
  {:error, :timeout}             -> {:cancel, :no_decision}
end

Oban.Pro.Worker.signal(job_id, %{decision: "approved"})   # from a controller, IEx, anywhere
```

Per Oban's documentation this *"turns workers into durable state machines that can wait on human approval or third-party
callbacks without holding a job process or database connection open."* Signals are persisted (one delivered before
`await_signal` is reached is consumed on the next call), `Workflow.signal/3` resolves jobs by name within a workflow,
and Oban Web surfaces an "Awaiting Signal" state with its deadline. Pro's Workflows also gained **grafting** — runtime
expansion of a sub-workflow — which is the durable equivalent of a dynamic sub-process.

That is a real answer to capabilities 1, 5 and part of 2, bought rather than built, from a maintainer with a track
record. It does **not** answer capabilities 3, 4, 6 or 9 — assignment resolution, maker-checker, delegation and
versioning are domain problems tied to our authorization model, and no job queue will supply them (§6.3). So Pro would
shorten phase 2, not phase 1, and phase 1 is where the value is. Worth pricing when this work is scheduled; not worth
reopening the open-source-only decision on its own.

Also: the sweep pattern is *reconciliation*, not *scheduling*. It is excellent as a safety net and poor as a primary
driver — a per-minute full-table scan per trigger does not scale to a process with forty node types.

### 4.4 Policies, `ActorContext`, and the maker-checker problem

**Covers:** authorization at the action layer for every caller ([thesis 1](../manifesto/01-model-your-domain.md)), as a
pure union of grants over `(role, privilege, depth)`, sharing, and hierarchy
([thesis 3](../manifesto/03-authorization-is-data.md)), precomputed once per request into
`AshEnterprise.Security.ActorContext`.

**Stops at two things, and both are load-bearing for BPM.**

**(a) The model is forward-only.** `ActorContext` answers *"given this actor, which records can they reach?"* Assignment
needs the inverse: *"given this task, which principals may act on it?"* Nothing in the current design answers that. A
`:deep` grant scoped to a business unit expands to a subtree of unit ids; inverting that into a set of user ids is a
different query, and doing it per task is exactly the per-row query cost the whole `ActorContext` design exists to
avoid. §6 addresses this.

**(b) Maker-checker is a deny rule, and we have banned deny rules.** `CLAUDE.md` non-negotiable #2 and
[thesis 3](../manifesto/03-authorization-is-data.md) both state it: never `forbid_if` for row access, because a single
subtraction destroys additivity and reintroduces order-dependence. But segregation of duties is *inherently*
subtractive: "everyone in Procurement may approve this, **except** the person who raised it."

This tension is real and must be resolved structurally rather than by making an exception. The resolution is in §6.3 and
it is, in one line: **subtract when computing candidates, not when evaluating policy.** The exclusion happens once, at
task creation, and its result is written as rows. The policy then reads those rows and remains a pure grant.

### 4.5 `ash_events` 0.7.0

**Covers:** every create/update/destroy on every platform resource lands in `AshEnterprise.Audit.EventLog` with actor,
changed attributes, and a shared transaction correlation id, plus event replay. If process steps mutate through Ash
actions, process history is audited for free, with no BPM-specific work.

**Stops at:** it is derived from *resource actions*. There is no vocabulary for a domain event that is not a row change
— "the escalation timer fired", "the join is still waiting on the legal branch", "this instance was migrated from v3 to
v4". Those are process facts, not record changes, and they need somewhere to live (§6.5).

### 4.6 Summary of the gap

| Capability (§1) | Covered by | Gap |
|---|---|---|
| 1 Long-running | `ash_oban` | No process identity spanning jobs |
| 2 Human tasks | — | **Nothing** |
| 3 Assignment resolution | — | **Nothing**; and the model is forward-only (§4.4a) |
| 4 Maker-checker | — | **Nothing**; and it conflicts with thesis 3 (§4.4b) |
| 5 Timers / escalation | `ash_oban` (`schedule_in`) | No cancellation bookkeeping, no declaration |
| 6 Delegation | — | **Nothing** |
| 7 Gateways | `Reactor.switch` (in-memory only) | Not durable |
| 8 Compensation | `Reactor` `undo`/`compensate` (in-memory only) | Not durable across days |
| 9 Versioning + in-flight | — | **Nothing** |
| 10 Audit | `ash_events` | No process-level event vocabulary |
| 11 Correlation | — | **Nothing** |
| 12 Operator visibility | `ash_admin`, `clarity` | Nothing process-shaped |

---

## 5. The decision

### 5.1 The three options, argued

**Option A — integrate an existing engine (Camunda 8, Flowable, Operaton, Temporal).**

The case for it is genuine and should not be dismissed: these engines have solved versioning, in-flight migration,
timers, correlation and operator tooling to a depth we will not reach. Camunda's Operate is a better process debugger
than anything we would build.

Rejected, for four reasons in descending weight:

1. **Licence.** Camunda 8 Self-Managed requires a commercial Enterprise licence for production as of 8.6. Open-source
   only is a stated requirement of this repository ([thesis 6](../manifesto/06-reversibility.md)). Camunda 7 CE is EOL as
   of October 2025. The Apache-2.0 options that remain — Flowable, Operaton, CIB seven, Fluxnova — are viable licences
   attached to JVM services, and Flowable's open-source distribution no longer includes a modeller at all (§3.2).
   Activiti and jBPM are, in practice, no longer options.
2. **No client.** There is no Elixir client for Zeebe, Flowable, Operaton or Temporal. The "thin ~150-line gRPC bridge"
   in `docs/BPMN.md` is optimistic; a job worker needs long-polling, lease renewal, backpressure, reconnection,
   idempotency and failure semantics, and it is unmaintained infrastructure the day after it is written. (Camunda 8.8+
   does now expose job activation over REST, which softens this — but does not change the licence.)
3. **Two sources of truth.** The engine owns "where the process is"; Ash owns "what is true." Every operational question
   then requires correlating two systems, and every write is a dual-write with an idempotency requirement.
   `docs/BPMN.md` names this risk correctly and then proceeds anyway.
4. **It contradicts the thesis.** This repository's claim is that cross-cutting enterprise concerns are *declarable*.
   Answering the most-requested enterprise workflow question with "run a JVM next to it" is a legitimate engineering
   answer and an admission that the thesis has a hole. If the hole is real, [thesis 7](../manifesto/07-what-we-do-not-have.md)
   is where it goes — not a second runtime.

**Option B — build a BPMN-2.0-conformant engine in Elixir.**

Rejected without much agony. Conformance is only valuable for interchange with other vendors' engines, which is not a
requirement. The cost is the entire long tail of the specification — the event taxonomy, the XML schema, the
`bpmndi:` diagram interchange namespace — for zero delivered capability. Two Elixir projects have attempted it and both
died before 1.0 (§3.1). Nobody is asking for conformance; they are asking for approvals.

**Option C — a BPMN-*inspired* declarative process DSL over our own stack.**

Recommended. Take the vocabulary that earned its place (§2), express it as a Spark DSL consistent with the rest of the
codebase, compile it to **data** rather than to closures, and execute it with a token interpreter whose durability comes
from Postgres and whose scheduling comes from Oban.

### 5.2 The recommendation, in one paragraph

**Build a token-based process interpreter as an Ash domain, driven by Oban, where every process node resolves to an Ash
action. Reactor is used inside a node, never as the process. Process definitions compile to a JSON snapshot persisted in
the database, so an in-flight instance never depends on a currently-loaded module. Human tasks are first-class
resources whose candidate principals are materialised as rows, which is what makes both the task list query and the
maker-checker exclusion work without violating the additive authorization model.**

The reasoning, compressed: durability must come from Postgres because that is the only thing in this stack that survives
a deploy; the process graph must be data because a code-first definition cannot be pinned by an in-flight instance; and
authorization must stay in the existing policy union because a second authorization model is the exact failure mode
[thesis 5](../manifesto/05-agents-are-users.md) is about.

### 5.3 The architectural line that must not be crossed

> **The process graph orchestrates. It never decides, never validates, and never authorizes.**

Every node calls an Ash action. The action carries the business rule, the validation, and the policy check. If a process
definition contains a business invariant, that invariant is now enforced in one place and bypassed by every other
caller — which is the controller-layer authorization mistake in a new costume. This is the same discipline
`docs/BPMN.md` correctly identifies for its bridge module, generalised.

---

## 6. Design sketch

Names are provisional. Code is illustrative, not final.

### 6.1 The DSL

```elixir
defmodule AshEnterprise.Procurement.RequisitionApproval do
  use AshEnterprise.Process,
    domain: AshEnterprise.Procurement,
    subject: AshEnterprise.Procurement.Requisition

  process do
    key :requisition_approval
    version 3

    start :validate

    # A service task. Calls an Ash action on the subject, as the process actor.
    # Ordinary Ash: policies apply, AshEvents records it.
    task :validate do
      action :validate_budget
      on_error :fail          # :fail | :retry | {:goto, node}
      to :route
    end

    # Exclusive gateway. Conditions are Ash expressions over the subject.
    gateway :route, type: :exclusive do
      branch expr(total_amount > 50_000), to: :executive_approval
      branch expr(total_amount > 5_000), to: :manager_approval
      default to: :auto_approve
    end

    human_task :manager_approval do
      # Candidate clauses UNION, exactly like the policy model (thesis 3).
      candidates role: "Requisition Approver", scope: :owning_business_unit
      candidates hierarchy: :manager_of_owner

      # Segregation of duties. Applied when candidates are RESOLVED,
      # never as a policy `forbid_if`. See section 6.3.
      excluding :created_by

      outcomes [:approved, :rejected, :changes_requested]
      quorum 1

      timer :remind, after: [hours: 24], do: :notify_assignee
      timer :escalate, after: [hours: 48], do: {:reassign, hierarchy: :manager_of_assignee}
      timer :expire, after: [days: 7], do: {:complete, outcome: :rejected}

      on :approved, to: :issue_order
      on :rejected, to: :notify_rejection
      on :changes_requested, to: :await_revision
    end

    # Parallel fan-out, and an explicit join.
    gateway :final_checks, type: :parallel do
      branch to: :legal_review
      branch to: :security_review
    end

    join :checks_complete, waits_for: [:legal_review, :security_review], to: :issue_order

    # A node whose work is a multi-step side effect with compensation.
    # Reactor's correct scope: one node, seconds, one job, in memory.
    task :issue_order do
      reactor AshEnterprise.Procurement.Workflows.IssueOrder
      compensate_with :void_order
      to :done
    end

    finish :done
    finish :notify_rejection, outcome: :rejected
  end
end
```

The DSL compiles, via a Spark transformer, to a plain map: nodes, edges, and *references* to actions by name. No
closures. Conditions are Ash expressions, which are already data (`Ash.Expr`) and already serialisable — this is why
`expr/1` is used rather than an anonymous predicate, and it is not a stylistic choice.

### 6.2 The data model

Six resources, all built on `AshEnterprise.Platform.Resource` so they inherit ownership, tenancy, audit and policies
like everything else ([thesis 4](../manifesto/04-batteries-are-inherited.md)).

| Resource | Holds | Notes |
|---|---|---|
| `Process.Definition` | `key`, `version`, `graph` (jsonb snapshot), `source_module`, `published_on`, `content_hash` | **Immutable.** Written at deploy. The interpreter reads this, never the module. |
| `Process.Instance` | `definition_id`, `subject_type`, `subject_id`, `correlation_id`, `lifecycle_status` | Pins one definition version for life. |
| `Process.Token` | `instance_id`, `node`, `status`, `parent_token_id`, `scheduled_job_id` | One row per live branch. Parallel gateways create N; joins consume N. |
| `Process.Task` | `instance_id`, `token_id`, `node`, `assignee_id`, `claimed_on`, `due_on`, `outcome`, `decided_by_id`, `delegated_from_id` | The human work item. |
| `Process.TaskCandidate` | `task_id`, `principal_id` | Materialised. §6.3. Same shape as `Security.AccessGrant`. |
| `Process.Event` | `instance_id`, `token_id`, `kind`, `node`, `data` | Process-level facts `ash_events` cannot express. §6.5. |

**Why a token table rather than a state column.** A single state column cannot represent two concurrent branches, and
[§4.1](#41-ash_state_machine-0213) establishes that the resource's one state machine is already spent on the CDM
lifecycle anyway. Tokens are also what make joins expressible: a join node is "delete N sibling tokens, create one", in
one transaction, with a unique constraint doing the deadlock prevention.

**Why the graph is a jsonb snapshot.** §7. This is not a storage preference; it is the versioning design.

### 6.3 Assignment, candidates, and maker-checker

This is the part worth the most care, and the part `docs/BPMN.md` does not address at all.

When a `human_task` node is entered, the interpreter runs an **assignment resolver** that turns the declared candidate
clauses into a set of principal ids, and writes them as `Process.TaskCandidate` rows. Three consequences follow, and
each solves a problem named earlier:

**(a) It inverts the forward-only authorization model once, not per request.** §4.4a establishes that `ActorContext`
answers "what can this actor reach", not "who can reach this". The resolver performs the inversion explicitly — expand
the role's grants at the declared scope into business unit ids, find the principals holding those roles — and pays for
it once per task rather than once per task-list render.

**(b) The task list becomes one indexed query.** `Process.Task` joined to `Process.TaskCandidate` on the actor's
`principal_ids` (which `ActorContext` already computes: the user id plus their team ids). No policy evaluation per row,
which is [thesis 3](../manifesto/03-authorization-is-data.md)'s performance rule respected rather than excepted.

**(c) Maker-checker stops being a deny rule.** `excluding :created_by` is applied *while building the candidate set* —
it removes rows before they are written. The policy that guards claiming a task is then a pure grant:

```elixir
policies do
  bypass AshEnterprise.Security.Checks.SystemActor do
    authorize_if always()
  end

  policy always() do
    authorize_if AshEnterprise.Security.Checks.RoleGrant
    authorize_if AshEnterprise.Process.Checks.IsTaskCandidate   # one MapSet.member?/2
    authorize_if AshEnterprise.Security.Checks.SharedWithActor
  end
end
```

Still a union. Still no `forbid_if`. Still order-independent. The subtraction happened in *data construction*, which is
a place subtraction is allowed, rather than in *policy evaluation*, where it is not. This is the design's best idea and
the reason to prefer it to bolting an exception onto thesis 3.

`IsTaskCandidate` obeys the never-query rule by reading a `task_candidacies` `MapSet` added to `ActorContext` and loaded
in `AshEnterpriseWeb.Plugs.LoadActorContext`. **That is one more query per request, on every request, for a feature
most requests do not use.** Mitigations: load it lazily on first use, or bound it (candidacies for open tasks only).
Named here because it is a real cost against a hard architectural rule, and it should be measured before it ships.

**Honest limits of materialisation:**

- **Staleness.** A candidate set resolved on Monday does not know about Tuesday's reorganisation. Options: re-resolve on
  a cheap `ash_oban` sweep; or re-check the underlying rule at claim time and treat the rows as an index rather than as
  the authority. The second is more correct and slower. Recommendation: rows are the index, the rule is re-checked at
  claim, and the discrepancy is logged — because a candidate list that silently disagrees with the role model is a bug
  you want to see.
- **Cardinality.** `role: "Employee", scope: :organization` on a 50,000-user tenant materialises 50,000 rows per task.
  The resolver must refuse to materialise above a configured bound and fall back to rule-evaluation-at-claim, accepting
  that the task list for that task is a filtered scan. Refusing loudly is better than a table that quietly becomes the
  largest in the database.
- **Delegation** adds a candidate row and records `delegated_from_id`. The audit entry names the delegate as actor and
  the delegator as accountable — the same distinction `AshEnterprise.Audit.EventLog` already draws between `user_id` and
  `system_actor`, and the CDM's `created_by` vs `created_on_behalf_by`. Reuse it rather than inventing a parallel one.

### 6.4 Execution

Every token advance is one Oban job.

1. Job loads the instance and token, `FOR UPDATE`.
2. Reads the node from `Definition.graph` (the snapshot, not the module).
3. Executes: call an Ash action; evaluate an `expr` and pick a branch; create a `Task` and its candidates; create N child
   tokens; consume N sibling tokens.
4. Writes the next token(s) and a `Process.Event`, in the same transaction.
5. Enqueues the next advance.

Idempotency is `(token_id, node, attempt)` with a unique constraint, so redelivery is safe by construction rather than
by discipline.

**Timers** are Oban jobs with `scheduled_at`, their `id` recorded on the token so completion can `Oban.cancel_job/1`.
Cancellation bookkeeping is exactly the thing that gets forgotten and produces escalation emails for tasks approved four
days earlier.

**A reconciliation sweep** — an `ash_oban` trigger, the pattern §4.3 describes — runs against instances whose token has
no live job. This is the safety net, not the driver, and it is what makes "stuck instance" a detected condition rather
than a support ticket.

**Compensation** across nodes is the interpreter's job, not Reactor's: on failure, walk the completed-node log backwards
and invoke each node's declared `compensate_with` action. Reactor's `undo` handles compensation *within* one node. The
two are different mechanisms at different timescales and conflating them is a known way to produce a system that
half-rolls-back.

### 6.5 Audit

Resource mutations are already audited by `AshEvents` because process nodes call ordinary Ash actions with an actor —
nothing new is required, which is the whole point of [thesis 4](../manifesto/04-batteries-are-inherited.md).

`Process.Event` carries only what the event log structurally cannot: token created/consumed, gateway branch taken (and
the evaluated condition), timer fired, timer cancelled, task assigned/claimed/delegated/escalated, instance migrated.
Correlated to the audit log by `correlation_id`, which `ActorContext` already threads.

The rule: **`Process.Event` never duplicates a row change.** If it is a mutation, it is in the event log. Two logs that
overlap will disagree, and the one an auditor reads will be the wrong one.

---

## 7. Process versioning and in-flight instances

The hardest problem, addressed directly.

**The trap with a code-first DSL.** If the process definition lives in a compiled module, an in-flight instance depends
on that module still existing, still compiling, and still meaning the same thing. Delete a node from the DSL and deploy,
and every instance sitting on that node is unrecoverable — not degraded, *unrecoverable*, because there is no longer any
description of what it was doing. This is the code-first equivalent of dropping a column that live rows still use, and
it is why Camunda deploys BPMN *files* to the engine rather than pointing the engine at source.

**The design consequence: the DSL compiles to data, and the data is deployed.**

1. At compile time, a Spark transformer serialises the graph to JSON and computes a content hash.
2. At deploy time (a release command, next to `mix ash.codegen`), any definition whose hash is not already in
   `Process.Definition` is inserted as a new row with `version = max + 1`. Definitions are never updated, never deleted.
3. `Process.Instance` pins `definition_id` at creation and never changes it.
4. The interpreter reads the snapshot. **It never reads the module.** A definition whose source module has been deleted
   still executes.

That last property is what makes the scheme work, and it costs something: **step implementations are still module and
function references, and those must not be deleted while any instance references them.** A definition snapshot pins the
*shape* of the process, not the *behaviour* of its steps. Mitigation is a CI check — for every action referenced by any
non-terminal node of any definition with live instances, assert the action exists — which is the same class of check as
`mix ash.codegen --check`. It is a linter, not a guarantee, and it should be described as such.

**Migrating in-flight instances.** Three positions, and the recommendation is the boring one:

| Position | Cost | Verdict |
|---|---|---|
| **Never migrate.** Instances finish on their pinned version. | Long-lived processes keep old versions alive for months; a bug fix does not reach them. | **Default.** Correct, cheap, and honest. |
| **Migrate automatically** when the node set is unchanged. | Requires proving graph equivalence. Tempting and wrong: identical node names with changed semantics are exactly the dangerous case. | Rejected. |
| **Migrate explicitly**, via a declared mapping. | Real work per migration. | **The escape hatch.** |

An explicit migration is a declared artifact, reviewed like a database migration:

```elixir
defmodule AshEnterprise.Procurement.RequisitionApproval.MigrateV3ToV4 do
  use AshEnterprise.Process.Migration,
    process: :requisition_approval, from: 3, to: 4

  # Every node with a live token in v3 must appear here or the migration
  # refuses to run. Silence is not a mapping.
  map :manager_approval, to: :manager_approval
  map :executive_approval, to: :senior_approval
  map :legal_review, to: :legal_review

  drop :deprecated_check, then: {:goto, :route}
end
```

Run as a batch job, one instance per transaction, each emitting a `Process.Event` of kind `:migrated` recording both
version ids. A partially-migrated population is a normal intermediate state, not a failure.

**What we are explicitly not solving:** migrating an instance whose *token topology* differs between versions — a
parallel branch added, a join arity changed. Camunda restricts this too. The honest position is that such a change
requires a new process key, and old instances drain on the old key.

---

## 8. Visual modelling

Two distinct requests, routinely conflated, with very different costs.

**"Can I read what the system does?"** — legibility. Almost always the actual request, and cheap. `ash_state_machine`
already generates Mermaid; Reactor already generates Mermaid; `clarity` already renders ER, class and policy diagrams
from live introspection. Generating a Mermaid flowchart from a `Process.Definition` snapshot is perhaps a day's work,
has no dependencies, no licence terms, renders in GitHub and in `ash_admin`, and — because it is generated from the
persisted snapshot rather than from source — **shows what an in-flight instance is actually executing**, which a
hand-maintained diagram never does. Overlay live token positions on it and you have a serviceable process debugger.

**"Can a business analyst change what the system does?"** — authorship. Expensive, and largely a mirage. The nodes call
Ash actions with policies and validations; an analyst who moves a box has not moved the behaviour, and a system where
the diagram and the code can disagree has a new class of production incident.

**On bpmn-js specifically.** The Camunda-maintained modeller is technically excellent and the obvious candidate. Two
things to know before proposing it:

- **Its licence is not MIT.** It is a *modified* MIT licence (Camunda Services GmbH) with an additional mandatory
  clause: the source code that displays the bpmn.io watermark linking to `https://bpmn.io` **must not be removed or
  changed**, and the watermark **must stay fully visible and not be visually overlapped by other elements**. For an
  internal admin tool this is a shrug. For a white-labelled product shipped to enterprise customers it is a procurement
  conversation, and it must be surfaced before anyone builds on it, not after. `dmn-js` and `diagram-js` carry
  comparable terms. `bpmn-moddle` (the XML ↔ JS object mapper, which is the piece that would matter for
  interchange) should be checked separately.
- **Bundling is possible but not free.** `assets/package.json` is deliberately minimal — three packages, all A2UI — and
  esbuild bundles it. bpmn-js and diagram-js are a substantial addition to a build that currently has almost no
  JavaScript surface.

**On round-tripping — do not.** Bidirectional sync between a visual model and a code DSL is a well-known failure mode,
and the reason is structural rather than a matter of implementation quality: the two models are not the same model. The
DSL carries things BPMN cannot express (Ash action references, candidate rules, policy interaction, `expr` conditions).
BPMN carries things the DSL will never implement (the event taxonomy, `bpmndi:` layout, lanes as decoration). Merging
two partially-overlapping models bidirectionally means every edit needs conflict resolution, and the conflicts arrive at
the worst time.

This is not a hunch, and it is worth arming whoever has to argue it, because "surely we can just sync them" is the
single most persistent request in this area. Five pieces of evidence, in ascending order of how hard they are to
dismiss:

1. **BPMN↔BPMN round-tripping is itself unsolved.** The OMG runs a Model Interchange Working Group whose test suite has
   three procedures — Import, Export, and explicitly **Roundtrip** (import a reference `.bpmn`, re-export, diff for data
   loss) — and whose own framing is that *"despite wide adoption of the BPMN notation, smooth BPMN model interchange
   between tools still poses a problem."* If XML → XML between two conforming vendors is lossy, XML ↔ an arbitrary DSL
   is strictly harder.
2. **Camunda built this exact tool and killed it.** `camunda/camunda-cycle` — repository description, verbatim, *"The
   BPMN 2.0 roundtrip tool"* — synchronised diagrams between Camunda Modeler and third-party modelling tools, and was
   one of the four original Camunda BPM components at the 2013 launch. It is now archived, carries two stars, and
   appears nowhere in current documentation. What replaced it is Camunda's *"One Model"* position: *"a single source of
   truth by using the same model for design, execution, monitoring, and analysis… the complexity that comes from dealing
   with multiple models for multiple stakeholders, forcing frequent version confusion and reconciliation, will be
   increasingly untenable."*
3. **Layout is the hard part, and Camunda punted on it.** Their own fluent Java builder — twelve years old, covering
   roughly a dozen element types — documents that it *"is not nearly complete"* and, crucially, that **"Auto layout is
   not provided, therefore the elements of different branches may overlap."** Generating correct BPMN *semantics* from
   code is easy. Generating a diagram a human wants to look at is not. This is also why AWS Step Functions can
   round-trip its Workflow Studio successfully: ASL carries no coordinates at all, so the diagram contains no
   human-authored information a generator could destroy. BPMN carries `bpmndi:` coordinates, and those are exactly the
   information a code generator cannot reconstruct and a human will not forgive losing.
4. **The MDA literature settled this two decades ago.** Bran Selic (co-chair of the UML 2.0 task force), 2003:
   round-trip conversion *"can't perform the kind of abstraction that a human can."* Juha-Pekka Tolvanen, more bluntly:
   *"Having the same information in two places, code and models, is a recipe for trouble."* And a UML **tool vendor**
   conceding the point in public — LieberLieber's CEO, *"Why Round-Trip Engineering does not work"* — notes that
   behavioural constructs simply have no code equivalent. Their recommended alternative is one-way generation plus
   protected regions.
5. **Every system that genuinely achieves bidirectionality does it by having one artifact, not two.** Umple calls it
   "text–diagram duality"; JetBrains MPS persists only the AST and treats every syntax as a projection; Blockly's visual
   *is* the AST. None of them synchronises two artifacts, because none of them has two artifacts.

Temporal's position is the same argument stated for workflows specifically, and their co-founder's framing is the one
to quote: **"The picture is a lie… It doesn't show the real control flow, which is hidden in data-dependent
expressions."** Their documentation is explicit that Temporal *"isn't a no-code Workflow engine — it is
Workflows-as-Code."* Airflow's PMC reached the same place from the other direction: *"Airflow UI is for monitoring, not
for DAG writing."*

**The position:** one-way, DSL → diagram, always. If BPMN XML export is ever required — for an auditor who wants to open
the process in a tool they already have — emit a read-only BPMN 2.0 XML rendering of the Common Executable subset from
the snapshot, and state plainly that it is a *view*, not an interchange format. Do not accept edits back.

---

## 9. Phasing

**Phase 0 — document the composition. (Days. Requires no new code, and should happen regardless of everything above.)**
`ash_state_machine` + `ash_oban` + policies + `AshEvents` already compose into a serviceable single-approval workflow.
Thesis 7 says "compose it" and then does not show how. A worked example in the repository — one resource, one approval,
one escalation trigger, tests — converts a documented gap into a documented pattern, and is the highest
value-per-hour item in this entire document.

**Phase 1 — approvals as a domain. (The real thesis-7 gap. This is the minimum useful deliverable.)**
`Process.Task` and `Process.TaskCandidate`, the assignment resolver, maker-checker via candidate exclusion, delegation,
escalation via `schedule_in` with cancellation bookkeeping, a task-list LiveView, and `ActorContext` integration.
**No process graph. No DSL. No interpreter.** An approval is attached to a resource action, not to a node in a diagram.

This is deliberately the largest single decision in the phasing: **most of the requested value is here, and none of the
hardest problems are.** No versioning, no in-flight migration, no token topology. If phase 1 ships and phase 2 never
starts, the repository is materially better and the gap in thesis 7 is closed. Phase 2 should not begin until phase 1
has been used in anger and its assignment model has survived a reorganisation.

**Phase 2 — the process DSL and interpreter.** Definitions-as-data, the token table, the Oban-driven advance job,
exclusive and parallel gateways with joins, sub-process via composition, the reconciliation sweep, generated Mermaid.

**Phase 3 — the hard half.** Cross-node compensation, explicit version migration with declared mappings, message
correlation, and a DMN-style decision table node (which is more likely to earn its keep than the process graph itself —
see §2).

**Phase 4 — reconsider visual modelling,** with the licence question answered first, and only if Mermaid demonstrably
failed to satisfy the actual request.

**Explicitly never:** BPMN 2.0 conformance claims, CMMN, bidirectional BPMN round-tripping, and a second runtime.

---

## 10. What is genuinely hard, unresolved, or a bad idea

Named honestly, in the spirit of [thesis 7](../manifesto/07-what-we-do-not-have.md).

**Hard, and we have a plan we are not certain about:**

1. **Assignment resolution against a live org chart.** §6.3 materialises candidates and re-checks at claim. The staleness
   and cardinality failure modes are described but not solved, and the correct bound is unknown until someone runs it
   against a real tenant. This is the single most likely thing to be redesigned after first contact.
2. **The extra `ActorContext` query.** Task candidacies violate the spirit of "five queries per request, independent of
   scale" for a feature most requests do not use. Lazy loading is the mitigation and it complicates the one struct in
   the codebase whose simplicity is load-bearing.
3. **Definition snapshots pin shape, not behaviour.** An action referenced by a live instance can be changed or deleted
   and the snapshot will not notice. A CI check narrows this; nothing closes it.
4. **Join semantics under failure.** A parallel branch that dies leaves a join waiting forever. Timeouts on joins are the
   standard answer and they turn a hang into a different wrong answer. There is no good option, only a chosen one.
5. **Testing a process is testing a distributed system.** Every node is a job. Deterministic tests need an inline Oban
   mode and a controllable clock, and the test suite will be slow and occasionally flaky. Budget for it honestly.

**Unresolved, and deliberately left open:**

6. **Does anything here belong upstream?** This is a reference application, not a library
   ([thesis 1](../manifesto/01-model-your-domain.md)) — but "approval workflows" is an ecosystem-wide gap, and an
   `ash_approvals` extension would be more useful to more people than a pattern in one template. Not a decision for this
   document.
7. **Where DMN sits.** A decision-table resource with versioned rules is plausibly *more* valuable than the process
   graph and is nearly independent of it. It may deserve to be promoted ahead of phase 2.
8. **Whether phase 2 is ever justified.** If phase 1 closes the real gap, the process graph may be architecture in
   search of a requirement. It should have to earn phase 2 with a use case that phase 1 provably cannot serve.

**Bad ideas, named so nobody re-proposes them:**

9. **Persisting a halted `Reactor` struct as the process state.** Stated precisely, because the blunt version is wrong
   and someone will check: it *does* work for module-backed steps. It fails for inline `run fn ... end` steps, whose
   generated function names are content hashes — editing a pending step's body bricks every in-flight checkpoint with
   no migration path. It also buys the wrong semantics: halt is a checkpoint that freezes the step's result, not a park
   that re-evaluates, so modelling an approval means hand-mutating an undocumented struct field. And composition is
   currently broken for halts (silent `nil`). §4.2. `ash_durable_workflow` is the worked example of taking this route
   and is not one to follow.
10. **Running Camunda 8 alongside.** Production requires a commercial licence as of 8.6, which fails the open-source
    requirement outright. Separately: no Elixir client, and two sources of truth.
11. **Running Flowable or Operaton alongside.** The licences are fine (Apache-2.0). Everything else is not: a JVM in the
    deployment, no Elixir client, and the split-truth problem unchanged.
12. **Business logic in the process graph.** §5.3. It bypasses policies for every non-process caller and reintroduces
    the exact defect [thesis 1](../manifesto/01-model-your-domain.md) exists to eliminate.
13. **Business data in process variables.** Tokens carry ids and routing signals. Everything else is read from the
    subject through Ash. `docs/BPMN.md` gets this right and it is worth preserving.
14. **A `forbid_if` for maker-checker.** It would work, it would be two lines, and it would break the additive model
    that [thesis 3](../manifesto/03-authorization-is-data.md) is built on. §6.3 exists to avoid it.
15. **BPMN conformance as a goal.** Nobody is asking. Conformance serves interchange, and we do not interchange.

---

## Appendix A — what `docs/BPMN.md` proposes, and why it does not transfer

`docs/BPMN.md` is a ~1,100-line Perplexity research transcript (with four large embedded PNGs accounting for ~95% of its
1.2MB). It is retained for provenance. Its substance:

**What it proposes.** For a product called **VendorPM** — a vendor-compliance platform built on an *existing Node.js and
Postgres system* — deploy **Camunda 8 Self-Managed** (Zeebe, Operate, Tasklist, Identity) alongside a new Elixir/Ash
service. Ash owns domain truth via `AshStateMachine` + `AshPaperTrail` + `AshOban`; Zeebe owns the BPMN diagram, human
task routing, and timers; a "~150-line" Elixir gRPC bridge translates Zeebe jobs into Ash actions and back. Reactor is
used inside a single job handler for compensating side effects. It includes a PRD, a TRD, a resource sketch, a bridge
sketch, a Docker Compose stanza, and a four-sprint delivery plan.

**What it gets right, and this plan keeps:** Ash owns business truth and Postgres is the system of record; the engine
holds routing state only; process variables carry ids, not data; workers must be idempotent; `AshOban` is a safety net
for stalled instances; and business logic must never live in the translation layer. Its closing heuristic — *"use the
process layer for orchestration; use Ash for business truth"* — is the correct principle and §5.3 is its restatement.

**Why it does not transfer:**

1. **Different application.** It is scoped to a specific vendor-compliance product with a legacy Node.js system that
   needs bridging. This repository is a reference architecture with no legacy system, and the Node.js constraint —
   which drives much of its reasoning, including the choice of an engine with a good Node SDK — does not exist here.
2. **Its licence claim is now false.** It states Camunda 8 Self-Managed is "free/open-source under the Camunda Community
   License" with cost "only for infrastructure." Since Camunda 8.6 (October 2024), production use of Zeebe, Operate,
   Tasklist, Identity and Optimize requires a commercial Enterprise licence. This inverts its central cost argument.
3. **Camunda 7 is no longer an out.** Community Edition reached end of life in October 2025.
4. **The bridge is under-costed.** "~150 lines" for a gRPC job worker omits long-polling, lease renewal, backpressure,
   reconnection and failure semantics — and there is no Elixir Zeebe client to start from, in the community hub or
   anywhere else.
5. **It does not address the two problems that actually matter here:** assignment resolved through a real authorization
   model (§6.3), and process versioning with in-flight instances (§7). It mentions version pinning in a single bullet
   and leaves it there.

Three smaller factual errors in it, recorded so they are not propagated:

- It advises falling back to *"a GenServer or `:gen_statem` for the timeout piece"* because AshOban's granularity is
  *"too coarse"* for sub-minute waits. **Wrong.** `AshOban.build_trigger/3` passes unrecognised options through to
  `Oban.Worker.new/2`, so `schedule_in:` gives durable one-off timers at second granularity (§4.3). The advice would
  trade a Postgres-backed timer for one that dies with the node — the opposite of the intended effect.
- It cites `queuert` as a Postgres-native Elixir alternative. **`queuert` is TypeScript** (`kvet/queuert`, targeting
  Kysely/Drizzle/Prisma), not on hex, and not an Elixir option at all.
- It predates Oban Pro 1.7's `await_signal` (April 2026), which is the single most relevant existing primitive for the
  use case it describes, and omits it entirely (§4.3).

Treat it as an input, not as a plan. Where this document contradicts it, this document is the one that was verified.

---

# Correction — 2026-08-20

**Appended, not merged.** Per the convention in [`README.md`](README.md), nothing above this line has
been edited: the useful record is what was predicted against what was found, and a document quietly
brought into line with the code teaches nothing. Two of this plan's positions were settled by building
it, and both were settled differently than the text above expects.

## §8's "one-way, DSL → diagram, always" was resolved by deleting one of the artifacts

[§8](#8-visual-modelling) closes with:

> **The position:** one-way, DSL → diagram, always. If BPMN XML export is ever required […] emit a
> read-only BPMN 2.0 XML rendering of the Common Executable subset from the snapshot, and state plainly
> that it is a *view*, not an interchange format. Do not accept edits back.

That is not what shipped, and the reason it is not is written into `ash_bpmn`'s own rules. Usage rule 3,
verbatim:

> **BPMN XML is the single artifact.** There is no code DSL for processes and there will not be one. Do
> not generate XML from code, do not parse the graph back into domain structures, do not keep a second
> copy of the process anywhere. Edit in the designer (or in the XML), publish, done.

`ash_decisions` rule 1 says the same about DMN XML. So the round-tripping problem §8 spends fifteen
hundred words arming the reader against was not solved — it was **removed**, by removing one of the two
artifacts it needs in order to exist. The document holds the XML in `Definition.xml`; publishing
compiles it into an immutable `Definition.graph` snapshot that the interpreter reads and nothing writes
back. There is one authored thing and one derived thing, and the derived thing is never edited.

§8's own evidence point 5 is the argument for this, and it was in the document the whole time:

> **Every system that genuinely achieves bidirectionality does it by having one artifact, not two.**
> Umple calls it "text–diagram duality"; JetBrains MPS persists only the AST and treats every syntax as
> a projection; Blockly's visual *is* the AST. None of them synchronises two artifacts, because none of
> them has two artifacts.

The conclusion drawn from that point in §8 — emit a read-only view from a DSL — keeps two artifacts and
makes one of them second-class. Taking the point at face value gives the better answer. It is worth
naming as a failure mode of a plan rather than of the reasoning: the evidence was correct, sufficient,
and led somewhere the recommendation did not go.

**What §8 got right and is still true.** Three of its warnings survived contact exactly as written.

- **The watermark obligation is real and is now doubled.** `bpmn-js` *and* `dmn-js` both carry the
  bpmn.io licence, so the attribution must stay visible and unoverlapped in two places. The screenshot
  hazard §8 did not anticipate is that a capture cropped to the designer root can cut it off, so a
  licence obligation is now also a property of the documentation pipeline.
- **Bundling is possible but not free.** `assets/package.json` went from five dependencies to seven, and
  `assets/node_modules` is now 86 MB. §8's "three packages, all A2UI" is stale only in the count; the
  characterisation of the cost was right.
- **Layout is the hard part.** §8's point 3 argues that `bpmndi:` coordinates are the human-authored
  information a code generator cannot reconstruct. That was confirmed from the other direction: the
  hand-written baselines in `priv/bpmn/` initially had no `bpmndi:` section at all, because the engine
  never reads one — and nothing complained until a human opened the designer and saw an empty canvas
  (commit `db52877`). Semantics without layout runs perfectly and cannot be looked at.

## §10.7's "where DMN sits" is answered, and the guess inside it was wrong

[§10.7](#10-what-is-genuinely-hard-unresolved-or-a-bad-idea), verbatim:

> **Where DMN sits.** A decision-table resource with versioned rules is plausibly *more* valuable than
> the process graph and is nearly independent of it. It may deserve to be promoted ahead of phase 2.

DMN sits in its own first-party package, `ash_decisions` — versioned, tenant-scoped, immutable on
publish, with a `businessRuleTask` in `ash_bpmn` as the only way a process reaches one. The first half
of the guess held: the decision layer is separately valuable, and it is reachable without a process
graph at all.

**"Nearly independent of it" was wrong, and wrong in the useful direction.** The two are coupled at the
expression language, and that coupling is the entire reason the work was worth doing. FEEL — DMN's
expression language — replaced `ash_bpmn`'s hand-written `AshBpmn.Expr` outright, so a gateway condition
and a decision table's input entry are now the same grammar evaluated by the same engine through one
adapter module per package. Adopting DMN did not add a second expression language to the platform; it
**removed** one. Had DMN been "promoted ahead of phase 2" as §10.7 suggests, that consolidation would
not have been available — there would have been nothing to consolidate with.

## Two smaller items, recorded so the record is not tidier than the history

**§10.15 — "BPMN conformance as a goal"** says *"Nobody is asking. Conformance serves interchange, and we
do not interchange."* Half of that stands and half does not. BPMN conformance is still not a goal and
`ash_bpmn` refuses everything outside its executable subset by element id. But **DMN conformance became
a goal and is measured**: `mix ash_decisions.tck` runs the vendored official DMN TCK corpus and gates the
build on it, at 97.68% of 3,495 asserted result nodes. The reason the same argument produces the opposite
answer is that the decision layer *does* interchange — the DMN document is the single artifact, it is
authored in a third-party designer, and a customer may reasonably expect to open it in a tool they
already own. §10.15's premise was right; its scope was BPMN, and DMN is not in it.

That interchange has a measured cost, which is the kind of thing this section exists to record:
`dmn-js` emits DMN 1.3 and the engine loads DMN 1.5, so a document drawn in the designer is rejected by
the engine that has to run it. `AshDecisions.Dmn.Profile` rewrites the namespace URIs on the way *into*
the engine and never on the way to storage, and `mix ash_decisions.tck --downgrade` re-runs the whole
corpus rewritten to 1.3 to prove the rewrite changes no answers.

**§10.13 — "business data in process variables"** was listed as a bad idea to be avoided by convention.
It is now a checked invariant instead: a `businessRuleTask` promotes named scalar signals onto
`Token.routing` and the decision's full output map goes to an `Evaluation` row and a `ProcessEvent`,
never to the token. The convention became a property.

The rest of §10 is unchanged and still open. §10.1 in particular — assignment resolution against a live
org chart, *"the single most likely thing to be redesigned after first contact"* — has now had first
contact, and `AshEnterprise.Process.AssignmentResolver` is the thing that will be redesigned.

**Where this correction and the sections above disagree, the code is the arbiter.** The adoption
narrative is [`ash-bpmn-in-reference-app.md`](ash-bpmn-in-reference-app.md); the decision layer's design
is [`decisions-and-feel.md`](decisions-and-feel.md).
