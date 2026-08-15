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
    api_type: :business_unit,
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

    has_many :ancestors, __MODULE__ do
      public? true

      # The join is a path prefix, not a foreign key, which is what
      # `no_attributes?` says. Walking `parent_business_unit_id` instead would
      # be one query per level -- the recursive lookup the materialized path
      # exists to avoid. Same prefix technique `AshEnterprise.Security.
      # ActorContext` uses to resolve a Deep grant.
      #
      # Includes self: a unit's own path is a prefix of itself, so the breadcrumb
      # ends at the unit it describes rather than at its parent.
      no_attributes? true
      filter expr(like(parent(path), path <> "%"))
      sort depth: :asc

      description "Every unit from the root down to and including this one, by materialized path."
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

    # `is_disabled` and the lifecycle status are ORTHOGONAL, exactly as they are
    # in Dataverse -- `businessunit` carries both `isdisabled` and `statecode`.
    # Disabling stops a unit granting access through it; deactivating is the
    # record's lifecycle. Conflating them would mean one concept could not be
    # expressed without the other.
    #
    # Use the platform's `:deactivate` / `:activate` actions for the lifecycle;
    # they are guarded by the state machine. These two touch only the flag.
    update :disable do
      accept []
      change set_attribute(:is_disabled, true)
    end

    update :enable do
      accept []
      change set_attribute(:is_disabled, false)
    end

    read :subtree do
      description "Every business unit at or below the given one."
      argument :business_unit_id, :uuid, allow_nil?: false

      prepare AshEnterprise.Accounts.Preparations.FilterBusinessUnitSubtree
    end
  end

  aggregates do
    # An aggregate rather than a hand-written SQL subquery. `Ash.Resource.
    # Aggregate` defaults to `authorize?: true`, so the destination's policies,
    # the tenant filter and AshArchival's `archived_at` base filter all apply
    # without being restated. A `fragment/1` doing the same join would bypass
    # all three silently, and would have to keep matching them forever.
    #
    # One lateral join for the whole page, not a query per row.
    list :ancestor_names, :ancestors, :name do
      public? true
      sort depth: :asc
    end
  end

  calculations do
    calculate :is_root, :boolean, expr(is_nil(parent_business_unit_id)) do
      public? true
    end

    calculate :breadcrumb, :string, expr(string_join(ancestor_names, " / ")) do
      public? true

      description """
      The ancestor chain by name, root first: "Example Corp / Engineering / Platform".

      `path` is the same chain as UUIDs, and stays that way: it is an
      authorization structure, read by every Deep grant as a prefix comparison.
      This is the display of it, derived, and never a second source of truth.
      """
    end

    # Indentation as data, because A2UI has nowhere to put it: no component in
    # any version of the spec carries a padding, indent or spacing property, and
    # an unknown property does not degrade -- the client throws and discards the
    # whole message. What it does have is markdown on every Text value, so the
    # indent travels inside the string.
    #
    # `&nbsp;` rather than spaces: markdown collapses runs of spaces, and four
    # leading spaces would make the line a code block instead.
    calculate :tree_label,
              :string,
              expr(
                fragment(
                  # The cast is required, not defensive: Ash renders `depth` as
                  # bigint and Postgres only has repeat(text, integer), so
                  # without it the query fails with `function repeat(unknown,
                  # bigint) does not exist`.
                  "repeat('&nbsp;', (? * 6)::integer) || CASE WHEN ? = 0 THEN '' ELSE '└─ ' END || ?",
                  depth,
                  depth,
                  name
                )
              ) do
      public? true

      description """
      `name`, indented by depth, for rendering the hierarchy as a flat list.

      Correct only when sorted by `path` ascending. Because every segment is a
      fixed-width UUID, lexicographic path order *is* depth-first pre-order, so
      each row lands directly beneath its parent.
      """
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
