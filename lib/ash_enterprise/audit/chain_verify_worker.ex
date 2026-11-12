defmodule AshEnterprise.Audit.ChainVerifyWorker do
  @moduledoc """
  Verifies every audit chain once a day and stores the result as evidence
  (`config/config.exs` crontab).

  For each tenant chain it runs `AshEnterprise.Audit.Chain.verify/1` (hot and archived rows
  together) and records the result with `AshCompliance.Ownership.Evidence.record/4` as an
  artifact for each criterion the verification evidences (`evidence_controls/0`): a JSON
  summary of how many events were checked and every finding. The artifact is recorded
  whatever the verification found. A break found is the control operating; it is not a
  reason to leave no trace that it ran. The chain with no tenant is verified too, but an
  artifact belongs to an organization, so its result is only in the job's return value.

  The freshness sweep (`AshEnterprise.Compliance.FreshnessSweepWorker`) then reads these
  artifacts: a day without one shows the criterion as unknown, with its finding.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  alias AshCompliance.Ownership.Evidence
  alias AshEnterprise.Audit.Chain
  alias AshEnterprise.Platform.SystemActor

  @producer "module:#{inspect(__MODULE__)}"

  @doc """
  The SOC 2 criteria this module records evidence for (the chain verification).

  Read by `AshCompliance.Ownership.Resolver.proves_producer/2`; `docs/controls.json`
  rows that name this module as their evidence producer must appear here.
  """
  def evidence_controls, do: ["CC4.1", "CC7.2"]

  @doc "The producer name every artifact carries, as `docs/controls.json` spells it."
  def producer, do: @producer

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    results =
      for result <- Chain.verify_all() do
        {result.organization_id, length(result.findings), record(result, now)}
      end

    case for({org, _, {:error, error}} <- results, do: {org, error}) do
      [] -> {:ok, Enum.map(results, fn {org, findings, _} -> {org, findings} end)}
      errors -> {:error, errors}
    end
  end

  @doc """
  Records one chain's verification result as evidence for each criterion. Options: `:now`.
  Returns `:skipped` for the chain with no tenant.
  """
  @spec record(Chain.result(), DateTime.t()) :: :ok | :skipped | {:error, term()}
  def record(%{organization_id: nil}, _now), do: :skipped

  def record(%{organization_id: org} = result, now) do
    content = summary(result, now)

    Enum.reduce_while(evidence_controls(), :ok, fn control, :ok ->
      case Evidence.record(org, control, content,
             producer: @producer,
             media_type: "application/json",
             method: :test,
             subject_type: "audit_chain",
             subject_id: org,
             now: now,
             actor: SystemActor.oban(),
             authorize?: false
           ) do
        {:ok, _artifact} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp summary(result, now) do
    Jason.encode!(%{
      "verified_at" => DateTime.to_iso8601(now),
      "chain" => result.organization_id,
      "checked" => result.checked,
      "skipped_unchained_prefix" => result.skipped_unchained_prefix,
      "anchored_after" => result.anchored_after,
      "findings" =>
        Enum.map(result.findings, fn finding ->
          %{
            "sequence" => finding.sequence,
            "id" => finding.id,
            "occurred_at" => DateTime.to_iso8601(finding.occurred_at),
            "problem" => Atom.to_string(finding.problem)
          }
        end)
    })
  end
end
