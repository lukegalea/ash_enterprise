defmodule AshEnterprise.Process.Triggers.CronSweep do
  @moduledoc """
  Fans the trigger sweep out to one job per tenant, every minute.

  A separate worker from `AshEnterprise.Process.Triggers.SweepWorker` because the cron entry
  has to be a single job and the sweep has to be per tenant: the ordering guarantee the cursor
  relies on holds *within* a tenant and nowhere else, so a single job walking every tenant's
  events would be a global cursor, which the design refuses
  (`docs/plans/event-triggered-processes.md` §2).
  """

  use Oban.Worker, queue: :bpmn, max_attempts: 1

  @impl Oban.Worker
  def perform(_job), do: AshEnterprise.Process.Triggers.SweepWorker.enqueue_all()
end
