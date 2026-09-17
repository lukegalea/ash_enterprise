# Adoption prompts — Phase 1 in the demonstration app

> Handoff briefs for agents working in **this repository** (`ash_enterprise`) to adopt
> the Phase 1 library work into the app's demonstration, examples, docs and screenshots.
> Phase 1 landed in `ash_bpmn` (honest compilation + designer authoring); the app pin is
> bumped in the PR that carries this directory. Spec: `README.md` and `prd.md` here;
> implementation evidence in `06-roadmap.md`'s Phase 1 status note.

How to use: run one prompt at a time, in order. Each is self-contained and ends with
acceptance criteria and a verification command. Every prompt assumes the binding rules
of `deps/ash_bpmn/usage-rules.md` — the three that matter most here:

1. **BPMN XML is the single artifact.** Where a prompt demonstrates *designer* capability,
   author in the embedded designer, never by hand-editing XML.
2. **Keep the bpmn.io watermark** visible and unmodified in every screenshot.
3. All mix commands run as `devenv shell -- mix ...`; never export `MIX_ENV`.

Sign-in for designer surfaces: the seeder's `admin@example.com` / `password1234`
(see `.claude/skills/run-the-app/SKILL.md`).

---

## Prompt 1 — Author the Phase 1 demo process in the designer

**Context.** The embedded designer (`/app/processes/:key/designer`) can now author
everything a process needs without touching XML: sequence-flow FEEL conditions with
validate-on-edit, exclusive-gateway default-flow management with live per-flow badges,
businessRuleTask decision bindings (ref + binding + version, input rows, promote rows)
with FEEL validation on every `from` field. A demo process should prove it end to end.

**Do.** Author a new process (suggest key `high_value_review`) in the designer,
containing at minimum: a none start; a user task with candidates and an expiry timer;
a **businessRuleTask** bound to an existing published decision (publish one first at
`/app/decisions/:key/editor` if none suits — e.g. a routing decision over the subject's
amount/tier) with two FEEL input rows and one promoted signal; an **exclusive gateway**
whose branches carry authored conditions (write one condition with a deliberate `==`
first, observe the editor's "FEEL equality is `=`, not `==`" correction, then fix it)
and a declared **default flow** (try selecting a conditioned flow as default, observe
the red *default + condition* badge, then resolve it properly); a merge join; an end
event with an outcome. Publish. Then start an instance against a seeded subject (a
script or seed via the platform domain is fine — `AshEnterprise.Bpmn` facade) and walk
it to completion through the task list at `/app/tasks`, confirming the gateway took the
authored branch in the instance viewer.

**Acceptance.** Published `high_value_review` definition; ≥ 1 completed instance whose
viewer shows the gateway branch taken matching the decision's answer; the XML in the
definition is exactly what the designer wrote (no post-editing). If the process earns
baseline status, publish it as a platform baseline via the `priv/bpmn` + publish-task
flow described in `docs/plans/event-triggered-processes.md` §8.

**Verify.** `devenv shell -- mix test test/ash_enterprise/bpmn` still green; the
definition's `graph` shows `feel_engine` stamped (FR-1.4).

---

## Prompt 2 — Demonstrate honest compilation (the error surface)

**Context.** The compiler now refuses every construct it does not execute — including
constructs nested inside supported nodes that previously vanished silently (a timer
start event used to run as a plain none-start) — and the designer surfaces each error
with a jump-to-element button and red canvas markers. This is a *feature* to
demonstrate, not a failure state to hide.

**Do.** On a scratch copy of the demo process (do not modify the published one), break
it three ways in the designer or XML view: (1) add a `timerEventDefinition` to the
start event; (2) add a `multiInstanceLoopCharacteristics` to the user task; (3) add an
`escalationEventDefinition` to the end event. Attempt to save/publish. Capture, in
words and screenshots: the errors panel listing all three with element ids, the red
canvas markers, and the jump-to-select behavior for each. Then fix all three and show
the panel clearing on successful publish. Also demonstrate one *warning* case: add a
`messageFlow` under definitions referencing the process, and show publish still
succeeds with the warning recorded.

**Acceptance.** A short walkthrough document (`docs/bpmn-event-dimension/` is the right
home, or the app docs page from Prompt 4) with the screenshots from Prompt 3 embedded;
the scratch definition is discarded afterwards.

**Verify.** The published demo definition from Prompt 1 is untouched; a fresh
publish of it still succeeds.

---

## Prompt 3 — Screenshots of the new surfaces

**Context.** `docs/screenshots/` already carries the app's screenshot record (check its
naming convention first — `ls docs/screenshots` — and follow it).

**Do.** Capture, at consistent viewport and zoom, with the bpmn.io watermark intact:

1. The condition editor open on a flow, showing the red inline FEEL error and the
   `=`-not-`==` hint, and a second capture in the green *Valid FEEL* state.
2. The exclusive-gateway panel with the default-flow select and the per-flow status
   badges — include one red *default + condition* badge.
3. The businessRuleTask form with an input row mid-error and one mid-valid.
4. The errors surface from Prompt 2: panel, red canvas markers, and one element
   selected via a jump button.
5. The instance viewer mid-run with the gateway's taken branch highlighted.

Reference them from the walkthrough (Prompt 2) and the docs page (Prompt 4) — a
screenshot nothing links to is a screenshot nobody sees.

**Acceptance.** Files in `docs/screenshots/` following the existing convention, each
referenced from at least one doc.

---

## Prompt 4 — App docs and adoption tests

**Context.** The app's docs describe the BPMN capability set as of the pin before
Phase 1; the specs in `docs/bpmn-event-dimension/` are now the source of truth, and
two behaviors deserve regression cover at the app boundary.

**Do.**
1. Update the app documentation pages that describe process capabilities (find them —
   `docs/HANDOFF.md`, the BPMN-referencing plans, and any README section on processes)
   to state Phase 1 honestly: the compiler refuses what it does not execute;
   conditions/bindings are authored in the designer; publish errors jump to elements.
   Link to `docs/bpmn-event-dimension/` for the roadmap and PRD/TRD.
2. Confirm `docs/plans/README.md`'s row for `event-triggered-processes.md` still reads
   accurately now that its correction appendix exists (append a dated correction note
   there only if the row's claim changed — it should not have).
3. Add two adoption tests under `test/ash_enterprise/bpmn/`:
   - a definition written with the **`bpmn:` prefix** (not `bpmn2:`) on supported nodes
     publishes and produces the same graph as its `bpmn2:` twin (FR-1.2 — prefix
     normalization now makes these first-class);
   - a definition containing a nested unsupported construct (reuse Prompt 2's timer
     start) fails publish through the app's own path with the element id in the error.
4. Run the full gate.

**Acceptance.** Docs updated with links; both tests green; no existing test weakened.

**Verify.** `devenv shell -- mix precommit` — the full local gate, green.
