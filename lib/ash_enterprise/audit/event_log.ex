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

  ## Retention

  ⚠️ There is no retention or purge policy here yet, and an append-only audit log
  is exactly what a GDPR erasure request collides with. Named honestly in
  `docs/manifesto/07-what-we-do-not-have.md#5-data-retention-purge-and-right-to-erasure`
  rather than pretended away. Before production: add time partitioning and a
  retention story.
  """

  use Ash.Resource,
    domain: AshEnterprise.Audit,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table "audit_events"
    repo AshEnterprise.Repo
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
