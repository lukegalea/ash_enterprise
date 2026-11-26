defmodule AshEnterprise.Documents.Paper.Impact.Table do
  @moduledoc """
  The table half of `AshEnterprise.Documents.Paper.Impact`: a draft
  `paper.clause.*` decision version replayed over the key's recorded
  evaluations (`AshDecisions.Replay`), each case mapped back to the issued run
  that evaluation decided.

  The evaluations and versions are read as the measuring person in the tenant,
  through their read policies, as `AshDecisions.Replay` always reads: someone
  who may not read the decision's evaluations replays nothing. A replay that
  saw fewer evaluations than the tenant has is not a measurement of what the
  table would do, so it is refused (`:evaluations_not_readable`) rather than
  reported as a clean, empty sample.

  The issue pipeline records each clause decision with the run's id as its
  correlation id (`AshEnterprise.Documents.Paper.Clauses`); that is the link
  back. Evaluations of runs that are not issued documents (a draft's
  rendering, a run blocked later in the pipeline) are left out, and a run
  evaluated more than once (a draft re-checked at issue) counts once, by its
  newest evaluation.

  Each run's outcome:

    * `:gains` / `:loses`: the candidate would put the clause in, or take it
      out;
    * `:reason_changed`: the same answer from another rule, so the run's
      recorded reason would change;
    * `:unchanged`;
    * `:unreproducible`: the recorded answer could not be reproduced (the
      replay's baseline control);
    * `:failed`: the candidate errors, no longer has the decision, or answers
      no boolean `include`, so the document could not be issued under it.
  """

  alias AshDecisions.Replay
  alias AshEnterprise.Decisions.{Definition, Evaluation}
  alias AshEnterprise.Documents.PaperRun

  require Ash.Query

  @doc "The cases for table candidate `definition`, measured as `actor`."
  @spec cases(Definition.t(), term(), pos_integer(), term()) ::
          {:ok, [map()], map()} | {:error, term()}
  def cases(%Definition{} = definition, tenant, cap, actor) do
    recorded =
      Replay.recorded(Definition, Evaluation, definition.key,
        actor: actor,
        tenant: tenant,
        limit: cap + 1
      )

    with :ok <- all_readable(definition.key, tenant, length(recorded), cap) do
      taken = Enum.take(recorded, cap)
      %{cases: replayed} = Replay.run(definition, taken)
      correlations = correlations(Enum.map(taken, & &1.id), actor, tenant)
      runs = issued_runs(Map.values(correlations), tenant)

      cases =
        replayed
        |> Enum.flat_map(&run_cases(&1, Map.get(runs, Map.get(correlations, &1.id))))
        |> Enum.uniq_by(& &1.run_id)

      {:ok, cases, %{taken: length(taken), truncated: length(recorded) > cap}}
    end
  end

  # How many evaluations of the key the tenant holds, as the machinery counts
  # them, against how many the replay could read (both up to cap + 1).
  defp all_readable(key, tenant, seen, cap) do
    ids =
      Definition
      |> Ash.Query.filter(key == ^key)
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1000)
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(& &1.id)

    held =
      Evaluation
      |> Ash.Query.filter(definition_id in ^ids)
      |> Ash.count!(tenant: tenant, authorize?: false)

    if min(held, cap + 1) > seen, do: {:error, :evaluations_not_readable}, else: :ok
  end

  defp correlations([], _actor, _tenant), do: %{}

  defp correlations(ids, actor, tenant) do
    Evaluation
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :correlation_id])
    |> Ash.read!()
    |> Map.new(&{&1.id, &1.correlation_id})
  end

  # The runs those evaluations decided that are issued documents, by id.
  defp issued_runs(ids, tenant) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))

    PaperRun
    |> Ash.Query.filter(
      id in ^ids and stage == :issued and render_status == :rendered and
        read_back_status == :passed
    )
    |> Ash.Query.select([:id, :created_on])
    |> Ash.Query.limit(length(ids) + 1)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Map.new(&{&1.id, &1})
  end

  # An evaluation whose run is not an issued document is no case.
  defp run_cases(_case, nil), do: []
  defp run_cases(c, run), do: [run_case(c, run)]

  defp run_case(c, run) do
    before = include(c.before)
    after_include = include(c.after)
    outcome = outcome(c.outcome, before, after_include)

    %{
      run_id: run.id,
      evaluation_id: c.id,
      issued_at: run.created_on,
      outcome: outcome,
      before: %{include: before, rules: c.before.rules},
      after: %{include: after_include, rules: (c.after && c.after.rules) || []},
      reason: reason(outcome, c)
    }
  end

  defp outcome(:unreproducible, _before, _after), do: :unreproducible
  defp outcome(replay, _before, _after) when replay in [:now_fails, :skipped], do: :failed

  defp outcome(replay, before, after_include) do
    cond do
      not is_boolean(before) or not is_boolean(after_include) -> :failed
      before and not after_include -> :loses
      after_include and not before -> :gains
      replay == :rules_changed -> :reason_changed
      true -> :unchanged
    end
  end

  defp reason(:failed, %{outcome: :skipped}), do: "the candidate no longer has this decision"
  defp reason(:failed, %{after: %{error: error}}) when is_binary(error), do: error
  defp reason(:failed, %{before: %{error: error}}) when is_binary(error), do: error
  defp reason(:failed, _case), do: "the candidate answers no boolean include"
  defp reason(_outcome, _case), do: nil

  # A single-output table answers the bare value; a context answers `include`.
  defp include(%{answer: %{"value" => value}}) when is_boolean(value), do: value
  defp include(%{answer: %{"value" => %{"include" => value}}}) when is_boolean(value), do: value
  defp include(_answer), do: nil
end
