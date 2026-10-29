defmodule AshEnterprise.AgentSpike.Step do
  @moduledoc """
  The `:step` trigger's generic action (S5). Reports what it ran with (the
  tenant, the actor, whether a transaction was open) to the process that
  drained the queue, then claims the row with a filtered update. Two workers
  for one row: one claims it, the other finds the filter no longer matches
  and returns `:skipped`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.AgentSpike.Subject

  @impl true
  def run(input, _opts, context) do
    id = input.arguments.primary_key["id"] || input.arguments.primary_key[:id]

    send(
      self(),
      {:agent_spike_step,
       %{
         id: id,
         tenant: context.tenant,
         actor: context.actor,
         in_transaction?: AshEnterprise.Repo.in_transaction?()
       }}
    )

    opts = [actor: context.actor, tenant: context.tenant, authorize?: true]

    with {:ok, row} <- Ash.get(Subject, id, opts) do
      case row |> Ash.Changeset.for_update(:claim_step, %{}, opts) |> Ash.update() do
        {:ok, _claimed} ->
          {:ok, :stepped}

        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} ->
          {:ok, :skipped}

        {:error, error} ->
          {:error, error}
      end
    end
  end
end
