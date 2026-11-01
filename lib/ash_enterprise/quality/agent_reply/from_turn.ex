defmodule AshEnterprise.Quality.AgentReply.FromTurn do
  @moduledoc """
  The `:from_turn` read of `AshEnterprise.Quality.AgentReply`: one answer
  turn, read as the query's actor in the query's tenant, as a reply subject.

  The turn is read through `AshEnterprise.Assistant.Turn`'s own read action
  with the same actor, tenant and `authorize?`, so its policies and its
  seal decide what comes back: an actor who may not read the turn gets no
  reply, never its ciphertext. A question turn, a missing turn and a turn
  whose scope is shredded also give no reply. The query's own filter (the
  authorization filter included) applies in memory.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Assistant.Turn
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Quality

  require Ash.Query

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    args = query.arguments

    with {:ok, id} <- subject_id(args),
         {:ok, turn} <- read_turn(args.turn_id, query, context) do
      records =
        case reply(id, turn) do
          nil -> []
          reply -> [reply]
        end

      Ash.Filter.Runtime.filter_matches(context[:domain], records, query.filter)
    end
  end

  defp read_turn(turn_id, query, context) do
    Turn
    |> Ash.Query.for_read(:read, %{},
      actor: context[:actor],
      tenant: query.tenant || context[:tenant],
      authorize?: Map.get(context, :authorize?, true)
    )
    |> Ash.Query.filter(id == ^turn_id and role == :assistant)
    |> Ash.read_one()
  end

  defp reply(_id, nil), do: nil
  defp reply(_id, %Turn{content: %Shredded{}}), do: nil

  defp reply(id, %Turn{} = turn) do
    struct(Quality.AgentReply, %{
      id: id,
      text: Quality.normalise_text(turn.content),
      turn_id: turn.id,
      thread_id: turn.thread_id,
      erasure_scope_id: turn.erasure_scope_id,
      status: turn.status,
      used_tools: used_tools?(turn)
    })
  end

  defp used_tools?(turn), do: List.wrap(turn.refs) != [] or calls(turn.tool_calls) != []

  defp calls(%{"calls" => calls}) when is_list(calls), do: calls
  defp calls(%{calls: calls}) when is_list(calls), do: calls
  defp calls(_tool_calls), do: []

  defp subject_id(%{run_id: run, case_id: kase, epoch: epoch})
       when is_binary(run) and is_binary(kase) and is_integer(epoch) do
    {:ok, "agent_reply:#{run}/#{kase}/#{epoch}"}
  end

  defp subject_id(%{turn_id: turn_id} = args) do
    if Enum.any?([:run_id, :case_id, :epoch], &(Map.get(args, &1) != nil)) do
      {:error,
       Ash.Error.Query.InvalidArgument.exception(
         field: :run_id,
         message: "run_id, case_id and epoch name a subject together: give all three or none"
       )}
    else
      {:ok, "assistant_turn:#{turn_id}"}
    end
  end
end
