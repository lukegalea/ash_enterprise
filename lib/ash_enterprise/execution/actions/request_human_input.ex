defmodule AshEnterprise.Execution.Actions.RequestHumanInput do
  @moduledoc """
  `HumanInput.request`: hands the question on to a person. It writes nothing: the
  invocation running it becomes `dispatched`, and its input task opens with that write
  (`AshEnterprise.Execution.Changes.OpenInputTask`). Asked outside an invocation there is
  nobody to hand it to, and it is refused.
  """

  use Ash.Resource.Actions.Implementation

  alias AshAgent.Invocation.Dispatch
  alias AshEnterprise.Execution.HumanInput

  @impl true
  def run(input, _opts, _context) do
    case input.context[:ash_agent] do
      %{invocation_id: id} when is_binary(id) ->
        {:ok,
         Dispatch.new(
           effect_system: HumanInput.effect_system(),
           effect_ref: id,
           deadline_at: DateTime.add(DateTime.utc_now(), HumanInput.answer_within()[:days], :day)
         )}

      _not_an_invocation ->
        {:error,
         Ash.Error.Changes.InvalidChanges.exception(
           message: "a question is asked through a run's tool call"
         )}
    end
  end
end
