defmodule AshEnterprise.Quality.AgentReply.FromRun do
  @moduledoc """
  The `:from_run` read of `AshEnterprise.Quality.AgentReply`: an agent run's answer,
  read as the query's actor in the query's tenant, as the reply subject
  `"agent_reply:<run_id>/<case_id>/<epoch>"`.

  The run and its steps are read through `AshEnterprise.Execution`'s own reads with
  the same actor, tenant and `authorize?`, so their policies and the run's seal decide
  what comes back: an actor who may not read the run gets no reply. A missing run, an
  answer that is not text, a run with no answer yet and a run whose scope is shredded
  also give no reply. The query's own filter applies in memory.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Execution
  alias AshEnterprise.Quality

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    args = query.arguments

    opts = [
      actor: context[:actor],
      tenant: query.tenant || context[:tenant],
      authorize?: Map.get(context, :authorize?, true)
    ]

    with {:ok, run} <- read_run(args.agent_run_id, opts),
         {:ok, reply} <-
           reply("agent_reply:#{args.run_id}/#{args.case_id}/#{args.epoch}", run, opts) do
      Ash.Filter.Runtime.filter_matches(context[:domain], List.wrap(reply), query.filter)
    end
  end

  defp read_run(id, opts) do
    Execution.list_agent_runs([query: [filter: [id: id]], load: [:output]] ++ opts)
  end

  defp reply(id, [%{output: %{"value" => text}, erasure_scope_id: scope} = run], opts)
       when is_binary(text) and is_binary(scope) do
    with {:ok, steps} <- Execution.list_agent_steps([query: [filter: [run_id: run.id]]] ++ opts) do
      {:ok,
       struct(Quality.AgentReply, %{
         id: id,
         text: Quality.normalise_text(text),
         agent_run_id: run.id,
         erasure_scope_id: scope,
         status: status(run.status),
         used_tools: Enum.any?(steps, &(List.wrap(&1.tool_calls) != []))
       })}
    end
  end

  defp reply(_id, _no_text_answer, _opts), do: {:ok, nil}

  defp status(:completed), do: :complete
  defp status(:failed), do: :failed
  defp status(_unfinished), do: :stopped
end
