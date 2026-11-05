defmodule AshEnterprise.Execution.Actions.RequestPublish do
  @moduledoc """
  `request_publish`: asks for a draft to be published through
  `AshEnterprise.Execution.invoke/4` (`apply_publish`, under four eyes), after checking
  that the draft could be published, so a draft that could not opens no approval for
  anyone to spend.

  The draft is read as the caller. The checks are the fragment's
  (`AshAgent.AgentVersion.Definition.publish_problems/1`: every toolset target declares
  its effects and is unchanged, every limit is set) and this application's
  (`AshEnterprise.Execution.Validations.Publishable`). Both run again when the publish
  itself runs, on the draft as it then stands.

  Each call is a request of its own (a fresh key), so asking again after a request went
  stale, because the draft was revised while it waited, opens a new approval.
  """

  use Ash.Resource.Actions.Implementation

  alias AshAgent.AgentVersion.Definition
  alias AshEnterprise.Execution.Actions.RequestInvocation
  alias AshEnterprise.Execution.Validations.Publishable

  @impl true
  def run(input, _opts, context) do
    with {:ok, draft} <-
           Ash.get(input.resource, input.arguments.record_id, Ash.Context.to_opts(context)),
         :ok <- publishable(draft, input.arguments[:authority]) do
      RequestInvocation.run(
        input,
        [target: :apply_publish, rename: %{record_id: "id"}],
        context
      )
    end
  end

  defp publishable(%{status: :draft} = draft, authority) do
    case Definition.publish_problems(draft) ++ Publishable.problems(draft, authority) do
      [] -> :ok
      problems -> {:error, invalid("cannot publish: " <> Enum.join(problems, "; "))}
    end
  end

  defp publishable(%{status: status}, _authority),
    do: {:error, invalid("only a draft can be published; this version is #{status}")}

  defp invalid(message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: :record_id, message: message)
end
