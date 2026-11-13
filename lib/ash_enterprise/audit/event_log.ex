defmodule AshEnterprise.Audit.EventLog do
  @moduledoc """
  The central audit trail. Every create, update and destroy on every platform
  resource lands here.

  This is the default audit layer for the whole application — see ADR 0002 for
  why a single central log beats per-resource version tables here, and
  `docs/manifesto/04-batteries-are-inherited.md` for how resources get wired to
  it without asking.

  ## Shape

  Modelled on the Dataverse `audit` entity, which is the same problem solved
  once already:

  | Dataverse | Here | Provided by |
  |---|---|---|
  | `operation` | `action_type` | AshEvents |
  | `objecttypecode` | `resource` | AshEvents |
  | `objectid` | `record_id` | AshEvents |
  | `userid` | `user_id` | `persist_actor_primary_key` |
  | `callinguserid` | `system_actor` | `persist_actor_primary_key` |
  | `changedata` | `data` / `changed_attributes` | AshEvents |
  | `transactionid` | `metadata["correlation_id"]` | `AshEnterprise.Platform.ActorContext` |

  ## Why UUIDv7 primary keys

  An audit log is written constantly and read in time order. UUIDv7 is
  time-ordered, so inserts stay at the right-hand edge of the index instead of
  scattering across it the way UUIDv4 does, and "the last hour of events" is a
  range scan.

  ## This resource is deliberately not a platform resource

  It cannot be: auditing the audit log recurses. It is also not owned by anyone,
  never soft-deleted, and must be append-only. That makes it the clearest case
  of a structural rather than preferential opt-out.

  ## Sensitive values are never recorded

  Every event passes through `AshEnterprise.Audit.Changes.RedactSensitive`
  before it is inserted: a `sensitive?` attribute or argument of the source
  resource is written as `nil` in `data`, `changed_attributes` and `metadata`,
  keeping its key. ash_events does this for `data` itself but not for
  `changed_attributes`, which is how `User.hashed_password` reached this table
  until 2026-10-14. The one exception is `ash_cloak`'s `encrypted_*`
  ciphertext, kept on purpose (see Retention below). Rows written before the
  fix are listed in `docs/runbooks/audit-sensitive-values.md`.

  ## Integrity: the chain, and the trigger

  "Append-only" was a property of the *application* here: this resource offers
  only `:read`, so nothing in Elixir could rewrite history. That is not the claim
  an auditor is asking about. They are asking whether history can be rewritten at
  all, and anyone holding a `psql` connection could.

  Two mechanisms now, doing different jobs:

  **The trigger prevents.** `UPDATE` and `DELETE` on this table raise. It is the
  cheap, total answer for everything short of an attacker with `ALTER TABLE`.

  **The chain detects.** Every row carries the SHA-256 of its own contents
  concatenated with the previous row's hash, so altering any row invalidates
  every row after it, and removing one breaks the link across the gap.
  `mix ash_enterprise.audit.verify` walks the chain (`AshEvents.Chain.verify/2`) and
  reports every break by sequence number. Dropping the trigger to make an edit
  therefore does not help: the edit is still detectable, which is the point of doing both.

  ### One chain per tenant, and why that is not a compromise

  The obvious design is a single global chain, and it would cost something real:
  every audited write in the system would have to serialize against every other,
  across all tenants.

  It would also be *redundant*, because AshEvents already takes
  `pg_advisory_xact_lock` on every audited action, before it inserts the event.
  The key is the chain the event joins (`AshEvents.Chain.LockKeyGenerator`): the
  `organization_id` in its metadata, which is what the trigger partitions on. The
  serialization a chain needs is therefore already held — per chain. Chaining
  per tenant adds no contention that was not already there, and chaining globally
  would add a great deal.

  The key is read from the metadata, not from the tenant of the resource being
  written, because the two can disagree: a resource that is not tenant-scoped can
  still be written under a tenant, and its event joins that tenant's chain. Keyed on
  the resource's tenancy (`AshEvents.AdvisoryLockKeyGenerator.Default`), such a write
  would hold the shared default key while appending to the tenant's chain, and could
  race that chain's tail.

  It is also the better artefact. A customer can verify their own chain without
  being shown anyone else's, which is exactly what "can I audit my own trail" has
  to mean in a multi-tenant system.

  Events with no tenant — registration before an organization exists, system
  actors operating outside one — form their own chain, keyed on `NULL`. A write
  given its tenant only when it runs (`Ash.create!(changeset, tenant: tenant)`) is
  not one of them: `StampCorrelation` stamps the tenant again as the action runs.

  ## Something depends on that lock which is not the chain

  The advisory lock above is taken by `AshEvents` for its own reasons, and the hash
  chain merely piggybacks on it. **A second consumer now depends on it too**, and on
  a stronger property than the chain needs, so it is recorded here rather than only
  where it is used.

  Because the lock is taken *before* the event row is inserted and is
  `xact`-scoped, a second transaction for the same chain cannot consume
  `nextval()` until the first has committed. So **within one tenant's chain,
  `sequence` order is commit order** — which is what makes `sequence` usable as a
  change-feed cursor at all. A plain `bigserial` is otherwise the canonical wrong
  thing to build a feed on: values are assigned at INSERT, so two transactions can
  take 100 and 101 and commit in the other order, and a consumer holding a
  high-water mark loses 100 permanently and silently.

  Three limits on that, each of which someone will otherwise assume away:

    * **It is per chain.** The key generator returns a two-element list for a
      tenant's chain and the log's single default integer for the `NULL` chain, so
      the two call `pg_advisory_xact_lock($1, $2)` and `pg_advisory_xact_lock($1)`.
      Postgres treats those as **separate lock spaces** — measured: holding `(0, 0)`,
      a `(0)` acquires in about a millisecond. The `NULL` chain therefore orders
      nothing against a tenant's chain, and a consumer must give it its own cursor
      (`AshEnterprise.Audit.EventSource` declares it best-effort).
    * **It depends on there being an enclosing transaction**, which is not obvious
      given `AshEnterprise.Repo` sets `prefer_transaction? false`. There is: an
      audited create traces as `begin / INSERT <resource> / pg_advisory_xact_lock /
      INSERT audit_events / commit`.
    * **It is `ash_events`' implementation, not our schema.** Another
      `advisory_lock_key_generator`, a key that stops matching the chain an event
      joins, or an upstream change to when the lock is taken, invalidates all of the
      above — and would do so silently, because the failure is a consumer skipping an
      event rather than an error. `AshEnterprise.Mdm.Refold` also relies on a tenant's
      key being the one `AshEvents.AdvisoryLockKeyGenerator.Default` gives it
      (`test/ash_enterprise/durability/mdm_refold_lock_order_test.exs`).

  `docs/plans/event-triggered-processes.md` §2 has the measurements and the design
  that rests on them.

  ## Retention

  Ninety days hot, then archived; never purged before four hundred days
  (`AshEvents.Chain.Retention`, run by `AshEnterprise.Audit.Retention`; ADR 0024's age
  half). An event older than ninety days is copied to `AshEnterprise.Audit.ArchivedEvent`,
  the copy is verified, and only then is the hot row deleted. The immutability trigger below allows that delete and no other: the
  row must be past ninety days and an identical copy must already be archived. The tail
  of every chain stays hot, so the chain trigger always finds the row to link to. Nothing
  is partitioned: ADR 0024 accepted monthly partitions, but none was ever created.

  Erasure does not delete from this log, and must not. Content from an external
  connection reaches it only as ciphertext sealed under that connection's
  erasure-scope key (`changed_attributes` → `encrypted_*`; the plaintext argument
  is sensitive and recorded as `nil` in `data`). Destroying the key
  (`AshEnterprise.Erasure.shred_scope/4`) makes that content unreadable here
  without changing a row, so the chain verifies unchanged. That holds only
  while no audited resource *stores a derived plaintext copy*: ash_events
  records every changed attribute that was not an input, so a value computed
  from sealed content and force-set on an audited row lands here in plaintext
  and outside any key. Derive on read instead (`MorningBrief.draft_text`), or
  mark the attribute `sensitive?` so it is recorded as `nil`
  (`Canonical.Person.name`/`email`). The erasure test sweeps the whole log for
  fixture content after a shred. This log is
  deliberately **not** `cloak_vault`-encrypted: one vault key for every event
  could not be shredded per scope. See ADR 0024's implementation note and
  `docs/runbooks/crypto-shredding.md`.
  """

  use Ash.Resource,
    domain: AshEnterprise.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog, AshEvents.Chain.Extension],
    # The bpmn trigger engine's nudge. It runs *after* the transaction -- Ash defers
    # notifications -- so it cannot extend the per-tenant advisory lock this chain relies on.
    # It also cannot be transactional with the write, which is why it only nudges and the
    # cron-driven sweep (`AshBpmn.Triggers.SweepWorker`, wired in the Oban crontab) is what
    # makes dispatch complete. The adapter over this log is
    # `AshEnterprise.Audit.EventSource`; the nudge reads `:resource` and `:organization_id`
    # off the row, which are the library's default field spellings.
    notifiers: [AshBpmn.Triggers.Nudge]

  # The chain is `ash_events_chain`'s: the trigger SQL, the verifier
  # (`AshEvents.Chain.verify/2`) and the move to the archive
  # (`AshEvents.Chain.Retention`) are built from this one declaration. The names and
  # the digest are the ones this table's rows were written under, so the rows already
  # in it verify unchanged:
  #
  #   * the trigger functions keep their names, and the statements, triggers and chain
  #     index are named after the table as they always were;
  #   * `digest_columns` is the column list the rows were hashed over, in order. A
  #     column the trigger wrote bare is `:omit_nil` (`concat_ws` skips a NULL); the
  #     actor and the tenant were coalesced to an empty field, the package's default
  #     rendering. Changing it stops every existing row from verifying.
  use AshEvents.Chain.Resources,
      {:chained_log,
       partition: :organization_id,
       partition_metadata_key: "organization_id",
       chain_function: "ash_enterprise_audit_chain",
       immutable_function: "ash_enterprise_audit_immutable",
       archive_table: "audit_event_archive",
       archive_run: AshEnterprise.Audit.ArchiveRun,
       digest_columns: [
         {:sequence, :omit_nil},
         {:id, :omit_nil},
         {:record_id, :omit_nil},
         {:version, :omit_nil},
         {:occurred_at, :omit_nil},
         {:resource, :omit_nil},
         {:action, :omit_nil},
         {:action_type, :omit_nil},
         :user_id,
         :organization_id,
         {:data, :omit_nil},
         {:changed_attributes, :omit_nil},
         {:metadata, :omit_nil},
         # Application time (record_as_of?): a row without either hashes as it did
         # before they existed.
         {:as_of, :omit_nil},
         {:as_of_range, :omit_nil}
       ]}

  postgres do
    table "audit_events"
    repo AshEnterprise.Repo

    references do
      # No foreign key: the run is lineage telemetry, deleted after its
      # retention window, while the audit entry is permanent.
      reference :lineage_run, ignore?: true
    end

    # The chain index (`audit_events_chain_index`) and the chain and immutability
    # statements are the package's (`AshEvents.Chain.Resources`, above): it emits them
    # under the names this table has always had, and refuses a second declaration.
    #
    # One command per statement, deliberately: Ecto's `execute/1` sends the string
    # as a prepared statement, and Postgres refuses "cannot insert multiple
    # commands into a prepared statement".
    custom_statements do
      # The correlation id as a real, indexed column, so "the audit entries of
      # this lineage run" is an index lookup and a plain relationship
      # (`AshEnterprise.Lineage.Run.audit_entries`, and `lineage_run` below).
      # Generated by the database from the metadata the platform stamps, like
      # `organization_id`, so it cannot disagree with it; a value that is not
      # a UUID reads as NULL. A stored generated column is filled for existing
      # rows by the table rewrite, which fires no row trigger, so the
      # append-only trigger is not in the way and the chain is unchanged (its
      # hash covers named columns, not this one).
      statement :audit_events_correlation_id do
        up """
        ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS correlation_id uuid
          GENERATED ALWAYS AS (
            CASE WHEN (metadata->>'correlation_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN (metadata->>'correlation_id')::uuid END
          ) STORED;
        """

        down "ALTER TABLE audit_events DROP COLUMN IF EXISTS correlation_id;"
      end

      statement :audit_events_correlation_id_index do
        up """
        CREATE INDEX IF NOT EXISTS audit_events_correlation_id_index
          ON audit_events (correlation_id);
        """

        down "DROP INDEX IF EXISTS audit_events_correlation_id_index;"
      end
    end

    # Created by the custom statement above, not by the snapshot diff: a
    # generated column has no Ash migration spelling.
    migration_ignore_attributes [:correlation_id]
  end

  event_log do
    clear_records_for_replay AshEnterprise.Audit.ClearRecordsForReplay
    primary_key_type Ash.Type.UUIDv7

    # A temporal resource's events record the application time of each write
    # (`as_of`, or `as_of_range` for a write over a period); ash_events refuses
    # an audited temporal resource without it. The chain hashes both.
    record_as_of? true

    # Human actors are persisted as a real foreign key.
    #
    # Non-human actors (`AshEnterprise.Platform.SystemActor`) are NOT persisted
    # here, because `persist_actor_primary_key` requires its destination to be an
    # Ash resource and a system actor is deliberately a compile-time constant
    # rather than a table -- see that module for why. Their attribution is
    # carried in event metadata instead.
    #
    # The distinction still has to survive: "the nightly reconciliation did this"
    # and "we failed to record who did this" are different findings, and a null
    # user_id alone cannot tell them apart.
    persist_actor_primary_key :user_id, AshEnterprise.Accounts.User

    # The key of the chain the event joins: its metadata's `organization_id`, which
    # `StampCorrelation` writes from the changeset's tenant (again in a `before_action`,
    # for a write given its tenant only when it runs). For a tenant's chain it is the
    # key `AshEvents.AdvisoryLockKeyGenerator.Default` gives that tenant, which is the
    # one `AshEnterprise.Repo.AdvisoryLock.xact_lock_audit_log!/2` takes to order the
    # MDM refold behind audited writes. See "Something depends on that lock" above.
    advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator

    # What the Audit trail and Lineage surfaces show of an entry: when, what,
    # which record and who. Never `data`, `changed_attributes` or `metadata`.
    public_fields [:id, :occurred_at, :resource, :action, :action_type, :record_id, :user_id]
  end

  @doc """
  The SOC 2 criteria this module records evidence for (the audit event log).

  Read by `AshCompliance.Ownership.Resolver.proves_producer/2`; `docs/controls.json`
  rows that name this module as their evidence producer must appear here.
  """
  def evidence_controls, do: ["CC6.3"]

  actions do
    # The log is append-only: AshEvents writes entries as a side effect of other
    # actions, nothing may create, update or destroy one directly, and since the
    # immutability trigger the database refuses too. Only reading is offered.
    defaults [:read]
    default_accept []

    read :for_export do
      description """
      The evidence an auditor asks for: everything that happened in a window,
      in chain order.
      """

      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false

      # Chain order, not time order. They agree in practice, and when they do
      # not it is because a clock moved -- in which case the sequence is the one
      # telling the truth about what the database saw.
      prepare build(sort: [sequence: :asc])

      # A twelve-month SOC 2 observation window is not a result set anyone should
      # hold in memory. Keyset rather than offset because the log only grows at
      # one end, so a keyset cursor stays correct while the export runs.
      pagination keyset?: true, required?: false

      filter expr(occurred_at >= ^arg(:from) and occurred_at < ^arg(:to))
    end

    read :chain do
      description "One tenant's chain in order, for verification."

      argument :organization_id, :uuid, allow_nil?: true

      prepare build(sort: [sequence: :asc])

      filter expr(organization_id == ^arg(:organization_id))
    end
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    # Reading the audit log is itself a privileged act -- it reveals the
    # existence, shape and history of records the reader may not otherwise be
    # able to see. So it is gated on an explicit grant rather than being
    # readable by anyone who can reach the admin UI.
    #
    # Only `:global` grants are meaningful here, and that is not the limitation it
    # used to be. Depth answers "how much of a tenant may you see"; the tenant
    # itself is answered by the multitenancy block above, so a customer reading
    # their own trail holds a global grant *within their tenant* and the data
    # layer does the rest. Two different questions, two different mechanisms --
    # which is why there is no bespoke check here.
    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end

  # Runs on the create action ash_events adds, so it covers every event,
  # before the chain trigger hashes the row.
  changes do
    change AshEnterprise.Audit.Changes.RedactSensitive, on: [:create]
  end

  # The log is tenant-scoped by the *same* mechanism as everything else, rather
  # than by a bespoke policy check.
  #
  # This is the whole reason `organization_id` is a real column and not a JSON
  # lookup. Before it existed, reading the log required a `:global` grant --
  # necessarily, because the log has no owner and no business unit, so `:deep`,
  # `:local` and `:basic` all reach nothing. The consequence was that a customer
  # could not see their own history at all: their only route to it was through
  # someone holding a grant over *every* tenant's log, which is the opposite of
  # what per-tenant log isolation means.
  #
  # `global? true` is what lets the two readings coexist. A request carrying a
  # tenant -- which is every ordinary request, since
  # `AshEnterpriseWeb.Plugs.LoadActorContext` sets one -- sees that tenant's
  # events and no others, enforced by the data layer rather than by a policy that
  # could be wrong. A read with no tenant at all sees everything, which is what a
  # system actor and a cross-tenant investigation need.
  #
  # Writes never carry a tenant: AshEvents inserts events without one, and the
  # chain trigger derives `organization_id` from the metadata the platform
  # stamped. So the column is written by the database and filtered by Ash, and
  # neither side takes the caller's word for it.
  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end

  attributes do
    # All four are written by the database, never by Elixir. `generated? true`
    # is what says so: Ash will not attempt to set them, and reads them back from
    # the INSERT's RETURNING clause.

    # Position within a chain. A bigserial rather than the UUIDv7 primary key
    # because two events can land in the same millisecond and the chain needs a
    # total order, not an approximate one.
    attribute :sequence, :integer do
      generated? true
      writable? false
      public? false
      description "Monotonic insert position. Orders the hash chain."
    end

    # The tenant this event belongs to, lifted out of `metadata` by the trigger.
    # A real column rather than a JSON lookup because a policy filters on it and
    # the chain index covers it.
    attribute :organization_id, :uuid do
      generated? true
      writable? false
      public? false
      description "The tenant the event belongs to. NULL events form their own chain."
    end

    attribute :previous_hash, :string do
      generated? true
      writable? false
      public? false
      description "The hash of the preceding event in this tenant's chain."
    end

    # Lifted out of `metadata` by a generated column (see `custom_statements`).
    attribute :correlation_id, :uuid do
      generated? true
      writable? false
      public? true

      description "The correlation id of the operation that wrote this entry; its lineage run's id."
    end

    attribute :hash, :string do
      generated? true
      writable? false
      public? false
      description "SHA-256 over this event's contents and `previous_hash`."
    end
  end

  relationships do
    # The lineage run of the operation that wrote this entry: a run's id is
    # its correlation id (`AshEnterprise.Lineage.Run`). Read under the
    # reader's lineage grant, so it is absent for someone without one.
    belongs_to :lineage_run, AshEnterprise.Lineage.Run do
      source_attribute :correlation_id
      define_attribute? false
      public? true
      domain AshEnterprise.Lineage
    end
  end

  @doc """
  Events attributable to no human: `user_id` is null.

  Read alongside the `system_actor` metadata key to see which non-human actor
  was responsible.
  """
  def system_events_query do
    require Ash.Query
    Ash.Query.filter(__MODULE__, is_nil(user_id))
  end
end
