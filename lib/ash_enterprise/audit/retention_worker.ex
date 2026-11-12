defmodule AshEnterprise.Audit.RetentionWorker do
  @moduledoc """
  Runs the retention policy once a day (`AshEnterprise.Audit.Retention`; the crontab in
  `config/config.exs`): archive what is past the ninety-day hot window, then purge from the
  archive what is past `purge_after_days`, which is never unless a deployment configures it.

  Idempotent: a second run the same day finds nothing to move. A move that does not verify
  deletes nothing and is recorded as a failed `AshEnterprise.Audit.ArchiveRun`; the job still
  succeeds, because retrying an archive that refused would refuse again, and the failed run is
  the record someone reads.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  alias AshEnterprise.Audit.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with {:ok, archived} <- Retention.archive(),
         {:ok, purged} <- Retention.purge() do
      {:ok, %{archived: summary(archived), purged: summary(purged)}}
    end
  end

  defp summary(:disabled), do: :disabled

  defp summary(%{audit: audit, evidence: evidence}),
    do: Enum.frequencies_by([evidence | audit], &step/1)

  defp step({kind, _run}), do: kind
  defp step(kind), do: kind
end
