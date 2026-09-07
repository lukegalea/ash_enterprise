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
end
