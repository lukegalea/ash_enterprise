defmodule AshEnterprise.Documents.Paper.Impact do
  @moduledoc """
  What a change to a document's wording would do to documents already issued,
  measured before a second person decides on it (R4).

  A candidate is one of:

    * **a clause version**: a draft `AshEnterprise.Documents.PaperClause` not
      yet admitted. The tenant's recent issued `PaperRun`s whose clause pins
      include that clause's key and locale are re-rendered from their frozen
      inputs (the sealed payload, the pinned theme, the clauses they carried),
      with only that clause swapped for the candidate, and each labelled block
      is compared with what the issued render reads back
      (`AshEnterprise.Documents.Paper.Impact.Rerender` over
      `AshPaper.Compare.compare/3`);
    * **a clause table version**: a draft `AshEnterprise.Decisions.Definition`
      for a `paper.clause.*` key. The key's recorded evaluations are replayed
      against it with `AshDecisions.Replay`, as the measuring person in the
      tenant, and each case is mapped back to the run it decided
      (`AshEnterprise.Documents.Paper.Impact.Table`): which documents would
      gain or lose the clause. Nothing is re-rendered.

  A layout is code, reviewed with the kernel's `mix paper.impact --layout
  <module>` over the fixture samples `config :ash_paper, :impact_samples`
  names (`AshEnterprise.Test.PaperSamples`, test only), never the database.

  ## The baseline control

  A run is compared only when re-rendering it with what it was issued with
  reproduces its recorded output digest, the control `AshDecisions.Replay`
  applies to a recorded evaluation. A run whose frozen inputs are gone (its
  erasure scope was shredded), whose theme the host no longer has, or whose
  bytes no longer reproduce is `:unreproducible`, never `:unchanged`: every
  `:changed` is then the candidate's doing.

  ## The report

  A plain map, every outcome zero-filled:

      %{
        candidate: %{kind: :clause, id: "…", key: "…", content_hash: "…", …},
        measured_at: ~U[…],
        error: nil,                          # or why nothing could be measured
        counts: %{changed: 2, unchanged: 0, unreproducible: 0, failed: 0},
        collateral: 0,                       # runs where more than the clause moved
        cases: [%{run_id: "…", outcome: :changed, blocks: [%{block:, before:, after:}], …}],
        sample: %{taken: 2, cap: 50, truncated: false}
      }

  `sample.truncated` says when the cap cut the sample: there is no silent cap.
  Zero affected runs is a measured report like any other.

  `stored/1` is the form the candidate keeps (`impact_report`): JSON data,
  with each clause case's document text (its title, its blocks' before and
  after text, a failure's detail) sealed under the erasure scope of the run it
  came from, so shredding that person's scope shreds their text out of the
  report while its counts stay. `gate/2` reads that form for the decision.
  """

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.Documents.Paper.Impact.{Rerender, Table}
  alias AshEnterprise.Documents.PaperClause
  alias AshEnterprise.Erasure.Keyring

  @default_cap 50
  @max_cap 200

  @clause_outcomes [:changed, :unchanged, :unreproducible, :failed]
  @table_outcomes [:gains, :loses, :reason_changed, :unchanged, :unreproducible, :failed]

  @labels %{
    "changed" => "Changed",
    "unchanged" => "Unchanged",
    "unreproducible" => "Could not be reproduced",
    "failed" => "Failed",
    "gains" => "Gains the clause",
    "loses" => "Loses the clause",
    "reason_changed" => "Same answer, different reason"
  }

  @typedoc "A gate refusal: why a decision cannot rest on the report."
  @type refusal ::
          :missing
          | {:errored, String.t()}
          | {:stale, String.t() | nil}
          | {:failed, pos_integer()}
          | {:unknown_outcome, term()}
          | :malformed

  @doc "How many runs a measurement takes by default: #{@default_cap}."
  @spec default_cap() :: pos_integer()
  def default_cap, do: @default_cap

  @doc """
  Measures `candidate` in `tenant`: a draft `PaperClause` or a draft
  `paper.clause.*` decision `Definition`. `opts`: `:actor` (who is measuring;
  a table's evaluations are read as them) and `:cap` (default #{@default_cap},
  at most #{@max_cap}).

  Never raises: anything that stops the measurement is the report's `error`,
  which `gate/2` refuses.
  """
  @spec measure(PaperClause.t() | Definition.t(), term(), keyword()) :: map()
  def measure(candidate, tenant, opts \\ [])

  def measure(%PaperClause{} = clause, tenant, opts) do
    candidate = %{
      kind: :clause,
      id: clause.id,
      key: clause.key,
      locale: clause.locale,
      version: clause.version,
      content_hash: clause.content_hash
    }

    cap = cap(opts)
    build(candidate, @clause_outcomes, cap, fn -> Rerender.clause_cases(clause, tenant, cap) end)
  end

  def measure(%Definition{} = definition, tenant, opts) do
    candidate = %{
      kind: :table,
      id: definition.id,
      key: definition.key,
      version: definition.version,
      content_hash: definition.content_hash
    }

    cap = cap(opts)

    build(candidate, @table_outcomes, cap, fn ->
      Table.cases(definition, tenant, cap, Keyword.get(opts, :actor))
    end)
  end

  defp cap(opts) do
    opts |> Keyword.get(:cap, @default_cap) |> max(1) |> min(@max_cap)
  end

  defp build(candidate, outcomes, cap, measure) do
    base = blank(candidate, outcomes, cap)

    case measure.() do
      {:ok, cases, sample} ->
        %{
          base
          | counts:
              Enum.reduce(cases, base.counts, &Map.update(&2, &1.outcome, 1, fn n -> n + 1 end)),
            collateral: Enum.count(cases, &(Map.get(&1, :collateral, []) != [])),
            cases: cases,
            sample: Map.merge(base.sample, sample)
        }

      {:error, reason} ->
        %{base | error: describe(reason)}
    end
  rescue
    error -> %{blank(candidate, outcomes, cap) | error: Exception.message(error)}
  end

  defp blank(candidate, outcomes, cap) do
    %{
      candidate: candidate,
      measured_at: DateTime.utc_now(),
      error: nil,
      counts: Map.new(outcomes, &{&1, 0}),
      collateral: 0,
      cases: [],
      sample: %{taken: 0, cap: cap, truncated: false}
    }
  end

  defp describe(:evaluations_not_readable),
    do: "the measuring person may not read every recorded evaluation of this decision"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason, limit: 10)

  @doc """
  The form a candidate keeps: JSON data (string keys, outcomes as strings),
  each clause case's document text sealed under its run's erasure scope.
  """
  @spec stored(map()) :: map()
  def stored(%{candidate: %{kind: :clause}} = report) do
    report
    |> Map.update!(:cases, &Enum.map(&1, fn c -> seal_case(c) end))
    |> json()
  end

  def stored(report), do: plain(report)

  @doc """
  A report as plain JSON data with nothing sealed: failure reasons in words.
  For reports that carry no document text (a table's).
  """
  @spec plain(map()) :: map()
  def plain(report) do
    report
    |> Map.update!(:cases, fn cases ->
      Enum.map(cases, &Map.update(&1, :reason, nil, fn r -> reason_text(r) end))
    end)
    |> json()
  end

  defp reason_text(nil), do: nil
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 500)

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp seal_case(c) do
    texts = %{
      "title" => c.title,
      "reason" => reason_text(c.reason),
      "blocks" => Enum.map(c.blocks, &[&1.before, &1.after])
    }

    c
    |> Map.drop([:title, :reason])
    |> Map.put(:reason_kind, reason_kind(c.reason))
    |> Map.put(:blocks, Enum.map(c.blocks, &Map.drop(&1, [:before, :after])))
    |> Map.put(:sealed, seal(c.erasure_scope_id, texts))
  end

  defp seal(nil, _texts), do: nil

  defp seal(scope_id, texts) do
    case Keyring.seal(scope_id, Jason.encode!(texts)) do
      {:ok, sealed} -> Base.encode64(sealed)
      {:error, _shredded_or_unknown} -> nil
    end
  end

  defp reason_kind(nil), do: nil
  defp reason_kind(reason) when is_atom(reason), do: to_string(reason)
  defp reason_kind(reason) when is_tuple(reason), do: reason_kind(elem(reason, 0))
  defp reason_kind(_reason), do: "other"

  @doc """
  A stored clause case's sealed text: `%{"title", "reason", "blocks" => [[before, after]]}`
  while its scope is live, `:shredded` once it is not, nil when it has none.
  """
  @spec opened(map()) :: map() | :shredded | nil
  def opened(%{"sealed" => sealed}) when is_binary(sealed) do
    case Keyring.open!(Base.decode64!(sealed)) do
      {:ok, json} -> Jason.decode!(json)
      {:shredded, _marker} -> :shredded
    end
  end

  def opened(_case), do: nil

  @doc """
  Whether a decision may rest on `report` (the stored form) for the candidate
  whose content hash is `content_hash`: `:ok`, or the refusal. Missing,
  errored, stale (measured for another content hash), malformed, a case whose
  outcome is unknown, or any `failed` case: each refuses. Zero cases is a
  measured report.
  """
  @spec gate(map() | nil, String.t() | nil) :: :ok | {:error, refusal()}
  def gate(nil, _content_hash), do: {:error, :missing}
  def gate(%{"error" => error}, _hash) when is_binary(error), do: {:error, {:errored, error}}

  def gate(
        %{"candidate" => %{"content_hash" => measured}, "cases" => cases, "counts" => counts},
        hash
      )
      when is_list(cases) and is_map(counts) do
    cond do
      is_nil(hash) or measured != hash ->
        {:error, {:stale, measured}}

      unknown = Enum.find(cases, &(not known_outcome?(&1))) ->
        {:error, {:unknown_outcome, unknown["outcome"]}}

      (failed = max(Enum.count(cases, &(&1["outcome"] == "failed")), failed_count(counts))) > 0 ->
        {:error, {:failed, failed}}

      true ->
        :ok
    end
  end

  def gate(_report, _hash), do: {:error, :malformed}

  defp known_outcome?(%{"outcome" => outcome}), do: Map.has_key?(@labels, outcome)
  defp known_outcome?(_case), do: false

  defp failed_count(%{"failed" => n}) when is_integer(n), do: n
  defp failed_count(_counts), do: 0

  @doc "A gate refusal in words, for the person deciding."
  @spec refusal(refusal()) :: String.t()
  def refusal(:missing),
    do: "no impact report: measure what this version would change before deciding on it"

  def refusal({:errored, error}), do: "the impact report errored (#{error}): measure it again"

  def refusal({:stale, _measured}),
    do: "the impact report was measured for another version: measure this one again"

  def refusal({:failed, n}),
    do: "the impact report has #{n} document(s) that failed to render or read back"

  def refusal({:unknown_outcome, outcome}),
    do: "the impact report has a case with an unknown outcome (#{inspect(outcome)})"

  def refusal(:malformed), do: "the impact report is malformed: measure it again"

  @doc "The label of a stored outcome."
  @spec label(String.t()) :: String.t()
  def label(outcome), do: Map.get(@labels, outcome, outcome)

  @doc """
  One line saying where a candidate's report stands: not measured, errored,
  stale, or its counts (and whether the cap cut the sample).
  """
  @spec summary(map() | nil, String.t() | nil) :: String.t()
  def summary(report, content_hash) do
    case gate(report, content_hash) do
      {:error, reason} when reason == :missing or elem(reason, 0) in [:errored, :stale] ->
        refusal(reason)

      _ok_or_failed ->
        counts(report)
    end
  rescue
    _malformed -> refusal(:malformed)
  end

  defp counts(%{"counts" => counts, "sample" => sample, "measured_at" => at} = report) do
    tally =
      counts
      |> Enum.filter(fn {_outcome, n} -> n > 0 end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {outcome, n} -> "#{label(outcome)} #{n}" end)

    tally = if tally == "", do: "No issued document affected", else: tally
    collateral = Map.get(report, "collateral", 0)

    [
      tally,
      collateral > 0 && "#{collateral} with blocks beyond the clause moving",
      "#{sample["taken"]} measured (cap #{sample["cap"]})",
      sample["truncated"] && "the cap cut the sample",
      "at #{at}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("; ")
  end

  defp counts(_report), do: refusal(:malformed)
end
