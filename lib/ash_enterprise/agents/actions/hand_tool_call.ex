defmodule AshEnterprise.Agents.Actions.HandToolCall do
  @moduledoc """
  `ToolCall.run_tool`: hands an approved call to the agent process that asked for it. It
  writes nothing: the invocation running it becomes `dispatched`, which is what the
  session waits for (`AshEnterprise.Agents.OmpSession`). Outside an invocation there is
  no approved call to hand over, and it is refused.
  """

  use Ash.Resource.Actions.Implementation

  alias AshAgent.Invocation.Dispatch
  alias AshEnterprise.Agents.ToolCall

  @impl true
  def run(input, _opts, _context) do
    case input.context[:ash_agent] do
      %{invocation_id: id} when is_binary(id) ->
        {:ok,
         Dispatch.new(
           effect_system: ToolCall.effect_system(),
           effect_ref: id,
           deadline_at: DateTime.add(DateTime.utc_now(), ToolCall.answer_within()[:days], :day)
         )}

      _not_an_invocation ->
        {:error,
         Ash.Error.Changes.InvalidChanges.exception(
           message: "a tool call runs as its invocation, once its person approves it"
         )}
    end
  end
end
