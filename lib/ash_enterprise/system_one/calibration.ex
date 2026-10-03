defmodule AshEnterprise.SystemOne.Calibration do
  @moduledoc """
  The host side of the calibration loop (S1-62): recording runs through
  the n-threshold trigger, and the confidence ramp's read surface.

  **Law 5: thresholds are policy data, earned by calibration.** A run is
  recorded ONCE, and the trigger
  (`AshJudgments.Calibration.propose_band_table/3`) decides — before the
  create — whether it proposes a band table: a run below the family's
  minimum n (or its per-class floor, or its own pre-registered pass bar)
  is recorded as `:no_table` with nothing proposed; a qualifying run is
  recorded as `:proposed_table` carrying the proposal. Negative results
  are kept (ADR 0047 point 7). The review queue surfaces
  `:proposed_table` runs that have no certification yet; nothing here
  certifies, publishes or activates — those are people's acts.

  The confidence ramp (`ramp/2`) is the per-family trajectory the UI lane
  renders: every run in order with n, ECE/Brier, the conformal threshold
  at the family's α, and the currently certified threshold beside them.
  """

  require Ash.Query

  alias AshEnterprise.SystemOne.Banding.Resolver
  alias AshEnterprise.SystemOne.BandTableCertification
  alias AshEnterprise.SystemOne.CalibrationRun
  alias AshJudgments.Calibration
  alias AshJudgments.Calibration.FamilyConfig

  @doc """
  Records one calibration run through the trigger.

  `attrs` are the fragment's `:record` inputs MINUS `result` and
  `proposed_band_table` — those the trigger decides. Returns
  `{:ok, run, outcome}` where outcome is `{:proposed, proposal}` or
  `{:refused, findings}`; a refusal is recorded (negative results are
  kept) and proposes nothing.
  """
  def record_run(attrs, opts \\ []) do
    attrs = Map.new(attrs)
    id = Map.get(attrs, :id) || Ash.UUID.generate()
    attrs = Map.put(attrs, :id, id)
    band_input = band_input(attrs)

    # The proposal names the SAME definition key the banding step's
    # resolver resolves - the earned table and the live lookup cannot
    # drift apart.
    case Calibration.propose_band_table(attrs, band_input,
           definition_key: Resolver.band_table_key(attrs[:family])
         ) do
      {:ok, proposal} ->
        with {:ok, run} <-
               do_record(attrs, id, :proposed_table, normalise_proposal(proposal), opts) do
          {:ok, run, {:proposed, proposal}}
        end

      {:error, findings} ->
        with {:ok, run} <- do_record(attrs, id, :no_table, nil, opts) do
          {:ok, run, {:refused, findings}}
        end
    end
  end

  defp do_record(attrs, id, result, proposed_band_table, opts) do
    CalibrationRun
    |> Ash.Changeset.for_create(
      :record,
      attrs
      |> Map.put(:id, id)
      |> Map.put(:result, result)
      |> Map.put(:proposed_band_table, proposed_band_table),
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant)
    )
    |> Ash.create()
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, error} -> {:error, error}
    end
  end

  # The proposal carries the run id it proposes for — computed before the
  # row exists (the trigger duck-types the attrs map), so the id is minted
  # here and pinned onto the create.
  defp normalise_proposal(proposal) do
    proposal
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp band_input(attrs) do
    %{
      question_hash: List.first(attrs[:question_hashes] || []),
      model_digest: attrs[:model_digest],
      runtime_version: attrs[:runtime_version],
      region: attrs[:region]
    }
  end

  @doc """
  The confidence ramp for a family: every recorded run in order, with n,
  ECE/Brier, the result, and the conformal threshold at the family's α —
  beside the CURRENTLY certified threshold (the published band table's
  basis), so the ramp shows earned-versus-live at a glance. Data only:
  the UI lane renders it.
  """
  @spec ramp(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ramp(family, opts \\ []) do
    config = FamilyConfig.fetch(family)
    alpha_key = Float.to_string(config.alpha)

    read_opts =
      case Keyword.get(opts, :actor) do
        nil -> [authorize?: false]
        actor -> [actor: actor, tenant: Keyword.get(opts, :tenant)]
      end

    with {:ok, runs} <-
           CalibrationRun
           |> Ash.Query.for_read(:by_family, %{family: family})
           |> Ash.read(read_opts) do
      points =
        runs
        |> Enum.reverse()
        |> Enum.map(fn run ->
          %{
            run_id: run.id,
            started_at: run.started_at,
            n: run.n,
            ece: run.ece,
            brier: run.brier,
            result: run.result,
            conformal_threshold: threshold_at(run.conformal_thresholds, alpha_key),
            proposed_band_table: run.proposed_band_table
          }
        end)

      {:ok,
       %{
         family: family,
         alpha: alpha_key,
         points: points,
         current: current(family, read_opts)
       }}
    end
  end

  defp threshold_at(thresholds, alpha_key) when is_map(thresholds) do
    case thresholds[alpha_key] do
      %{threshold: threshold} -> threshold
      %{"threshold" => threshold} -> threshold
      _other -> nil
    end
  end

  defp threshold_at(_thresholds, _alpha_key), do: nil

  defp current(family, read_opts) do
    BandTableCertification
    |> Ash.Query.filter(family == ^family and status == ^:certified)
    |> Ash.Query.sort(certified_at: :desc)
    |> Ash.read_one(read_opts)
    |> case do
      {:ok, nil} ->
        nil

      {:ok, certification} ->
        %{certified_by: certification.certified_by, certified_at: certification.certified_at}

      {:error, error} ->
        {:error, error}
    end
  end
end
