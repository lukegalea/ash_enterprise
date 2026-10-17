defmodule AshEnterprise.Canonical.Task do
  @moduledoc """
  A commitment with a status (dogfood §11): captured by the operator or
  extracted from a message by a later epic. `source` records where it came
  from — provenance is mandatory, not decoration.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, and `status` below is this resource's own
  lifecycle — a Dataverse Active/Inactive pair beside it would be two answers
  to one question.

  ## A person's own action items (ADR 0052)

  Any active member may capture an action item for themselves (`:capture`),
  read their own (`:mine`) and mark one of their own done (`:complete_mine`)
  with no role grant. `:complete_mine` is a generic action because a
  self-service update cannot be declared: it finds the task through `:mine`,
  as the actor, so it reaches only a row the actor owns, and only then runs
  `:complete` on it. That write is the actor's own act on their own row,
  recorded under their name in the audit log; every other update to a task
  still takes a role grant.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [:capture, :mine, :complete_mine]

  postgres do
    table "canonical_tasks"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
      description "What is to be done."
    end

    attribute :due_at, :utc_datetime_usec do
      public? true
      description "When it is due, if it is."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:open, :done, :cancelled]
      default :open
      description "The commitment's state: open until it is done or cancelled."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "Where the task came from: manual, gmail, slack, calendar."
    end

    attribute :external_system, :string do
      public? true
      constraints max_length: 64
      description "Source-of pair: which external system the task was projected from."
    end

    attribute :external_id, :string do
      public? true
      constraints max_length: 512
      description "Source-of pair: that system's id for the task."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_external, [:external_system, :external_id]
  end

  actions do
    defaults [:read]

    read :mine do
      description "The actor's own tasks, soonest due first."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
      prepare build(sort: [due_at: :asc_nils_last, inserted_at: :desc])
    end

    create :capture do
      description """
      Capture an open action item for the actor, owned by them. `source`
      records where it came from: `manual` (typed in) or `assistant`
      (proposed in the agent chat and confirmed by the person).
      """

      accept [:title, :due_at]

      argument :source, :atom do
        allow_nil? false
        default :manual
        constraints one_of: [:manual, :assistant]
      end

      change set_attribute(:status, :open)
      change set_attribute(:source, arg(:source))
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
    end

    update :complete do
      description "Mark the task done."
      accept []
      change set_attribute(:status, :done)
    end

    action :complete_mine, :struct do
      description """
      Mark one of the actor's own tasks done: found through `:mine` as the
      actor, then `:complete`. Another person's task is not found.
      """

      constraints instance_of: __MODULE__

      argument :task_id, :uuid do
        allow_nil? false
        description "The task to mark done (one of the actor's own)."
      end

      run AshEnterprise.Canonical.Actions.CompleteOwnTask
    end

    read :by_external do
      description """
      Look up the canonical row projected from one raw SourceObject.

      KNOWN GAP (E1 review, fix owned by a dedicated E1 follow-up):
      SourceObject identity is `[external_system, external_id]` *without* the
      stream, and this lookup inherits that shape — two streams sharing an
      external id would land on one row here. Projectors disambiguate by
      filtering `source_metadata["stream"]` when they select their raw rows;
      until the identity is fixed, lookups cannot.
      """

      get? true
      argument :system, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false

      filter expr(external_system == ^arg(:system) and external_id == ^arg(:id))
    end

    create :upsert_from_source do
      description "The replay write path: upsert on the source identity."

      accept [
        :title,
        :due_at,
        :status,
        :source,
        :external_system,
        :external_id,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_external
      upsert_fields [:title, :due_at, :status, :source]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
    define :mine
    define :capture, args: [:title]
    define :complete_mine, args: [:task_id]
  end
end
