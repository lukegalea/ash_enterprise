defmodule AshEnterprise.Process do
  @moduledoc """
  What starts a process, and which version of it a tenant runs.

  `AshEnterprise.Bpmn` holds processes and `AshEnterprise.Decisions` holds the rules they route
  on. This domain holds the two things that sit *around* them and that neither package can
  supply, because both are statements about how this particular application is operated:

    * **Triggers** — a process starts because something happened, not because someone pressed
      a button wired to it by a developer. `Trigger`, `TriggerCursor` and `TriggerDispatch`
      turn the audit log into a change feed and record what was done with each event.
    * **Bindings** — a `Binding` says which definition of a given key a tenant runs, so the
      platform can ship a baseline and a tenant can diverge from it deliberately rather than
      by forking it forever.

  Also the three host callbacks the process engine requires — `AssignmentResolver`,
  `ActionInvoker` and `DecisionResolver` — which are the seams that keep business logic out of
  the diagram.

  The design, and the measurements the trigger dispatch rests on, are in
  `docs/plans/event-triggered-processes.md`.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Process.Trigger
    resource AshEnterprise.Process.TriggerCursor
    resource AshEnterprise.Process.TriggerDispatch
    resource AshEnterprise.Process.Binding
  end
end
