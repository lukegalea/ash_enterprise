defmodule AshEnterprise.Lineage.PruneWorker do
  @moduledoc """
  Deletes lineage past its retention window, once a day
  (`AshEnterprise.Lineage.Retention`; the crontab in `config/config.exs`).

  Idempotent: a second run the same day deletes nothing. Unique for an hour,
  so a tick that lands while one is still running collapses into it.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, AshEnterprise.Lineage.Retention.prune()}
  end
end
