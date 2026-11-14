defmodule AshEnterprise.Audit.ChainVerifyWorker do
  @moduledoc """
  Verifies every audit chain once a day and stores the result as evidence
  (`config/config.exs` crontab).

  For each tenant chain it runs `AshEvents.Chain.verify/2` (hot and archived rows
  together) and records the result with `AshCompliance.Ownership.Evidence.record/4` as an
  artifact for each criterion the verification evidences (`evidence_controls/0`): a JSON
  summary of how many events were checked and every finding. The artifact is recorded
  whatever the verification found. A break found is the control operating; it is not a
  reason to leave no trace that it ran. The chain with no tenant is verified too, but an
  artifact belongs to an organization, so its result is only in the job's return value.

  **One chain that cannot be verified does not stop the others.** A verification that
  raises (the chain could not be read) records no evidence for that tenant: it files a
  finding for each criterion instead, status `:error`, at the grain
  `{organization, criterion, "audit_chain", organization}`, and every other chain is still
  verified and recorded. The next clean verification of that chain resolves the finding.
  The job succeeds either way: the finding is the record someone reads, and a retry the same
  hour would duplicate the healthy tenants' evidence.

  The freshness sweep (`AshEnterprise.Compliance.FreshnessSweepWorker`) then reads these
  artifacts: a day without one shows the criterion as unknown, with its finding.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias AshCompliance.Ownership.Evidence
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.SystemActor

  @producer "module:#{inspect(__MODULE__)}"
  @subject_type "audit_chain"
  @gap "audit_chain_verification"

  @doc """
  The SOC 2 criteria this module records evidence for (the chain verification).

  Read by `AshCompliance.Ownership.Resolver.proves_producer/2`; `docs/controls.json`
  rows that name this module as their evidence producer must appear here.
  """
  def evidence_controls, do: ["CC4.1", "CC7.2"]

  @doc "The producer name every artifact carries, as `docs/controls.json` spells it."
  def producer, do: @producer

  @doc "The subject type of the finding a chain that could not be verified files."
  def subject_type, do: @subject_type

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  @doc """
  Verifies every chain and records each result.

  Returns `{:ok, [{tenant, findings}]}`, where `findings` is the number of findings, or
  `{:error, message}` for a chain whose verification raised (recorded as a finding), or
  `{:error, errors}` when recording failed. Options: `:now`, and `:verifier`, the function
  that verifies one chain (default `AshEvents.Chain.verify/2`).
  """
  @spec run(keyword()) :: {:ok, [{term(), term()}]} | {:error, term()}
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    verify_opts = [on_error: :return] ++ Keyword.take(opts, [:verifier])

    results =
      for result <- AshEvents.Chain.verify_all(EventLog, verify_opts) do
        {result.partition, outcome(result), record(result, now)}
      end

    case for({org, _, {:error, error}} <- results, do: {org, error}) do
      [] -> {:ok, Enum.map(results, fn {org, outcome, _} -> {org, outcome} end)}
      errors -> {:error, errors}
    end
  end

  defp outcome(%{error: message}), do: {:error, message}
  defp outcome(result), do: length(result.findings)

  @doc """
  Records one chain's verification result: evidence for each criterion, or, for a
  verification that raised, a finding for each criterion. Returns `:skipped` for the chain
  with no tenant.
  """
  @spec record(AshEvents.Chain.result(), DateTime.t()) :: :ok | :skipped | {:error, term()}
  def record(%{partition: nil} = result, _now) do
    if error = result[:error] do
      Logger.error("The audit chain with no tenant could not be verified: #{error}")
    end

    :skipped
  end

  def record(%{partition: org, error: error}, now) do
    Logger.error("The audit chain of #{org} could not be verified: #{error}")

    each_control(fn control ->
      file_unverified(org, control, "The chain could not be verified: #{error}", now)
    end)
  end

  def record(%{partition: org} = result, now) do
    content = summary(result, now)

    with :ok <- record_evidence(org, content, now) do
      resolve_unverified(org, now)
    end
  end

  defp record_evidence(org, content, now) do
    each_control(fn control ->
      case Evidence.record(org, control, content,
             producer: @producer,
             media_type: "application/json",
             method: :test,
             subject_type: @subject_type,
             subject_id: org,
             now: now,
             actor: SystemActor.oban(),
             authorize?: false
           ) do
        {:ok, _artifact} -> :ok
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp each_control(fun) do
    Enum.reduce_while(evidence_controls(), :ok, fn control, :ok ->
      case fun.(control) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp file_unverified(org, control, explanation, now) do
    grain = %{
      organization_id: org,
      control_id: control,
      subject_type: @subject_type,
      subject_id: org
    }

    with {:ok, row} <- AshCompliance.Domain.upsert_finding_grain(grain, authorize?: false) do
      first_seen = if row.first_seen_at, do: [], else: [{:set, :first_seen_at, now}]

      ops =
        first_seen ++
          [
            {:set, :status, :error},
            {:set, :severity, :high},
            {:set, :gap, @gap},
            {:set, :last_seen_at, now},
            {:set, :resolved_at, nil},
            {:set, :explanation, String.slice(explanation, 0, 1_000)}
          ]

      case AshCompliance.Domain.apply_finding_ops(row, ops, authorize?: false) do
        {:ok, _finding} -> :ok
        error -> error
      end
    end
  end

  # A clean read of the chain again closes the finding an earlier failure opened. The
  # finding keeps its status; resolved_at says when the chain was read again.
  defp resolve_unverified(org, now) do
    with {:ok, findings} <-
           AshCompliance.Domain.findings_for_organization(org, authorize?: false) do
      findings
      |> Enum.filter(&(&1.subject_type == @subject_type and is_nil(&1.resolved_at)))
      |> Enum.reduce_while(:ok, &resolve_finding(&1, &2, now))
    end
  end

  defp resolve_finding(finding, :ok, now) do
    ops = [
      {:set, :resolved_at, now},
      {:set, :last_seen_at, now},
      {:set, :explanation, "The chain was verified again."}
    ]

    case AshCompliance.Domain.apply_finding_ops(finding, ops, authorize?: false) do
      {:ok, _finding} -> {:cont, :ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp summary(result, now) do
    Jason.encode!(%{
      "verified_at" => DateTime.to_iso8601(now),
      "chain" => result.partition,
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
