defmodule AshEnterprise.Process.Triggers.Notifier do
  @moduledoc """
  Nudges the trigger sweep when an audited write lands on a resource some trigger cares about.

  ## It is a nudge, and it must never be more than that

  Ash defers notifications until the transaction is over, so this runs **after** the write has
  committed. That is good — it means the notifier cannot extend the per-tenant advisory lock
  that `AshEvents` holds, and cannot make other audited writes queue behind it.

  It also means **enqueuing here is not transactional with the write**. A crash between
  `COMMIT` and `Oban.insert/2` loses the nudge, silently and undetectably.

  That is survivable only because the nudge is not how dispatch completes: the cron-driven
  sweep walks the cursor and reaches the same events regardless. Losing a nudge costs latency;
  it cannot cost a process. If anyone ever removes the cron sweep and relies on this, the
  system acquires a silent failure mode — which is why it is stated here and not only in the
  plan.

  ## Debounced

  The insert is `unique` over a five-second window per tenant, so a burst of writes produces
  one sweep rather than one job each.
  """

  use Ash.Notifier

  require Logger

  alias AshEnterprise.Process.Triggers.{Index, SweepWorker}

  @impl true
  def notify(%Ash.Notifier.Notification{data: event}) do
    resource = Map.get(event, :resource)
    tenant = Map.get(event, :organization_id)

    if is_binary(resource) and Index.interested?(resource) do
      enqueue(tenant)
    end

    :ok
  rescue
    e ->
      # A notifier that raises must not fail the write it is notifying about. The write has
      # already committed; the worst case here is a missed nudge, which the sweep covers.
      Logger.warning("trigger notifier failed: #{Exception.message(e)}")
      :ok
  end

  def notify(_other), do: :ok

  defp enqueue(tenant) do
    %{"tenant" => tenant}
    |> SweepWorker.new(unique: [period: 5, keys: [:tenant], states: [:available, :scheduled]])
    |> Oban.insert()
  end
end
