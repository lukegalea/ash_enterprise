defmodule AshEnterprise.Audit.ArchivedEvent do
  @moduledoc """
  Audit events that have left the hot log: the archive store of ADR 0024's age half.

  `AshEnterprise.Audit.Retention.archive/1` copies each tenant chain's leading run of events
  older than the hot window (ninety days) here, verifies the copy, and only then deletes the
  hot rows. The columns are `audit_events`' own, byte for byte, plus `archived_at`, so a
  copied row still hashes to its `hash` and `AshEnterprise.Audit.Chain` verifies hot and
  archived rows as one chain.

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
  in `AshEnterprise.Audit.Retention`, which the database checks against the hot row.

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

  postgres do
    table "audit_event_archive"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:organization_id, :sequence], name: "audit_event_archive_chain_index"
    end

    # One command per statement (see `AshEnterprise.Audit.EventLog`): Ecto sends each as a
    # prepared statement, which takes one command.
    custom_statements do
      statement :audit_event_archive_guard_function do
        up """
        CREATE OR REPLACE FUNCTION ash_enterprise_audit_archive_guard() RETURNS trigger AS $fn$
        BEGIN
          IF TG_OP = 'DELETE' AND OLD.occurred_at < now() - interval '400 days' THEN
            RETURN OLD;
          END IF;

          RAISE EXCEPTION 'audit_event_archive keeps every event for 400 days; % is not permitted', TG_OP
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Archived events are never edited, and are purged only after 400 days.';
        END;
        $fn$ LANGUAGE plpgsql;
        """

        # Not CASCADE, so a change to this function alone fails its migration rather than
        # silently taking the trigger with it; change the trigger statement with it.
        down "DROP FUNCTION IF EXISTS ash_enterprise_audit_archive_guard();"
      end

      statement :audit_event_archive_guard_trigger do
        up """
        CREATE OR REPLACE TRIGGER audit_event_archive_guard
          BEFORE UPDATE OR DELETE ON audit_event_archive
          FOR EACH ROW EXECUTE FUNCTION ash_enterprise_audit_archive_guard();
        """

        down "DROP TRIGGER IF EXISTS audit_event_archive_guard ON audit_event_archive;"
      end
    end
  end

  actions do
    defaults [:read]
    default_accept []

    read :chain do
      description "One tenant's archived chain in order."

      argument :organization_id, :uuid, allow_nil?: true

      prepare build(sort: [sequence: :asc])

      filter expr(
               organization_id == ^arg(:organization_id) or
                 (is_nil(^arg(:organization_id)) and is_nil(organization_id))
             )
    end
  end

  # As `AshEnterprise.Audit.EventLog`: reading the archive is reading the audit log.
  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end

  attributes do
    # The primary key is the hot row's id, copied, not generated: a second copy of one
    # event conflicts rather than landing beside it.
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      writable? false
      public? true
    end

    attribute :sequence, :integer do
      allow_nil? false
      writable? false
      public? false
      description "The event's position in its tenant chain, as it was in the hot log."
    end

    attribute :organization_id, :uuid do
      writable? false
      public? false
    end

    attribute :record_id, :uuid, allow_nil?: false, writable?: false, public?: true
    attribute :version, :integer, allow_nil?: false, writable?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, writable?: false, public?: true
    attribute :resource, :string, allow_nil?: false, writable?: false, public?: true
    attribute :action, :string, allow_nil?: false, writable?: false, public?: true
    attribute :action_type, :string, allow_nil?: false, writable?: false, public?: true
    attribute :user_id, :uuid, writable?: false, public?: true
    attribute :data, :map, allow_nil?: false, writable?: false, public?: false
    attribute :changed_attributes, :map, allow_nil?: false, writable?: false, public?: false
    attribute :metadata, :map, allow_nil?: false, writable?: false, public?: false
    attribute :previous_hash, :string, writable?: false, public?: false
    attribute :hash, :string, writable?: false, public?: false

    attribute :archived_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      public? true
      description "When the retention run copied this event out of the hot log."
    end
  end
end
