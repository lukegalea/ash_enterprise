defmodule AshEnterprise.Mdm.SecondOpinion do
  @moduledoc """
  A calibrated model second opinion on the pairs the matcher bands review
  (S1-83, ADR 0054).

  The deterministic matcher stays first and is unchanged: it blocks, scores
  and bands every pair in Postgres. Its review band is wide by design, so a
  steward sees many easy pairs. `ask/2` puts one review-banded pair to a
  model, and is called only by `AshEnterprise.Mdm.SecondOpinionWorker`, a
  job: never by a read, a calculation or a policy check (law 3). For the
  pair it

    1. asks `MatchCandidate`'s declared `records_describe_same_entity`
       through its generated judge action, over the side-by-side alone
       (`AshEnterprise.Mdm.Projections.MatchPair`). The answer is a ledger
       row, with the state sealed on it under the golden record's erasure
       scope (the tenant's judged-text scope when the golden has none), so
       shredding the person shreds what the model read about them;
    2. bands the answer through the family's published band table
       (`AshEnterprise.SystemOne.Banding.Step`, family
       `mdm_match_second_opinion`), which records the banding. With no
       published table nothing is banded and the reading is `"unsure"`;
    3. stamps the reading on the candidate (`second_opinion`), which is what
       the steward surface shows;
    4. acts only on an admitted yes from a table with a certification in
       force (`AshEnterprise.Quality.Gate.certified?/3`): the pair is merged
       as the admit band would have merged it, and leaves the queue. Anything
       else (review, omit, a refusal, no table, an uncertified table, an
       admitted no) changes nothing: the pair stays in the queue with the
       opinion shown beside it.

  The family has no low band, so a table earned for it has two ranges, and
  a confident no is never admitted: "not this golden" is a steward's call.

  A steward's later verdict on the pair is also recorded as a human verdict
  on the second opinion's ledger row (`AshEnterprise.Mdm.Changes.StewardVerdict`),
  so it feeds the family's next calibration run.
  """

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{AutoMerge, MatchCandidate, People, StagedRecord}
  alias AshEnterprise.Mdm.Projections.MatchPair
  alias AshEnterprise.Platform.{Correlation, SystemActor}
  alias AshEnterprise.Quality.Gate
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshEnterprise.SystemOne.JudgedState
  alias AshJudgments.Registry.Info

  @question :records_describe_same_entity
  @action :judge_records_describe_same_entity
  @family "mdm_match_second_opinion"
  @subject_type "match_candidate"

  @doc "The declared question."
  @spec question() :: struct()
  def question, do: Info.question(MatchCandidate, @question)

  @doc "The family the second opinion is calibrated and banded in."
  @spec family() :: String.t()
  def family, do: @family

  @doc """
  Whether review-banded pairs are put to the model at all
  (`config :ash_enterprise, #{inspect(__MODULE__)}, enabled: true`). Off by
  default: a deployment turns it on once it has an in-zone instrument.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:ash_enterprise, __MODULE__, [])[:enabled] == true

  @doc "The judge action's input for a side-by-side pair (a map with the projection's four fields)."
  @spec judge_input(map(), keyword()) :: Ash.ActionInput.t()
  def judge_input(pair, opts \\ []) do
    Ash.ActionInput.for_action(MatchCandidate, @action, %{"input" => MatchPair.state(pair)}, opts)
  end

  @doc """
  Asks the second opinion on one candidate, bands it, stamps it and, from a
  certified table only, acts on it (see the moduledoc).

  Returns `{:ok, %{candidate:, reading:, certified?:, acted:}}`, where
  `acted` is `:merged` or `:none`; `{:error, :not_review_banded}` for a
  candidate that is not a pending review-banded staged pair; or
  `{:error, {:judge_failed, error}}` with nothing recorded but what the
  judge wrote.

  Options: `:tenant` and `:instrument` (`model_version`, `model_digest`,
  `runtime_version`) are required; `:actor` (default the `oban` system
  actor), `:correlation_id`, `:judgments` (extra judge-context entries,
  such as a test's `:req_llm`), `:resolver` (the banding step's band-table
  seam), `:band_table` (the family's `Gate.published_band_table/3`, read
  by default) and `:now`.
  """
  @spec ask(MatchCandidate.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ask(%MatchCandidate{} = candidate, opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    opts = Keyword.put_new_lazy(opts, :correlation_id, &Correlation.id/0)

    with :ok <- askable(candidate),
         {pair, golden} = side_by_side(candidate, tenant),
         {:ok, answer, observation_id} <- judge(candidate, pair, golden, opts) do
      AshEnterprise.Repo.transaction(fn ->
        decide(candidate, pair, answer, observation_id, opts)
      end)
    end
  end

  defp askable(%{band: :review, status: :pending, staged_record_id: id}) when is_binary(id),
    do: :ok

  defp askable(_candidate), do: {:error, :not_review_banded}

  # The pair as the steward surface shows it, read as the system: the model
  # reads what the matcher read.
  defp side_by_side(candidate, tenant) do
    system = SystemActor.system()
    staged = Ash.get!(StagedRecord, candidate.staged_record_id, tenant: tenant, actor: system)
    golden = Ash.get!(Person, candidate.golden_id, tenant: tenant, actor: system)
    mapped = staged.mapped || %{}

    pair = %{
      staged_name: mapped["name"],
      staged_email: mapped["email"],
      golden_name: golden.name,
      golden_email: golden.email && to_string(golden.email)
    }

    {pair, golden}
  end

  defp judge(candidate, pair, golden, opts) do
    observation_id = Ash.UUID.generate()
    input = judge_input(pair, actor: Keyword.get(opts, :actor, SystemActor.oban()))

    context =
      SystemOne.judge_context(
        tenant: Keyword.fetch!(opts, :tenant),
        correlation_id: Keyword.fetch!(opts, :correlation_id),
        judgments:
          Map.merge(
            %{
              req_llm: SystemOne.DecisionWire,
              instrument: instrument!(opts),
              subject: %{type: @subject_type, id: candidate.id},
              observation_id: observation_id,
              mode: :live,
              state_ref: %{"purpose" => "second_opinion"}
            },
            Keyword.get(opts, :judgments, %{})
          ),
        judged_state: JudgedState.project(question(), input),
        judged_state_scope_id: golden.erasure_scope_id
      )

    case Ash.run_action(input, context: context) do
      {:ok, answer} -> {:ok, answer, observation_id}
      {:error, error} -> {:error, {:judge_failed, error}}
    end
  end

  defp decide(candidate, pair, answer, observation_id, opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    # Read again: a steward may have decided the pair while the model answered.
    candidate =
      Ash.get!(MatchCandidate, candidate.id, tenant: tenant, actor: SystemActor.system())

    banded = band(candidate, pair, answer, observation_id, opts)

    table =
      Keyword.get_lazy(opts, :band_table, fn -> Gate.published_band_table(@family, tenant) end)

    certified? = Gate.certified?(table, @family, opts)
    reading = Step.reading(banded)

    stamped =
      candidate
      |> Ash.Changeset.for_update(
        :record_second_opinion,
        %{second_opinion: stamp(answer, observation_id, banded, reading, certified?)},
        tenant: tenant,
        actor: SystemActor.system()
      )
      |> Ash.update!()

    acted =
      if certified? and reading == "yes" do
        merge!(stamped, tenant)
      else
        :none
      end

    %{candidate: stamped, reading: reading, certified?: certified?, acted: acted}
  end

  defp band(candidate, pair, answer, observation_id, opts) do
    declared = question()

    Step.band(
      [%{question: declared, answer: answer, observation_id: observation_id}],
      [
        family: @family,
        tenant: Keyword.fetch!(opts, :tenant),
        subject: %{"type" => @subject_type, "id" => candidate.id},
        predicate: declared.question_id,
        subject_state_digest: JudgedState.digest(MatchPair.state(pair)),
        holds_value: true,
        correlation_id: Keyword.fetch!(opts, :correlation_id),
        mode: :live
      ] ++ Keyword.take(opts, [:resolver])
    )
  end

  defp stamp(answer, observation_id, banded, reading, certified?) do
    {band, banding_id, band_table} =
      case banded do
        {:ok, %{band: band, banding: banding}} ->
          {Atom.to_string(band), banding.id, banding.band_table}

        _unbanded ->
          {nil, nil, nil}
      end

    %{
      "judgment_id" => observation_id,
      "question_hash" => question().question_hash,
      "p_true" => probability(answer),
      "reading" => reading,
      "band" => band,
      "banding_id" => banding_id,
      "band_table" => band_table,
      "certified" => certified?
    }
  end

  defp probability(%{probability: p}) when is_number(p), do: p / 1
  defp probability(%{probability: %Decimal{} = p}), do: Decimal.to_float(p)
  defp probability(_answer), do: nil

  # The admit band's own merge (`AutoMerge.admit!/4`), or a people pair's
  # (`People.Pipeline.confirm!/3`), as the system: the certified table
  # decided, so nobody's verdict is recorded. Only a pair still pending in
  # review is merged; one a steward decided meanwhile is left as it is.
  defp merge!(candidate, tenant) do
    system = SystemActor.system()
    staged = Ash.get!(StagedRecord, candidate.staged_record_id, tenant: tenant, actor: system)

    cond do
      candidate.status != :pending or candidate.band != :review ->
        :none

      People.staged?(staged) ->
        People.Pipeline.confirm!(candidate, staged, tenant)

        candidate
        |> Ash.Changeset.for_update(:update, %{status: :auto_merged},
          tenant: tenant,
          actor: system
        )
        |> Ash.update!()

        :merged

      true ->
        golden = Ash.get!(Person, candidate.golden_id, tenant: tenant, actor: system)
        AutoMerge.admit!(candidate, staged, golden, tenant)
        :merged
    end
  end

  defp instrument!(opts) do
    case Keyword.fetch!(opts, :instrument) do
      %{model_version: v, model_digest: d, runtime_version: r} = instrument
      when is_binary(v) and is_binary(d) and is_binary(r) ->
        Map.take(instrument, [:model_version, :model_digest, :runtime_version])

      other ->
        raise ArgumentError, "a second opinion needs an instrument, got #{inspect(other)}"
    end
  end
end
