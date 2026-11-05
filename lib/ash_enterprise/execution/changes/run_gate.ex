defmodule AshEnterprise.Execution.Changes.RunGate do
  @moduledoc """
  A manifest's `check_gate`: runs the release gate (`AshEnterprise.Execution.Release.Gate`)
  and keeps its result as `gate_result`, with the ids of the suite runs it rests on. A
  manifest that passes becomes `requested`; one that does not stays as it is, resolved, with
  the reasons.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Release.Gate

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      result = Gate.check(changeset.data, changeset.tenant)

      changeset =
        Ash.Changeset.force_change_attributes(changeset, %{
          gate_result: result,
          suite_run_ids: Gate.suite_run_ids(result)
        })

      if result["passed"],
        do: AshStateMachine.transition_state(changeset, :requested),
        else: changeset
    end)
  end
end
