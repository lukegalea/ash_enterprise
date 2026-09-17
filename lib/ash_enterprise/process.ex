defmodule AshEnterprise.Process do
  @moduledoc """
  Which version of a process or decision a tenant runs.

  `AshEnterprise.Bpmn` holds processes, decisions' rules live in `AshEnterprise.Decisions`,
  and since the trigger-engine adoption the event-triggered dispatch itself — subscriptions,
  the cursor and the dispatch ledger — lives there too, instantiated from `ash_bpmn`'s
  trigger resources. This domain holds the one thing that remains irreducibly *host* policy:
  the `Binding`, which says which definition of a given key a tenant runs, so the platform
  can ship a baseline and a tenant can diverge from it deliberately rather than by forking it
  forever. Resolution is `Resolver`; the engine reads pinned definitions through
  `DefinitionLoader`.

  ## Baseline resolution from the trigger lane — the Phase 2 gap, stated

  The library's correlator resolves a subscription's `process_key` with the definition
  resource's own `latest_published` **in the event's tenant**; as built it offers no
  loader seam at start time. This application's baselines live in the platform
  organization, so a tenant that runs only baselines has nothing for a subscription to
  resolve: the dispatch records `:failed` with reason `:no_definition`. The cross-tenant
  half of the story is served — by `Resolver` for explicit `start_instance` calls, and by
  `DefinitionLoader` for pinned definitions at execution time — but **subscription starts
  resolve in-tenant only, and cross-tenant baseline divergence there is a documented gap
  pending a loader seam in the engine**. A tenant that wants an event-triggered process
  today publishes its own copy (fork the baseline, publish the draft); no speculative
  machinery was built to hide this.

  Also the three host callbacks the process engine requires — `AssignmentResolver`,
  `ActionInvoker` and `DecisionResolver` — which are the seams that keep business logic out of
  the diagram.

  The design, and the measurements the event dispatch rests on, are in
  `docs/plans/event-triggered-processes.md`; the replacement of the prototype's trigger
  pipeline by the library's engine is TRD §10.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Process.Binding
  end
end
