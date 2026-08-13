defmodule AshEnterprise.Accounts.BusinessUnit do
  @moduledoc """
  A node in the organizational hierarchy, and the unit of the `Local` and `Deep`
  access levels.

  Every tenant has exactly one **root** business unit (`parent_business_unit_id`
  is null) and every user belongs to exactly one business unit. A record's
  `owning_business_unit_id` decides who can reach it at anything below
  Organization level. See `docs/manifesto/03-authorization-is-data.md`.

  ## The materialized path

  `Deep` access means "my business unit and everything beneath it". Answering
  that with a recursive CTE on every policy evaluation is exactly the per-row
  query the authorization design forbids, so the ancestor chain is materialized
  into `path`:

      /a1b2.../  (root)
      /a1b2.../c3d4.../  (child)
      /a1b2.../c3d4.../e5f6.../  (grandchild)

  With that, a subtree is a **prefix match on an indexed column**:

      WHERE path LIKE '/a1b2.../c3d4.../%'

  which `AshEnterprise.Security.ActorContext` runs **once per request** to build
  `bu_subtree_ids`. Policy checks then compare against that precomputed set and
  never touch the database.

  Dataverse does the same thing — `team.traversedpath` — for the same reason.

  ### The cost

  Moving a business unit rewrites the `path` of its entire subtree. That is
  deliberate: reparenting is rare and reads are constant, so the expensive
  operation is the one that almost never happens. It is done inside a
  transaction by `AshEnterprise.Accounts.Changes.MaintainBusinessUnitPath`.

  ## Ownership

  `:business_owned`, matching Dataverse. A business unit is not owned by a user
  or a team — it is part of the security structure itself.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    ownership: :business_owned,
    cdm_entity: "BusinessUnit"

  postgres do
    table "business_units"
    repo AshEnterprise.Repo

    custom_indexes do
      # The index that makes Deep depth checks cheap.
      #
      # text_pattern_ops is not optional here: under any collation other than C,
      # a plain btree index cannot serve `LIKE 'prefix%'`. Without it this index
      # exists, looks reasonable, and is never used -- and the sequential scan it
      # hides only becomes visible at production data volumes.
      index ["organization_id", "path text_pattern_ops"],
        name: "business_units_org_path_prefix_index",
        using: "btree"
    end

    references do
      reference :parent_business_unit, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 160
    end

    attribute :path, :string do
      allow_nil? false
      public? true
      writable? false

      description """
      Materialized ancestor path, maintained by the platform. Slash-delimited
      ids, leading and trailing slash: "/root-id/child-id/".
      """
    end

    attribute :depth, :integer do
      allow_nil? false
      default 0
      public? true
      writable? false
      description "Distance from the root. The root is 0. Derived from path."
    end

    attribute :division_name, :string do
      public? true
      constraints max_length: 100
    end

    attribute :cost_center, :string do
      public? true
      constraints max_length: 100
    end

    attribute :is_disabled, :boolean do
      allow_nil? false
      default false
      public? true
      description "A disabled business unit keeps its records but grants no access through them."
    end
  end

  relationships do
    belongs_to :parent_business_unit, __MODULE__ do
      public? true
      attribute_writable? true

      description """
      Null only for the tenant's root business unit. Dataverse marks this
      ApplicationRequired for the same reason: exactly one row per tenant may
      have no parent.
      """
    end

    has_many :child_business_units, __MODULE__ do
      public? true
      destination_attribute :parent_business_unit_id
    end
  end

  identities do
    identity :unique_name_per_parent, [:parent_business_unit_id, :name]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name, :division_name, :cost_center, :parent_business_unit_id]

    create :create do
      primary? true
      change AshEnterprise.Accounts.Changes.MaintainBusinessUnitPath
    end

    update :update do
      primary? true
      require_atomic? false
      change AshEnterprise.Accounts.Changes.MaintainBusinessUnitPath
    end

    update :disable do
      accept []
      change set_attribute(:is_disabled, true)
      change set_attribute(:state_code, 1)
    end

    update :enable do
      accept []
      change set_attribute(:is_disabled, false)
      change set_attribute(:state_code, 0)
    end

    read :subtree do
      description "Every business unit at or below the given one."
      argument :business_unit_id, :uuid, allow_nil?: false

      prepare AshEnterprise.Accounts.Preparations.FilterBusinessUnitSubtree
    end
  end

  calculations do
    calculate :is_root, :boolean, expr(is_nil(parent_business_unit_id)) do
      public? true
    end
  end

  code_interface do
    define :create
    define :read
    define :subtree, args: [:business_unit_id]
    define :disable
    define :enable
  end
end
