defmodule AshEnterprise.Execution.Changes.EmitRunFinished do
  @moduledoc """
  A run that reaches a final state announces it, in the same transaction
  (`AshEnterprise.Execution.RunFinished`).

  Attached to every action that can end a run: the claim that fails it, the record that
  completes or fails it, and a cancellation. A transition that leaves the run alive
  announces nothing. The announcement is written as the job runner, whoever ended the run:
  it is the run's own bookkeeping, not an act of the person who asked for the cancellation.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.RunFinished
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor

  @final [:completed, :failed, :cancelled]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      if run.status in @final do
        Execution.emit_run_finished!(
          RunFinished.envelope(run),
          actor: SystemActor.oban(),
          tenant: run.organization_id
        )

        # The run is final and announced, and neither has committed.
        Faults.point(:agent_run_finished_announced)
      end

      {:ok, run}
    end)
  end
end
