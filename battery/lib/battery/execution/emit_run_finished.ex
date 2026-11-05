defmodule Battery.Execution.EmitRunFinished do
  @moduledoc """
  A run that reaches a final state announces it, in the same transaction
  (`Battery.Execution.RunFinished`): attached to every action that can end a run.
  """

  use Ash.Resource.Change

  @final [:completed, :failed, :cancelled]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      if run.status in @final do
        Battery.Execution.RunFinished
        |> Ash.Changeset.for_create(:emit, Battery.Execution.RunFinished.envelope(run))
        |> Ash.create!()
      end

      {:ok, run}
    end)
  end
end
