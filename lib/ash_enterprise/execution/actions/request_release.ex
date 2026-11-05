defmodule AshEnterprise.Execution.Actions.RequestRelease do
  @moduledoc """
  `request_release`: runs the release gate on a resolved manifest, keeps what it found, and,
  when it passes, asks for `promote` through `AshEnterprise.Execution.invoke/4` (four eyes).

  Only the manifest's author asks, so the approval, which excludes whoever asked, excludes
  the author. The gate's result is written by `check_gate` before this action answers: a
  manifest that fails it is refused here with the reasons, and the same reasons stay on the
  manifest.

  Each call that passes is a request of its own, so asking again after a request went stale
  opens a new approval.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Actions.RequestInvocation

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, manifest} <- Ash.get(input.resource, input.arguments.record_id, opts),
         :ok <- requestable(manifest, context.actor),
         {:ok, checked} <- Execution.check_release_gate(manifest, %{}, opts) do
      if checked.gate_result["passed"] do
        RequestInvocation.run(input, [target: :promote, rename: %{record_id: "id"}], context)
      else
        {:error,
         invalid(
           "the release gate refused it: " <> Enum.join(checked.gate_result["problems"], "; ")
         )}
      end
    end
  end

  defp requestable(%{status: status}, _actor) when status not in [:resolved, :requested],
    do: {:error, invalid("only a resolved manifest is released; this one is #{status}")}

  defp requestable(%{author_id: author_id}, %{id: author_id}), do: :ok

  defp requestable(_manifest, _actor),
    do: {:error, invalid("only its author asks for a release: the approval excludes them")}

  defp invalid(message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: :record_id, message: message)
end
