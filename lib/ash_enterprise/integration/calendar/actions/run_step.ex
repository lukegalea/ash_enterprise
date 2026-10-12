defmodule AshEnterprise.Integration.Calendar.Actions.RunStep do
  @moduledoc """
  `Sync.run_step`: one bounded step of `AshEnterprise.Integration.Calendar.Step`,
  as the action's actor.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.Calendar.Step

  @impl true
  def run(input, _opts, context) do
    Step.run(context.actor, Map.get(input.arguments, :linked_account_id))
  end
end
