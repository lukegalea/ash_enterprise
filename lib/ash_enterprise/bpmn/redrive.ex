defmodule AshEnterprise.Bpmn.Redrive do
  @moduledoc """
  A person driving a failed trigger dispatch again: one row per failed dispatch re-driven,
  saying who asked, under which subscription version, and what came of it.

  The sweep records a dispatch it could not make as a `:failed` row and moves on
  (`AshEnterprise.Bpmn.Dispatch`); nothing retries it by itself. `redrive_failed` takes a
  range of a tenant's log (by event sequence or by when the events happened), finds the
  failed dispatches in it, and re-drives each through `record`, which runs the funnel again
  for that one event (`AshBpmn.Triggers.Correlator.dispatch_event/4` with `redrive: true`).

  ## Under the version on the row

  A failed dispatch names the subscription version that failed, and that is the version
  driven again, whatever has been published since: a superseded version keeps the events
  up to its `retired_sequence`, and the funnel offers the event to no other. A version that
  is now disabled is not driven (`:not_started`, reason `disabled`): the switch is the
  operator's answer to "stop starting this".

  ## A standing grant is checked now

  A `:standing_grant` version's steps run for its publisher, on the grant publishing it
  wrote (ADR 0069). That grant is re-checked at the re-drive, as it is at every step
  (`AshEnterprise.Execution.Identity.recipe_requester/3`): a grant revoked or lapsed since
  the failure, or a publisher who has left or been deactivated, records `:no_authority` with
  the reason and starts nothing. Re-driving never borrows the authority the version had
  when the event happened.

  ## Starts once

  A re-drive does not count the `:failed` row as the record, and every other row still is,
  so a failure can become a start but never a second one (the dispatch identity excludes
  failed rows, not started ones). An event already started under the version records
  `:already_started` and runs nothing.

  ## A person's act

  The person is the row's `created_by_id`, as for every platform record.

  `record` and `redrive_failed` are `human_only` and `changes_authority`: no system actor,
  no engine and no automation principal reaches them, because a re-drive starts processes
  that may run under a publisher's standing grant. The person needs what publishing that
  tenant's recipes needs, a global `write` on `AshEnterprise.Bpmn.Subscription`
  (`AshEnterprise.Security.Checks.ManagesRecipes`), or a grant on this resource itself.

  Audited: re-driving changes what runs, so it is in the trail an auditor reads, beside the
  dispatch rows it produced.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Bpmn,
    ownership: :organization_owned,
    lifecycle?: false,
    # A record of an act, never edited or deleted.
    archival?: false,
    human_only: [:record, :redrive_failed],
    changes_authority: [:record, :redrive_failed],
    extra_grants: [AshEnterprise.Security.Checks.ManagesRecipes]

  postgres do
    table "bpmn_redrives"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :failed_dispatch_id, :uuid do
      allow_nil? false
      public? true
      description "The failed dispatch driven again."
    end

    attribute :subscription_id, :uuid do
      public? true
      description "The subscription version the failed dispatch names, and the re-drive used."
    end

    attribute :event_id, :uuid do
      public? true
      description "The audit event driven again."
    end

    attribute :event_sequence, :integer do
      public? true
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:started, :already_started, :not_started, :no_authority]
      description "What the re-drive did."
    end

    attribute :reason, :string do
      public? true

      description "Why nothing started: the dispatch's reason, the version's switch, or why " <>
                    "its standing grant no longer holds. Nil when it started."
    end

    attribute :dispatch_id, :uuid do
      public? true
      description "The dispatch that started the process, when one did or already had."
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "Drive one failed dispatch again, under the subscription version it names."
      accept [:failed_dispatch_id]
      change {AshEnterprise.Bpmn.Redrive.Changes.Drive, []}
    end

    action :redrive_failed, {:array, :struct} do
      description "Drive again every failed dispatch whose event lies in a range of the " <>
                    "tenant's log, each under the version on its row."

      constraints items: [instance_of: __MODULE__]

      argument :from_sequence, :integer, description: "First event sequence, inclusive."
      argument :to_sequence, :integer, description: "Last event sequence, inclusive."

      argument :since, :utc_datetime_usec,
        description: "Events that happened at or after this instant."

      argument :until, :utc_datetime_usec,
        description: "Events that happened before this instant."

      run AshEnterprise.Bpmn.Redrive.Actions.RedriveFailed
    end
  end

  code_interface do
    define :record, args: [:failed_dispatch_id]
    define :redrive_failed
  end
end
