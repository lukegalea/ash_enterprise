defmodule Battery.Execution.ProcessTask do
  @moduledoc """
  A service task that runs a declared target through its invocation, the way a host's
  `AshBpmn.ActionInvoker` does it.

    * The key is the engine's invocation key written out,
      `bpmn:<instance>:<token>:<node>`, the same for every redelivery of one execution of
      the node; the instance and node are its parent.
    * It is asked for, and runs, as the member who started the instance
      (`started_by_id`), never as the engine.
    * A ready row runs inline, in the advance job; the answer is what the row records
      (`AshAgent.Invocation.Failure.bpmn/1`): its result, the business error
      `{:bpmn_error, code, details}` an error boundary catches, or an error the engine
      retries.

  So a redelivery asks again under the same key, gets the row back, and returns what it
  recorded without running the target again.
  """

  alias AshAgent.Invocation.{Failure, Target}
  alias Battery.Execution.{Invocation, Member}

  def run({resource, action}, ctx) do
    with {:ok, starter} <- starter(ctx[:instance]),
         {:ok, row} <- invoke(Target.name(resource, action), ctx, starter),
         {:ok, row} <- settle(row) do
      answer(row)
    end
  end

  @doc "The invocation key for the engine's `{instance_id, token_id, node_id}`."
  def key({instance_id, token_id, node_id}), do: "bpmn:#{instance_id}:#{token_id}:#{node_id}"

  defp starter(%{started_by_id: id}) when is_binary(id), do: Ash.get(Member, id)
  defp starter(_instance), do: {:error, :no_starter}

  defp invoke(target, ctx, starter) do
    {instance_id, _token_id, node_id} = engine_key = ctx[:invocation_key]

    Invocation
    |> Ash.ActionInput.for_action(
      :invoke,
      %{
        target: target,
        args: %{"id" => ctx[:subject].id},
        key: key(engine_key),
        parent: %{"process_instance_id" => instance_id, "process_node_id" => node_id}
      },
      actor: starter
    )
    |> Ash.run_action()
  end

  defp settle(%{status: :ready} = row) do
    with {:ok, _outcome} <-
           Invocation
           |> Ash.ActionInput.for_action(:execute, %{primary_key: %{"id" => row.id}})
           |> Ash.run_action() do
      Ash.get(Invocation, row.id)
    end
  end

  defp settle(row), do: {:ok, row}

  defp answer(row) do
    case Failure.bpmn(row) do
      :completed ->
        {:ok, outputs(row.result)}

      {:error, {:bpmn_error, code, _}} ->
        {:error, {:bpmn_error, code, %{"invocation_id" => row.id}}}

      {:error, {:incident, class, code}} ->
        {:error, {:invocation_failed, row.id, class, code}}

      :waiting ->
        {:error, {:invocation_not_final, row.id, row.status}}
    end
  end

  defp outputs(%{"value" => value}) when is_map(value), do: value
  defp outputs(result) when is_map(result), do: result
  defp outputs(_none), do: %{}
end
