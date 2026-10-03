defmodule AshEnterprise.SystemOne.ReviewQueue do
  @moduledoc """
  What awaits a person (S1-62's review queue, data surface — no UI):
  one ordered, paginated read across the four kinds of pending work.

  | Kind | Awaits | Source |
  |---|---|---|
  | `:question_proposal` | a person's confirm — the declaration is their act (S1-61) | QuestionProposal, status `:proposed` |
  | `:band_table_proposal` | a person's certification (§8.2) | CalibrationRun, result `:proposed_table`, no certification for the proposed definition yet |
  | `:review_band` | a person's verdict | Banding, band `:review`, no HumanVerdict for any of its observations |
  | `:certification_revocation` | a person's revocation — the run behind the certification has aged past the family's `max_age_days` | BandTableCertification, status `:certified`, aged run |

  Ordered oldest-first across kinds, paginated (`:limit`, `:offset`).
  Reads are person-readable in the platform's ordinary sense: pass
  `actor:`/`tenant:` and every underlying read goes through the
  resource's own policies; without an actor (machinery, tests) they run
  unauthorised.

  Nothing here mutates. Confirming, certifying, verdicting and revoking
  are the resources' own person-gated acts.
  """

  require Ash.Query

  alias AshEnterprise.SystemOne.Banding
  alias AshEnterprise.SystemOne.BandTableCertification
  alias AshEnterprise.SystemOne.CalibrationRun
  alias AshEnterprise.SystemOne.HumanVerdict
  alias AshEnterprise.SystemOne.QuestionProposal
  alias AshJudgments.Calibration.FamilyConfig

  @kinds [:question_proposal, :band_table_proposal, :review_band, :certification_revocation]

  @doc """
  The pending work, oldest first. Opts: `:actor`, `:tenant`, `:limit`
  (default 50), `:offset` (default 0), `:kinds` (default all four).
  Returns `{:ok, %{items: [...], total: n}}`.
  """
  def pending(opts \\ []) do
    kinds = Keyword.get(opts, :kinds, @kinds)
    read_opts = read_opts(opts)

    items =
      kinds
      |> Enum.flat_map(&collect(&1, read_opts))
      |> Enum.sort_by(& &1.queued_since, DateTime)
      |> Enum.drop(max(Keyword.get(opts, :offset, 0), 0))
      |> Enum.take(max(Keyword.get(opts, :limit, 50), 0))

    {:ok, %{items: items, total: length(items)}}
  end

  defp collect(:question_proposal, read_opts) do
    {:ok, proposals} =
      QuestionProposal
      |> Ash.Query.filter(status == ^:proposed)
      |> Ash.Query.sort(proposed_at: :asc)
      |> Ash.read(read_opts)

    Enum.map(proposals, fn proposal ->
      %{
        kind: :question_proposal,
        id: proposal.id,
        family: proposal.source,
        summary:
          "#{length(proposal.proposals)} candidate question(s) drafted from #{proposal.source}",
        queued_since: proposal.proposed_at,
        record: proposal
      }
    end)
  end

  defp collect(:band_table_proposal, read_opts) do
    with {:ok, runs} <- proposed_runs(read_opts),
         {:ok, certifications} <- active_certifications(read_opts) do
      certified_keys = MapSet.new(certifications, & &1.definition_key)

      runs
      |> Enum.filter(fn run ->
        key = proposed_key(run)
        key != nil and not MapSet.member?(certified_keys, key)
      end)
      |> Enum.map(&band_table_proposal_item/1)
    end
  end

  defp collect(:certification_revocation, read_opts) do
    with {:ok, certifications} <- active_certifications(read_opts) do
      certifications
      |> Enum.filter(&run_aged?(&1, read_opts))
      |> Enum.map(&revocation_item/1)
    end
  end

  defp collect(:review_band, read_opts) do
    with {:ok, bandings} <- review_bandings(read_opts),
         {:ok, verdict_ids} <- verdict_ids_for(bandings, read_opts) do
      bandings
      |> Enum.reject(&fully_verdicted?(&1, verdict_ids))
      |> Enum.map(&review_band_item/1)
    end
  end

  defp read_opts(opts) do
    case Keyword.get(opts, :actor) do
      nil -> [authorize?: false]
      actor -> [actor: actor, tenant: Keyword.get(opts, :tenant)]
    end
  end

  defp proposed_runs(read_opts) do
    CalibrationRun
    |> Ash.Query.filter(result == ^:proposed_table)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read(read_opts)
  end

  defp active_certifications(read_opts) do
    BandTableCertification
    |> Ash.Query.filter(status == ^:certified)
    |> Ash.read(read_opts)
  end

  defp proposed_key(run) do
    proposal = run.proposed_band_table

    cond do
      is_map(proposal) and Map.has_key?(proposal, "definition_key") ->
        proposal["definition_key"]

      is_map(proposal) and Map.has_key?(proposal, :definition_key) ->
        proposal[:definition_key]

      true ->
        nil
    end
  end

  defp band_table_proposal_item(run) do
    %{
      kind: :band_table_proposal,
      id: run.id,
      family: run.family,
      summary:
        "band table proposed for #{run.family} at n=#{run.n} (model #{run.model_digest}) — awaiting a person's certification",
      queued_since: run.started_at,
      record: run
    }
  end

  defp run_aged?(certification, read_opts) do
    max_age = FamilyConfig.fetch(certification.family).max_age_days

    case run_started_at(certification, read_opts) do
      %DateTime{} = started_at -> DateTime.diff(DateTime.utc_now(), started_at, :day) > max_age
      _ -> false
    end
  end

  defp run_started_at(certification, read_opts) do
    case certification.calibration_run_id do
      nil ->
        nil

      run_id ->
        CalibrationRun
        |> Ash.Query.filter(id == ^run_id)
        |> Ash.read_one(read_opts)
        |> case do
          {:ok, %CalibrationRun{} = run} -> run.started_at
          _ -> nil
        end
    end
  end

  defp revocation_item(certification) do
    %{
      kind: :certification_revocation,
      id: certification.id,
      family: certification.family,
      summary:
        "certification for #{certification.family} (definition #{certification.definition_key} v#{certification.definition_version}) rests on an aged run — revoke or re-certify",
      queued_since: certification.certified_at,
      record: certification
    }
  end

  defp review_bandings(read_opts) do
    Banding
    |> Ash.Query.filter(band == ^:review)
    |> Ash.Query.sort(banded_at: :asc)
    |> Ash.read(read_opts)
  end

  defp verdict_ids_for(bandings, read_opts) do
    observation_ids = Enum.flat_map(bandings, & &1.observation_ids)

    if observation_ids == [] do
      {:ok, MapSet.new()}
    else
      HumanVerdict
      |> Ash.Query.filter(judgment_id in ^observation_ids)
      |> Ash.read(read_opts)
      |> case do
        {:ok, verdicts} -> {:ok, MapSet.new(verdicts, & &1.judgment_id)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp fully_verdicted?(banding, verdict_ids) do
    Enum.all?(banding.observation_ids, &MapSet.member?(verdict_ids, &1))
  end

  defp review_band_item(banding) do
    %{
      kind: :review_band,
      id: banding.id,
      # §7.1 carries no family column — the family rides the flattened
      # inputs the evaluation consumed.
      family: banding.inputs["family"],
      summary:
        "review-band judgment(s) #{Enum.join(banding.observation_ids, ", ")} awaiting a person's verdict (reason: #{banding.reason_code})",
      queued_since: banding.banded_at,
      record: banding
    }
  end
end
