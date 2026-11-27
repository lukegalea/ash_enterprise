defmodule AshEnterprise.Journeys.EvidenceSink do
  @moduledoc """
  Records a journey run as compliance evidence (`AshJourneys.EvidenceSink`), on the
  `AshEnterprise.Audit.ChainVerifyWorker` template: evidence for each control the
  journey's `metadata` names when the run passed, a `:noncompliant` finding for each when
  it failed.

      EvidenceSink.record(manifest, ir, organization_id: org)

  ## What a run must be to count

  Only a run that proves the journey as it is declared and approved writes anything. A
  run writes nothing, and `record/3` returns `{:error, {:not_evidence, reasons}}`, when

    * it was retried: its `retries` is 1 or more, or a step took more than one attempt
      (flaky). The runner counts a CI re-run (`JOURNEYS_RUN_ATTEMPT`) and a second run at
      the same commit as retries (`AshBrowserTests.Journeys.Candidates`); a second claim
      of one journey in the same VM is an independent first attempt, and counts;
    * it errored: it never reached a verdict;
    * it is stale or from another build: `AshJourneys.Lock.verify/6` refuses the journey's
      approved run (none approved, a newer declaration than the approved one, a lock whose
      pin moved), or the run itself proves another declaration or version than the
      approved one, or ran on another browser build than the lock pins;
    * its manifest does not read back (`AshJourneys.Manifest.decode/1`), including an
      `:operated` run that recorded figures: an operated run records the manifest and
      never figures;
    * the journey names no controls.

  ## What it writes

  A pass writes one artifact per control with `AshCompliance.Ownership.Evidence.record/4`:
  the manifest's own bytes (JSON, never a figure), method `:test`, producer
  `"journey:<id>"` (`producer/1`), subject `{"journey", "<id>/<locale>"}`, and the class of
  the environment it ran in (`environment_class/2`). It also resolves the finding an
  earlier failure in that class of environment filed.

  A failure files a finding for each control, status `:noncompliant` and severity `:high`,
  at the grain `{organization, control, "journey", "<id>/<locale>/<class>"}`, naming the
  step that failed. Production and non-production failures are separate findings, so a
  test run that passes never closes what a production run found.

  ## The environment class

  The manifest's environment (`:test`, `:staging` or `:operated`) is the run's; the
  evidence records it in `AshCompliance.Boundary`'s classes, which the freshness sweep
  reads. Only an `:operated` run in an audited deployment
  (`AshEnterprise.Security.AuditedDeployment`) is `:production`; every other run is
  `:non_production`, recorded and never counted toward freshness. A run in the seeded
  world proves the code, not that the control operates.

  Options: `:organization_id` (required: the tenant the run ran in, which the manifest
  does not record) and `:now`.
  """

  @behaviour AshJourneys.EvidenceSink

  require Logger

  alias AshCompliance.Ownership.Evidence
  alias AshJourneys.{Approval, Ir, Lock, Manifest}

  @subject_type "journey"
  @failed_gap "journey_failed"

  @doc "The producer name a journey's artifacts carry, as `docs/controls.json` spells it."
  @spec producer(String.t()) :: String.t()
  def producer(journey_id), do: "journey:" <> journey_id

  @doc "The subject type of a journey's artifacts and findings."
  def subject_type, do: @subject_type

  @doc """
  The `AshCompliance.Boundary` class of the environment a run with manifest environment
  `environment` ran in, in a deployment of `deployment_class`
  (`config :ash_enterprise, :deployment_class`).
  """
  @spec environment_class(Manifest.environment(), :audited | nil) ::
          :production | :non_production
  def environment_class(:operated, :audited), do: :production
  def environment_class(_environment, _deployment_class), do: :non_production

  @impl AshJourneys.EvidenceSink
  def record(manifest, ir, opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, manifest, bytes} <- read_back(manifest),
         {:ok, controls} <- controls(ir),
         [] <- refusals(manifest, ir) do
      class =
        environment_class(
          manifest.environment,
          Application.get_env(:ash_enterprise, :deployment_class)
        )

      run = %{
        org: organization_id,
        manifest: manifest,
        bytes: bytes,
        class: class,
        controls: controls,
        now: now
      }

      case manifest.status do
        :passed -> each_control(run, &pass/2)
        :failed -> each_control(run, &fail/2)
      end
    else
      {:error, _reason} = error -> error
      reasons when is_list(reasons) -> not_evidence(reasons)
    end
  end

  # The manifest as it reads back from its own bytes: the bytes are what is recorded, and
  # reading them applies every check of the format (an operated run with figures, an
  # unknown field, a malformed step).
  defp read_back(%Manifest{} = manifest) do
    bytes = Manifest.encode(manifest)

    case Manifest.decode(bytes) do
      {:ok, read} -> {:ok, read, bytes}
      {:error, problems} -> not_evidence(problems)
    end
  end

  defp read_back(other),
    do: not_evidence(["expected an AshJourneys.Manifest, got #{inspect(other)}"])

  defp not_evidence(reasons) do
    Logger.info("A journey run was not recorded as evidence: #{Enum.join(reasons, "; ")}")
    {:error, {:not_evidence, reasons}}
  end

  defp refusals(manifest, ir) do
    case identity(manifest, ir) do
      [] -> attempts(manifest) ++ verdict(manifest) ++ current(manifest, ir)
      mismatched -> mismatched
    end
  end

  defp identity(manifest, ir) do
    [
      manifest.journey != ir["id"] &&
        "the run is of journey #{manifest.journey}, not #{ir["id"]}",
      manifest.locale not in ir["locales"] &&
        "the journey is not declared in locale #{manifest.locale}"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp attempts(manifest) do
    flaky = for step <- manifest.steps, step.attempts > 1, do: step.name

    [
      manifest.retries > 0 &&
        "the run needed #{manifest.retries} retr#{if manifest.retries == 1, do: "y", else: "ies"}; " <>
          "only a first attempt is evidence",
      flaky != [] &&
        "step(s) #{Enum.join(flaky, ", ")} took more than one attempt (flaky); " <>
          "only a first attempt is evidence"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp verdict(%Manifest{status: :errored}),
    do: ["the run errored, so it reached no verdict"]

  defp verdict(%Manifest{status: :passed, steps: steps}) do
    case for step <- steps, step.status != :passed, do: step.name do
      [] -> []
      steps -> ["the run says passed, but step(s) #{Enum.join(steps, ", ")} did not pass"]
    end
  end

  defp verdict(%Manifest{status: :failed}), do: []

  # The journey's approved run must still prove it (`Lock.verify/6`), and this run must be
  # of the declaration and the browser build that approval is of.
  defp current(manifest, ir) do
    root = Application.app_dir(:ash_enterprise)
    journey = %{ir: ir, hash: Ir.hash(ir)}

    with {:ok, lock} <- Lock.read(root),
         {:ok, entry, _approved} <-
           Lock.verify(root, lock, ir["id"], journey, manifest.locale, texts: false) do
      [
        manifest.declaration_hash != entry.hash &&
          "the run proves declaration #{short(manifest.declaration_hash)}, but the approved " <>
            "one is #{short(entry.hash)}: the run is stale",
        manifest.version != ir["version"] &&
          "the run is of version #{manifest.version}, but the journey is at #{ir["version"]}",
        Approval.build(manifest) != entry.browser &&
          "the run is from #{Approval.describe(Approval.build(manifest))}, but the lock pins " <>
            "#{Approval.describe(entry.browser)}"
      ]
      |> Enum.filter(&is_binary/1)
    else
      {:error, _refusal, reasons} -> Enum.map(reasons, &("the approved run: " <> &1))
      {:error, problems} -> Enum.map(problems, &("the lock: " <> &1))
    end
  end

  defp controls(ir) do
    case get_in(ir, ["metadata", "controls"]) do
      [_ | _] = controls ->
        if Enum.all?(controls, &(is_binary(&1) and String.trim(&1) != "")),
          do: {:ok, controls},
          else: not_evidence(["the journey's controls are not all ids: #{inspect(controls)}"])

      _none ->
        not_evidence(["the journey names no controls in its metadata"])
    end
  end

  defp each_control(run, fun), do: all_ok(run.controls, &fun.(run, &1))

  # Applies `fun` to each item until one returns an error, which is returned.
  defp all_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp pass(run, control) do
    with {:ok, _artifact} <-
           Evidence.record(run.org, control, run.bytes,
             producer: producer(run.manifest.journey),
             media_type: "application/json",
             method: :test,
             subject_type: @subject_type,
             subject_id: "#{run.manifest.journey}/#{run.manifest.locale}",
             environment_class: run.class,
             now: run.now,
             # Trusted machinery: the run's own verdict, recorded as ChainVerifyWorker does.
             authorize?: false
           ) do
      resolve(run, control)
    end
  end

  defp fail(run, control) do
    grain = grain(run, control)

    # Trusted machinery, as ChainVerifyWorker files its finding.
    with {:ok, row} <- AshCompliance.Domain.upsert_finding_grain(grain, authorize?: false) do
      first_seen = if row.first_seen_at, do: [], else: [{:set, :first_seen_at, run.now}]

      ops =
        first_seen ++
          [
            {:set, :status, :noncompliant},
            {:set, :severity, :high},
            {:set, :gap, @failed_gap},
            {:set, :last_seen_at, run.now},
            {:set, :resolved_at, nil},
            {:set, :explanation, String.slice(failure(run), 0, 1_000)}
          ]

      apply_ops(row, ops)
    end
  end

  defp failure(%{manifest: manifest, class: class}) do
    step = Enum.find(manifest.steps, &(&1.status == :failed))
    where = if step, do: " at step #{step.name}#{if step.error, do: ": " <> step.error}", else: ""

    "Journey #{manifest.journey} (#{manifest.locale}) failed#{where} " <>
      "(run #{manifest.run_id}, commit #{manifest.commit}, #{manifest.environment} " <>
      "environment, #{class})."
  end

  # A pass closes the finding a failure in the same class of environment filed. The
  # finding keeps its status; resolved_at says when the journey passed again.
  defp resolve(run, control) do
    %{subject_id: subject_id} = grain(run, control)

    with {:ok, findings} <-
           AshCompliance.Domain.findings_for_organization(run.org, authorize?: false) do
      findings
      |> Enum.filter(
        &(&1.control_id == control and &1.subject_type == @subject_type and
            &1.subject_id == subject_id and is_nil(&1.resolved_at))
      )
      |> all_ok(
        &apply_ops(&1, [
          {:set, :resolved_at, run.now},
          {:set, :last_seen_at, run.now},
          {:set, :explanation, "The journey passed again (run #{run.manifest.run_id})."}
        ])
      )
    end
  end

  defp grain(run, control) do
    %{
      organization_id: run.org,
      control_id: control,
      subject_type: @subject_type,
      subject_id: "#{run.manifest.journey}/#{run.manifest.locale}/#{run.class}"
    }
  end

  defp apply_ops(finding, ops) do
    case AshCompliance.Domain.apply_finding_ops(finding, ops, authorize?: false) do
      {:ok, _finding} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp short(hash) when is_binary(hash), do: binary_part(hash, 0, min(12, byte_size(hash)))
end
