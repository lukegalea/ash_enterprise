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
  `mix ash_enterprise.audit.verify` walks the chain and reports the first break
  by sequence number. Dropping the trigger to make an edit therefore does not
  help: the edit is still detectable, which is the point of doing both.

  ### One chain per tenant, and why that is not a compromise

  The obvious design is a single global chain, and it would cost something real:
  every audited write in the system would have to serialize against every other,
  across all tenants.

  It would also be *redundant*, because AshEvents already takes
  `pg_advisory_xact_lock` on every audited action, keyed by the tenant of the
  resource being written (`AshEvents.AdvisoryLockKeyGenerator.Default`). The
  serialization a chain needs is therefore already held — per tenant. Chaining
  per tenant adds no contention that was not already there, and chaining globally
  would add a great deal.

  It is also the better artefact. A customer can verify their own chain without
  being shown anyone else's, which is exactly what "can I audit my own trail" has
  to mean in a multi-tenant system.

  Events with no tenant — registration before an organization exists, system
  actors operating outside one — form their own chain, keyed on `NULL`.

  ## Something depends on that lock which is not the chain

  The advisory lock above is taken by `AshEvents` for its own reasons, and the hash
  chain merely piggybacks on it. **A second consumer now depends on it too**, and on
  a stronger property than the chain needs, so it is recorded here rather than only
  where it is used.

  Because the lock is taken *before* the event row is inserted and is
  `xact`-scoped, a second transaction for the same tenant cannot consume
  `nextval()` until the first has committed. So **within one tenant, `sequence`
  order is commit order** — which is what makes `sequence` usable as a change-feed
  cursor at all. A plain `bigserial` is otherwise the canonical wrong thing to build
  a feed on: values are assigned at INSERT, so two transactions can take 100 and 101
  and commit in the other order, and a consumer holding a high-water mark loses 100
  permanently and silently.

  Three limits on that, each of which someone will otherwise assume away:

    * **It is per tenant, and only for tenant-scoped resources.** The default key
      generator returns a two-element list under attribute multitenancy and a single
      integer otherwise, so the two paths call `pg_advisory_xact_lock($1, $2)` and
      `pg_advisory_xact_lock($1)`. Postgres treats those as **separate lock spaces** —
      measured: holding `(0, 0)`, a `(0)` acquires in about a millisecond. The
      `NULL`-tenant chain therefore has *no* ordering guarantee, not a weaker one, and
      a consumer must give it its own cursor and treat it as best-effort.
    * **It depends on there being an enclosing transaction**, which is not obvious
      given `AshEnterprise.Repo` sets `prefer_transaction? false`. There is: an
      audited create traces as `begin / INSERT <resource> / pg_advisory_xact_lock /
      INSERT audit_events / commit`.
    * **It is `ash_events`' implementation, not our schema.** Setting a custom
      `advisory_lock_key_generator`, or an upstream change to when the lock is taken,
      invalidates all of the above — and would do so silently, because the failure is
      a consumer skipping an event rather than an error.

  `docs/plans/event-triggered-processes.md` §2 has the measurements and the design
  that rests on them.

  ## Retention

  ⚠️ There is still no retention or purge policy, and the immutability trigger
  above makes the collision with a GDPR erasure request sharper rather than
  softer: the log now actively refuses the `DELETE` that erasure implies. Named
  in `docs/manifesto/07-what-we-do-not-have.md#5-data-retention-purge-and-right-to-erasure`
  and designed in ADR 0024 rather than pretended away.
  """

  use Ash.Resource,
    domain: AshEnterprise.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog],
    # The trigger dispatcher's nudge. It runs *after* the transaction -- Ash defers
    # notifications -- so it cannot extend the per-tenant advisory lock this chain relies on.
    # It also cannot be transactional with the write, which is why it only nudges and the
    # cron-driven sweep is what makes dispatch complete.
    notifiers: [AshEnterprise.Process.Triggers.Notifier]

  postgres do
    table "audit_events"
    repo AshEnterprise.Repo

    custom_indexes do
      # The chain trigger reads the tail of each tenant's chain on every insert,
      # so this index is on the hot path of every audited write in the system,
      # not just of reading the log.
      index [:organization_id, :sequence], name: "audit_events_chain_index"
    end

    # One command per statement, deliberately: Ecto's `execute/1` sends the string
    # as a prepared statement, and Postgres refuses "cannot insert multiple
    # commands into a prepared statement". Splitting them also means a failure
    # names which piece failed.
    custom_statements do
      statement :audit_events_chain_function do
        up """
        CREATE OR REPLACE FUNCTION ash_enterprise_audit_chain() RETURNS trigger AS $fn$
        DECLARE
          prev text;
        BEGIN
          -- The tenant is taken from the metadata the platform stamps rather than
          -- accepted from the caller, so the column and the metadata cannot
          -- disagree. See AshEnterprise.Platform.Changes.StampCorrelation.
          NEW.organization_id := NULLIF(NEW.metadata->>'organization_id', '')::uuid;

          SELECT hash INTO prev
          FROM audit_events
          WHERE organization_id IS NOT DISTINCT FROM NEW.organization_id
          ORDER BY sequence DESC
          LIMIT 1;

          NEW.previous_hash := prev;
          NEW.hash := encode(sha256(convert_to(concat_ws('|',
            coalesce(prev, ''),
            NEW.sequence::text,
            NEW.id::text,
            NEW.record_id::text,
            NEW.version::text,
            NEW.occurred_at::text,
            NEW.resource,
            NEW.action,
            NEW.action_type,
            coalesce(NEW.user_id::text, ''),
            coalesce(NEW.organization_id::text, ''),
            NEW.data::text,
            NEW.changed_attributes::text,
            NEW.metadata::text
          ), 'UTF8')), 'hex');

          RETURN NEW;
        END;
        $fn$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS ash_enterprise_audit_chain() CASCADE;"
      end

      statement :audit_events_chain_trigger do
        up """
        CREATE TRIGGER audit_events_chain
          BEFORE INSERT ON audit_events
          FOR EACH ROW EXECUTE FUNCTION ash_enterprise_audit_chain();
        """

        down "DROP TRIGGER IF EXISTS audit_events_chain ON audit_events;"
      end

      statement :audit_events_immutable_function do
        up """
        CREATE OR REPLACE FUNCTION ash_enterprise_audit_immutable() RETURNS trigger AS $fn$
        BEGIN
          RAISE EXCEPTION 'audit_events is append-only; % is not permitted', TG_OP
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Correct a wrong entry by recording a new one.';
        END;
        $fn$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS ash_enterprise_audit_immutable() CASCADE;"
      end

      statement :audit_events_immutable_trigger do
        # Row-level on purpose: TRUNCATE is deliberately still allowed, because
        # `mix ecto.reset` has to work and a TRUNCATE is not a quiet edit -- it
        # takes the whole table, which is conspicuous in a way one altered row
        # is not.
        up """
        CREATE TRIGGER audit_events_immutable
          BEFORE UPDATE OR DELETE ON audit_events
          FOR EACH ROW EXECUTE FUNCTION ash_enterprise_audit_immutable();
        """

        down "DROP TRIGGER IF EXISTS audit_events_immutable ON audit_events;"
      end
    end
  end

  event_log do
    clear_records_for_replay AshEnterprise.Audit.ClearRecordsForReplay
    primary_key_type Ash.Type.UUIDv7

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
  end

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

    attribute :hash, :string do
      generated? true
      writable? false
      public? false
      description "SHA-256 over this event's contents and `previous_hash`."
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
