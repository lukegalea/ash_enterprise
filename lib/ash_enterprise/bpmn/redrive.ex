defmodule AshEnterprise.Bpmn.Redrive do
  @moduledoc """
  A person driving a failed trigger dispatch again: one row per failed dispatch re-driven,
  saying who asked, under which subscription version, and what came of it —
  `AshBpmn.Resources.Redrive` instantiated on the platform base.

  The sweep records a dispatch it could not make as a `:failed` row and moves on
  (`AshEnterprise.Bpmn.Dispatch`); nothing retries it by itself. `redrive_failed` takes a
  range of a tenant's log (by event sequence or by when the events happened), finds the
  failed dispatches in it, and re-drives each through `record`, which runs the funnel again
  for that one event under the subscription version on its row. The package does the
  driving (`AshBpmn.Triggers.Redrive`): a disabled version is `:not_started`, an event
  already started is `:already_started`, and nothing starts twice.

  ## A standing grant is checked now

  A `:standing_grant` version's steps run for its publisher, on the grant publishing it
  wrote (ADR 0069). That grant is re-checked at the re-drive, as it is at every step, by the
  `authority:` callback (`AshEnterprise.Bpmn.Subscription.Authority.holds_now/2`): a grant
  revoked or lapsed since the failure, or a publisher who has left or been deactivated,
  records `:no_authority` with the reason and starts nothing. Re-driving never borrows the
  authority the version had when the event happened.

  ## A person's act

  The person is the row's `created_by_id`, as for every platform record, so the package's
  own `redriven_by_id` is off.

  `record` and `redrive_failed` are `human_only` and `changes_authority`: no system actor,
  no engine and no automation principal reaches them, because a re-drive starts processes
  that may run under a publisher's standing grant. The person needs what publishing that
  tenant's recipes needs, a global `write` on `AshEnterprise.Bpmn.Subscription`
  (`AshEnterprise.Security.Checks.ManagesRecipes`), or a grant on this resource itself.

  Audited: re-driving changes what runs, so it is in the trail an auditor reads, beside the
  dispatch rows it produced.
  """

  use AshBpmn.Resources.Redrive,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_redrives",
    # The platform base records the creator.
    redriven_by?: false,
    authority: {AshEnterprise.Bpmn.Subscription.Authority, :holds_now, []},
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      # A record of an act, never edited or deleted.
      archival?: false,
      human_only: [:record, :redrive_failed],
      changes_authority: [:record, :redrive_failed],
      extra_grants: [AshEnterprise.Security.Checks.ManagesRecipes]
    ]
end
