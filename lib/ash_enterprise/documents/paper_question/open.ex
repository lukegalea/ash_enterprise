defmodule AshEnterprise.Documents.PaperQuestion.Open do
  @moduledoc """
  `PaperQuestion.open`: the questions the actor's own blocked runs recorded
  and the facts table still cannot answer (`AshEnterprise.Documents.PaperQuestion`).

  A manual read owns its bound (`AshEnterprise.Platform.Transformers.DefaultPagination`
  leaves it alone), so this one applies the platform's: it reads at most
  `max_page_size` of the actor's newest blocked runs, and returns the query's
  `offset` and `limit` of their questions, `default_limit` when the query names
  none and never more than `max_page_size`.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper.Interview
  alias AshEnterprise.Documents.PaperQuestion
  alias AshEnterprise.Platform.Transformers.DefaultPagination
  alias AshEnterprise.Security.ActorContext

  @reasons %{
    "no_fact" => "Not answered yet",
    "stale" => "Your data changed since you answered",
    "expired" => "Your answer has expired",
    "below_grade" => "Not yet answered by a person"
  }

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    opts = context |> Ash.Context.to_opts() |> Keyword.take([:actor, :tenant, :tracer])
    tenant = opts[:tenant] || query.tenant || ActorContext.tenant(opts[:actor])

    case Documents.my_paper_runs(
           opts
           |> Keyword.merge(tenant: tenant, authorize?: true)
           |> Keyword.put(:query,
             filter: [render_status: :failed],
             limit: DefaultPagination.max_page_size()
           )
         ) do
      {:ok, runs} -> {:ok, runs |> questions(tenant) |> page(query)}
      {:error, error} -> {:error, error}
    end
  end

  defp page(rows, query) do
    limit =
      min(query.limit || DefaultPagination.default_limit(), DefaultPagination.max_page_size())

    rows |> Enum.drop(query.offset || 0) |> Enum.take(limit)
  end

  defp questions(runs, tenant) do
    for run <- runs,
        problem <- run.problems,
        problem["kind"] == "missing_fact" do
      {run, problem}
    end
    # `mine` is newest first: the newest run's question stands for its scope.
    |> Enum.uniq_by(fn {_run, problem} -> {problem["predicate"], problem["scope"]} end)
    |> Enum.flat_map(fn {run, problem} ->
      case Interview.status_of(problem, tenant) do
        {:unknown, reason} -> [row(run, problem, reason)]
        _answered -> []
      end
    end)
  end

  # The kind's scope as its values, in key order: the organization is the
  # tenant's own and says nothing.
  defp about(scope) when is_map(scope) do
    scope
    |> Map.delete("organization")
    |> Enum.sort()
    |> Enum.map_join(" ", fn {_key, value} -> to_string(value) end)
  end

  defp about(_scope), do: nil

  defp row(run, problem, reason) do
    struct(PaperQuestion, %{
      id: "#{run.id}/#{problem["predicate"]}",
      run_id: run.id,
      document_kind: run.document_kind,
      about: about(problem["scope"]),
      predicate: problem["predicate"],
      question: problem["question"],
      message: problem["message"],
      evidence: problem |> Map.get("evidence", []) |> List.wrap() |> Enum.join(" "),
      reason: Map.get(@reasons, to_string(reason), to_string(reason))
    })
  end
end
