defmodule AshEnterprise.Process.Binding do
  @moduledoc """
  Which definition of a given key this tenant runs.

  The platform ships baseline processes and decisions. A tenant may diverge from one — and the
  point of this resource is that diverging is a *deliberate, recorded, reversible act* rather
  than a fork that quietly becomes permanent.

  ## Absence is the default, and that is load-bearing

  **No row means "follow the platform baseline, latest published."**

  So provisioning a tenant writes nothing; a newly published baseline is live in every tenant
  that has not diverged, immediately; and reverting a customization is *deleting a row*. Any
  design where the default is a row is a design where onboarding a tenant means backfilling one
  row per workflow, forever, and where a tenant that was never customized is indistinguishable
  from one that was and then reverted.

  ## `forked_from_version` is not optional

  A tenant's first fork is version 1 in its own scope even when the platform is on version 5,
  because `AssignVersion` numbers within the tenant. Without recording what it was forked
  *from*, the lineage is unrecoverable and "you are two versions behind" has no answer.

  ## What rebinding does not do

  It does not touch anything already running. Instances pin `definition_id` at creation, so
  rebinding changes only what *new* instances resolve to. That is `ash_bpmn` usage rule 4 and
  it is not negotiable here: migrating an in-flight instance onto a definition it was never
  verified against is the failure the whole versioning design exists to prevent.

  Audited, because rebinding a workflow is exactly the kind of change an auditor should find
  in the log without being told to look.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Process,
    ownership: :organization_owned,
    lifecycle?: false,
    audit?: true,
    archival?: false

  postgres do
    table "process_bindings"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:process, :decision]
      public? true
      description "One table for both: a decision is versioned and diverged from identically."
    end

    attribute :key, :string do
      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      allow_nil? false
      constraints one_of: [:platform, :tenant]
      public? true

      description """
      `:tenant` — this tenant authored its own and runs that.
      `:platform` — deliberately pinned to a specific platform version rather than tracking
      the latest, which is what a tenant does when it wants to hold still.
      """
    end

    attribute :target_id, :uuid do
      allow_nil? false
      public? true

      description "The definition this tenant runs. Not a relationship: it may be a process or a decision."
    end

    attribute :bound_version, :integer do
      allow_nil? false
      public? true
      description "Denormalized so a list view is one read."
    end

    attribute :forked_from_version, :integer do
      public? true
      description "The platform version this diverged from. Nil when pinned rather than forked."
    end

    attribute :bound_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    attribute :bound_by_id, :uuid do
      public? true
      description "Who rebound it. Provenance for a change with no other visible author."
    end
  end

  identities do
    identity :one_per_key, [:kind, :key]
  end

  actions do
    defaults [:read]

    create :bind do
      accept [
        :kind,
        :key,
        :source,
        :target_id,
        :bound_version,
        :forked_from_version,
        :bound_by_id
      ]

      upsert? true
      upsert_identity :one_per_key
    end

    # Reverting a customization. Deliberately a destroy rather than a flag: the absence of a
    # row is what "follow the baseline" means, so anything else would be a second way to say it.
    destroy :unbind do
    end

    read :for_kind do
      argument :kind, :atom, allow_nil?: false
      filter expr(kind == ^arg(:kind))
    end

    read :by_key do
      argument :kind, :atom, allow_nil?: false
      argument :key, :string, allow_nil?: false
      filter expr(kind == ^arg(:kind) and key == ^arg(:key))
    end
  end

  code_interface do
    define :bind
    define :unbind
    define :for_kind, args: [:kind]
    define :by_key, args: [:kind, :key], get?: true
  end
end
