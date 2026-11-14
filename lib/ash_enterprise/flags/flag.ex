defmodule AshEnterprise.Flags.Flag do
  @moduledoc """
  One tenant's decision about one feature flag (ADR 0072), in table `feature_flags`:
  who in this tenant sees the code path the key names.

    * `key` is declared by the build (`AshEnterprise.Flags.Catalogue`); one row per
      key per tenant.
    * `state` is `:off`, `:on` (everyone in the tenant) or `:targeted`: the people in
      `user_ids`, the members of the teams in `team_ids`, everyone in the subtree of
      a business unit in `business_unit_ids`, and `percentage` of people by a stable
      bucket (`AshEnterprise.Flags.Targeting`).

  The row is never read when a flag is checked. `AshEnterprise.Security.ActorContext`
  resolves a tenant's rows once per request into the keys that are on for the
  person, and `AshEnterprise.Flags.enabled?/2` reads that set.

  Organization-owned and audited: reading and writing flags is a role grant on this
  resource like any other, and every create and flip is an event in the audit log
  with its actor and correlation id. Writes are `human_only`: deciding who sees a
  feature is a person's act, never a background job's or an automation principal's.
  The deployment's own switch is `FLAGS_OFF`, which needs no row.

  A flag is not authorization. No policy check reads one: a flag says whether a code
  path is offered, a grant says whether a person may use it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Flags,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    human_only: [:set, :turn_on, :turn_off, :target]

  postgres do
    table "feature_flags"
    repo AshEnterprise.Repo
  end

  actions do
    defaults [:read]

    create :set do
      description "Record this tenant's decision for a declared flag: its state and targets."
      accept [:key, :state, :team_ids, :business_unit_ids, :user_ids, :percentage]

      validate AshEnterprise.Flags.Validations.DeclaredKey
    end

    update :turn_on do
      description "On for everyone in the tenant."
      accept []

      change set_attribute(:state, :on)
    end

    update :turn_off do
      description "Off for everyone in the tenant. The targets are kept for a later `target`."
      accept []

      change set_attribute(:state, :off)
    end

    update :target do
      description "On for the named people, teams, business-unit subtrees and percentage only."
      accept [:team_ids, :business_unit_ids, :user_ids, :percentage]

      change set_attribute(:state, :targeted)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The declared flag this row decides (`AshEnterprise.Flags.Catalogue`)."
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :off
      constraints one_of: [:off, :on, :targeted]
      description "Off, on for everyone in the tenant, or on for the targets only."
    end

    attribute :team_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
      description "Teams whose members see the flag while it is targeted."
    end

    attribute :business_unit_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
      description "Business units whose whole subtree sees the flag while it is targeted."
    end

    attribute :user_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
      description "People who see the flag while it is targeted."
    end

    attribute :percentage, :integer do
      public? true
      constraints min: 0, max: 100

      description """
      The share of people, 0 to 100, who see the flag while it is targeted, by a bucket
      stable per person and key.
      """
    end
  end

  identities do
    identity :unique_key, [:key]
  end
end
