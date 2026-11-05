defmodule AshEnterprise.Bpmn.Cursor do
  @moduledoc """
  How far the trigger sweep has read into one tenant's audit chain —
  `AshBpmn.Resources.Cursor` instantiated on the platform base.

  Bookkeeping, not a record: one row per tenant, saying nothing an auditor
  wants that `AshEnterprise.Bpmn.Dispatch` does not say better. Hence
  `ownership: :none`, no lifecycle, and — deliberately — **not audited**. Two
  logs describing the same fact will eventually disagree, and a cursor changes
  once per sweep.

  The `NULL`-tenant chain has no ordering guarantee at all (`AshEnterprise.Audit.EventSource`
  declares it `:best_effort`) and cannot get a cursor row here even in
  principle: the platform base keeps `organization_id` `allow_nil? false`,
  which is the tenancy invariant every resource in the application shares and
  which a NULL-tenant baseline row would weaken for all of them to serve one.
  The engine's per-tenant sweep fan-out (`AshEnterprise.Bpmn.Subscription.trigger_tenants/0`)
  enumerates real organizations only, so the chain is never swept — which is
  the honest treatment for a chain with nothing to promise.
  """

  use AshBpmn.Resources.Cursor,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_cursors",
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :none,
      lifecycle?: false,
      audit?: false,
      archival?: false
    ]

  # With `:base` set the macro leaves tenancy — and therefore the one-per-tenant
  # identity — to the host, so this is declared here rather than inherited. It is
  # what makes the sweep's create-at-high-water an upsert rather than a
  # duplication risk, and what a concurrent publish's cursor stamp collides with
  # instead of doubling.
  identities do
    identity :one_per_tenant, [:organization_id] do
      all_tenants? true
    end
  end

  alias AshEnterprise.Platform.SystemActor

  @doc """
  Establishes `tenant`'s cursor at the current high-water mark of its audit chain, when it
  has none; an existing cursor is left exactly where it is.

  Creating a cursor at zero would be the obvious thing and is badly wrong: the sweep would
  walk the tenant's entire history and start a process for every matching event that ever
  happened. The sweep's own fresh cursor starts at the newest event too, which skips every
  event between a first waiter or subscription and the first sweep. So whatever first makes
  a tenant interested in events (a subscription going live, a process instance starting)
  stamps the mark as of that moment.

  Read first, create only when absent: an upsert's conflict clause is a write, and one written
  carelessly re-stamps the mark every time, silently skipping everything in between. The
  one-per-tenant unique index is the race arbiter: two concurrent first writers cannot
  double-create, and the loser fails loudly rather than resetting anything.
  """
  @spec ensure!(Ash.UUID.t()) :: :ok
  def ensure!(tenant) do
    unless exists?(tenant) do
      create!(%{last_sequence: high_water(tenant)}, actor: SystemActor.process(), tenant: tenant)
    end

    :ok
  end

  defp exists?(tenant) do
    __MODULE__
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
    |> is_nil()
    |> Kernel.not()
  end

  defp high_water(tenant) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      [%{sequence: sequence}] -> sequence
      [] -> 0
    end
  end
end
