defmodule AshEnterprise.Mdm.SourceIdentity do
  @moduledoc """
  The XREF registry (ADR 0049/0050): which external source identity points
  at which golden record, RIGHT NOW — temporal, one open period per
  `(organization, source, stream, external_id)`. A merge closes the
  loser's periods and opens new ones at the survivor; an unmerge reverses.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false

  temporal do
    strategy :context
    attribute :valid_at
    recorded_at :recorded_at
  end

  postgres do
    table "mdm_source_identities"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :atom do
      allow_nil? false
      public? true
    end

    attribute :stream, :atom do
      allow_nil? false
      public? true
    end

    attribute :external_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 768
    end

    attribute :golden_resource, :string do
      allow_nil? false
      public? true
    end

    attribute :golden_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :asserted_by, :atom do
      allow_nil? false
      public? true
      default :mapping
      constraints one_of: [:mapping, :steward]
    end

    attribute :confidence, :decimal do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # The XREF invariant (ADR 0050): one source id points at exactly ONE
    # golden at a time. On a temporal resource the identity becomes a
    # WITHOUT OVERLAPS exclusion — history may hold many periods, "now"
    # may hold only one.
    identity :one_open_period, [:organization_id, :source, :stream, :external_id]
  end

  code_interface do
    define :current_for,
      action: :current,
      args: [:source, :stream, :external_id],
      not_found_error?: false
  end

  actions do
    read :read do
      primary? true
    end

    # The "right now" identity of one external id — the XREF lookup.
    read :current do
      get? true
      argument :source, :atom, allow_nil?: false
      argument :stream, :atom, allow_nil?: false
      argument :external_id, :string, allow_nil?: false

      filter expr(
               source == ^arg(:source) and stream == ^arg(:stream) and
                 external_id == ^arg(:external_id)
             )
    end

    create :open do
      description "Opens (or idempotently re-asserts) the identity's period at the survivor."

      accept [
        :source,
        :stream,
        :external_id,
        :golden_resource,
        :golden_id,
        :asserted_by,
        :confidence
      ]
    end

    # The temporal machinery versions this write: the old period closes at
    # the write instant and the new one opens — repointing is an update,
    # exactly as the guide's "you never pass a period as action input" says.
    update :repoint do
      description "Repoints the identity at a new golden — the merge's write."
      accept [:golden_resource, :golden_id]
    end

    update :retire do
      description "The unmerge correction: the identity stops pointing at any golden."
      accept []
      change set_attribute(:golden_id, nil)
    end
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
      authorize_if AshEnterprise.Security.Checks.SharedWithActor
      authorize_if AshEnterprise.Security.Checks.HierarchyGrant
    end
  end
end
