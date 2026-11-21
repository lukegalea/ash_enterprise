defmodule AshEnterprise.Documents.Paper.ClauseTableVerifier do
  @moduledoc """
  The publish gate for the `paper.clause.*` decision family, configured as
  `config :ash_decisions, publish_verifiers: [...]`. Every other key is `:ok`.

  A clause table decides what wording goes into a tenant's documents and says
  why, in the matched rule's description — so a table that cannot do its one
  job is refused before it can decide anything:

    * the hit policy is `UNIQUE` — one input, one answer, never two;
    * the only output is `include`, typed `boolean` — the table says in or
      out, nothing else;
    * every rule carries a non-blank `description` — the description is the
      reason the run records; a rule that cannot say why it fires cannot
      include a clause.

  On top of the family's own shape, `AshDecisions.Verifier.verify/1` must
  report no incomplete-table finding: a payload the table has no rule for
  would read as "undecided" and refuse the issue, so a published table is one
  that decided, or explicitly excluded, every input its analysis could prove.
  (What the analysis cannot prove travels as obligations and does not block —
  the membership-column note in `AshEnterprise.Test.Paper.ClauseTables`.)

  Last, the second pair of eyes decides on a measured change, exactly as a
  clause's `admit` does (`AshEnterprise.Documents.Paper.Impact.gate/2`): the
  version's `impact_report` must exist, have been measured for this content
  hash, and hold no failed document. Missing, stale, errored or failed refuses,
  saying which; zero affected documents publishes. The shape checks run first,
  so a table that cannot do its job is refused for that, not for its report.

  The verifier receives the definition's identity
  (`AshDecisions.Config.publish_verifiers/0`) and reads the row by its own id:
  a gate on the row being published, machine-internal, running inside the
  publish action the caller was already authorized for — the same posture as
  ash_decisions' own still-draft validation on its definition, re-reading its row.
  """

  @prefix "paper.clause."

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Documents.Paper.Impact

  require Ash.Query

  @doc "The publish-verifier entry point: `:ok`, or `{:error, reason}`."
  @spec verify(map()) :: :ok | {:error, term()}
  def verify(%{key: key} = identity) when is_binary(key) do
    if String.starts_with?(key, @prefix) do
      identity |> Map.get(:id) |> row() |> check(identity)
    else
      :ok
    end
  end

  def verify(_other), do: :ok

  defp row(nil), do: nil

  # The row being published, by its own id: the one legitimate global read,
  # a primary-key lookup inside that row's own publish action.
  defp row(id) do
    Definition
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  # A draft whose document does not compile has no graph; `ErrorsEmpty`
  # refuses that publish and this gate has nothing to add.
  defp check(nil, _identity), do: :ok

  defp check(definition, identity) when is_map(definition.graph) do
    decisions = definition.graph["decisions"] || %{}

    with :ok <- each_table(decisions),
         :ok <- tables_complete(definition.graph) do
      impact_measured(definition, Map.get(identity, :content_hash) || definition.content_hash)
    end
  end

  defp check(_definition, _identity), do: :ok

  # The report the checker decides on, for exactly the content being published.
  defp impact_measured(definition, content_hash) do
    case Impact.gate(definition.impact_report, content_hash) do
      :ok -> :ok
      {:error, reason} -> {:error, "impact: " <> Impact.refusal(reason)}
    end
  end

  defp each_table(decisions) do
    decisions
    |> Map.values()
    |> Enum.reduce_while(:ok, fn decision, :ok ->
      case table(decision) do
        :ok -> {:cont, :ok}
        {:error, _} = refusal -> {:halt, refusal}
      end
    end)
  end

  defp table(decision) do
    policy = decision["hit_policy"]
    outputs = decision["outputs"] || []
    output_names = Enum.map(outputs, & &1["name"])

    cond do
      policy != "UNIQUE" ->
        {:error, {:not_unique, decision["name"], policy}}

      output_names != ["include"] ->
        {:error, {:output_not_include, decision["name"], output_names}}

      Enum.map(outputs, & &1["type_ref"]) != ["boolean"] ->
        {:error, {:include_not_boolean, decision["name"]}}

      true ->
        described_rules(decision)
    end
  end

  defp described_rules(decision) do
    undescribed =
      Enum.find(decision["rules"] || [], fn rule ->
        description = rule["description"]
        not is_binary(description) or String.trim(description) == ""
      end)

    if undescribed do
      {:error, {:rule_description_missing, decision["name"], undescribed["id"]}}
    else
      :ok
    end
  end

  # No incomplete-table finding: a gap the analysis proved would refuse every
  # issue whose payload fell into it.
  defp tables_complete(graph) do
    case Enum.find(AshDecisions.Verifier.verify(graph).findings, &(&1.kind == :incomplete)) do
      nil -> :ok
      finding -> {:error, {:incomplete_table, finding.path, finding.message}}
    end
  end
end
