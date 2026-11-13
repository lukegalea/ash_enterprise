defmodule AshEnterprise.Audit.ArchivedEvent do
  @moduledoc """
  Audit events that have left the hot log: the archive store of ADR 0024's age half.

  `AshEvents.Chain.Retention.archive/2` (run by `AshEnterprise.Audit.Retention`) copies each
  tenant chain's leading run of events older than the hot window (ninety days) here, verifies
  the copy, and only then deletes the hot rows. The table, its columns, its guard trigger and
  its read actions are `ash_events_chain`'s archive (`{:archive, ...}`): the columns are
  `audit_events`' chained ones with their types, plus `archived_at`, so a copied row still
  hashes to its `hash` and `AshEvents.Chain.verify/2` verifies hot and archived rows as one
  chain. This module adds who may read it and the tenancy.

  ## Where it lives, and what it is not

  A table in the same database, not a detached partition: ADR 0024 accepted monthly
  partitions, but no partition was ever created, so there was nothing to detach. Moving
  rows here takes them out of the hot table and its indexes, which every audited write
  touches. It does not make the database smaller. A deployment that wants the archive on
  cheaper storage moves this table to another tablespace, or dumps it; both keep it
  verifiable, because verification needs only the rows.

  ## Why it is not a platform resource

  For the reason `AshEnterprise.Audit.EventLog` is not: it is the log, moved. Auditing a
  write here would put a second copy of every archived event back into the log it left.
  It has no create, update or destroy action. Rows arrive only through the set-based copy
  in `AshEvents.Chain.Retention`, which the database checks against the hot row.

  ## The database holds the two numbers

  * **Nothing archived is updated.** The trigger refuses every `UPDATE`.
  * **Nothing younger than four hundred days is deleted.** The trigger refuses a `DELETE`
    of a row whose `occurred_at` is less than four hundred days old, whoever asks. A
    deployment can keep rows longer (`AshEnterprise.Audit.Retention` purges only when
    configured to); it cannot keep them for less.

  And on the hot side, `audit_events`' own trigger refuses a `DELETE` unless an identical
  copy of the row is already here and the row is older than ninety days
  (`AshEnterprise.Audit.EventLog`).
  """

  use Ash.Resource,
    domain: AshEnterprise.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # The table `audit_event_archive`, its chain index, its guard statements (under the guard
  # function's name the table has always had), its attributes and its `:read` and `:chain`
  # actions.
  use AshEvents.Chain.Resources,
      {:archive,
       log: AshEnterprise.Audit.EventLog,
       table: "audit_event_archive",
       repo: AshEnterprise.Repo,
       guard_function: "ash_enterprise_audit_archive_guard"}

  # The archive's half of `AshEnterprise.Audit.Export`, beside the hot log's own `:for_export`.
  actions do
    read :for_export do
      description """
      The archived half of the evidence an auditor asks for (`AshEnterprise.Audit.Export`):
      what happened in a window and has left the hot log, in chain order.
      """

      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false

      prepare build(sort: [sequence: :asc])
      pagination keyset?: true, required?: false

      filter expr(occurred_at >= ^arg(:from) and occurred_at < ^arg(:to))
    end
  end

  # Reading the archive is reading the audit log, so the grant that reaches it is the one on
  # `AshEnterprise.Audit.EventLog`: an auditor who may read the log reads all of it, and a
  # second privilege would let an export silently stop at ninety days.
  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if {AshEnterprise.Security.Checks.RoleGrant, as: AshEnterprise.Audit.EventLog}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end
end
