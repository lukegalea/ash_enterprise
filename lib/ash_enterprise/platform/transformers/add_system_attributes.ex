defmodule AshEnterprise.Platform.Transformers.AddSystemAttributes do
  @moduledoc """
  Adds the CDM system attributes and multitenancy configuration declared by the
  `platform` section of `AshEnterprise.Platform.SystemAttributes`.

  Every attribute is added with "add if absent" semantics, so a resource that
  declares its own version of one of these columns keeps it.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Run before Ash's own attribute handling has been finalised, and before
  # AshPostgres builds its migration view of the resource.
  @impl true
  def before?(_), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    ownership = Transformer.get_option(dsl, [:platform], :ownership, :user_owned)
    tenant? = Transformer.get_option(dsl, [:platform], :tenant?, true)
    lifecycle? = Transformer.get_option(dsl, [:platform], :lifecycle?, true)

    dsl =
      dsl
      |> add_provenance()
      |> add_concurrency()
      |> maybe_add_lifecycle(lifecycle?)
      |> maybe_add_ownership(ownership)
      |> maybe_add_tenancy(tenant?)

    {:ok, dsl}
  end

  # --- provenance: cdsCreationModificationDatesAndIds -------------------------
  #
  # `created_by_id` and friends are plain uuids rather than relationships. Adding
  # six `belongs_to :user` relationships to every resource in the system would
  # make the relationship graph unreadable and invite accidental preloads on
  # every query. The Accounts domain provides code interfaces for resolving them
  # when a UI actually needs a name.
  defp add_provenance(dsl) do
    dsl =
      dsl
      |> add_new(fn ->
        Ash.Resource.Builder.build_create_timestamp(:created_on, public?: true)
      end)
      |> add_new(fn ->
        Ash.Resource.Builder.build_update_timestamp(:modified_on, public?: true)
      end)

    Enum.reduce(
      [
        {:created_by_id, "The user who created this record."},
        {:modified_by_id, "The user who last modified this record."},
        {:created_on_behalf_by_id,
         "Set when an application or delegate created the record on a user's behalf."},
        {:modified_on_behalf_by_id,
         "Set when an application or delegate modified the record on a user's behalf."}
      ],
      dsl,
      fn {name, doc}, acc ->
        add_new(acc, fn ->
          Ash.Resource.Builder.build_attribute(name, :uuid,
            allow_nil?: true,
            public?: true,
            description: doc
          )
        end)
      end
    )
    |> add_new(fn ->
      Ash.Resource.Builder.build_attribute(:overridden_created_on, :utc_datetime_usec,
        allow_nil?: true,
        public?: true,
        description:
          "The original creation time, when a record was imported and its real created_on differs from the import time."
      )
    end)
    |> add_new(fn ->
      Ash.Resource.Builder.build_attribute(:import_sequence_number, :integer,
        allow_nil?: true,
        public?: false,
        description: "Identifies the data import or migration that created this record."
      )
    end)
  end

  # --- concurrency: cdsVersionTracking ----------------------------------------
  #
  # Dataverse carries `versionnumber` as a bigint that increments on every write.
  # Here it backs optimistic locking: a stale write is rejected rather than
  # silently overwriting a concurrent edit. Enterprise forms are long-lived and
  # two users editing the same record is normal, not exceptional.
  defp add_concurrency(dsl) do
    add_new(dsl, fn ->
      Ash.Resource.Builder.build_attribute(:version_number, :integer,
        allow_nil?: false,
        default: 1,
        public?: true,
        description: "Row version, incremented on write. Used for optimistic locking."
      )
    end)
  end

  # --- lifecycle: cdsStateAndStatus -------------------------------------------
  #
  # Dataverse stores `statecode` and `statuscode` as a pair of integers, but the
  # mapping status -> state is a total function, so storing both is storing the
  # same fact twice -- and two columns that must agree eventually disagree.
  #
  # We store only the status, as an atom driven by AshStateMachine, and DERIVE
  # both integers as calculations. Interop is preserved on read; an inconsistent
  # pair becomes unrepresentable.
  defp maybe_add_lifecycle(dsl, false), do: dsl

  defp maybe_add_lifecycle(dsl, true) do
    lifecycle = AshEnterprise.Platform.Lifecycle

    dsl
    |> add_new(fn ->
      Ash.Resource.Builder.build_attribute(:lifecycle_status, :atom,
        allow_nil?: false,
        default: lifecycle.default_status(),
        public?: true,
        constraints: [one_of: lifecycle.statuses()],
        description:
          "The record's lifecycle status. Managed by AshStateMachine: only declared transitions may change it."
      )
    end)
    |> add_derived_code(:status_code, lifecycle.status_code_pairs(),
      description: "Dataverse statuscode, derived from lifecycle_status. Read-only."
    )
    |> add_derived_code(:state_code, lifecycle.state_code_pairs(),
      description:
        "Dataverse statecode, derived from the status's owning state. Read-only -- this is why the pair cannot drift."
    )
  end

  # Builds `state_code`/`status_code` as a derived value over the status atom.
  #
  # A module calculation rather than an expression: see
  # `AshEnterprise.Platform.Calculations.LifecycleCode` for why, and for the
  # bounded cost (these two are not filterable in SQL; `lifecycle_status` is).
  defp add_derived_code(dsl, name, pairs, opts) do
    case Ash.Resource.Builder.build_calculation(
           name,
           :integer,
           {AshEnterprise.Platform.Calculations.LifecycleCode, pairs: pairs},
           public?: true,
           description: opts[:description]
         ) do
      {:ok, entity} ->
        if calculation_exists?(dsl, name) do
          dsl
        else
          Transformer.add_entity(dsl, [:calculations], entity)
        end

      {:error, error} ->
        raise "AddSystemAttributes could not build #{name}: #{inspect(error)}"
    end
  end

  defp calculation_exists?(dsl, name) do
    dsl
    |> Transformer.get_entities([:calculations])
    |> Enum.any?(&(&1.name == name))
  end

  # --- ownership: cdsOwnershipInfo --------------------------------------------
  defp maybe_add_ownership(dsl, ownership) when ownership in [:organization_owned, :none],
    do: dsl

  # Dataverse's BusinessOwned: the row belongs to a business unit, not to a
  # principal. Local and Deep depth checks still work; Basic does not, because
  # there is no owner to compare the actor against.
  defp maybe_add_ownership(dsl, :business_owned), do: add_owning_business_unit(dsl)

  defp maybe_add_ownership(dsl, :user_owned) do
    dsl
    |> add_owning_business_unit()
    |> add_new(fn ->
      Ash.Resource.Builder.build_attribute(:owner_id, :uuid,
        allow_nil?: false,
        public?: true,
        description: "The owning principal: a user or a team."
      )
    end)
    |> add_new(fn ->
      # The CDM models this as an inline `Owner` entity with userOption and
      # teamOption members, discriminated by `ownerIdType`. A two-column
      # (id, type) pair is the same thing and is what Ash policies can filter on
      # without a join.
      Ash.Resource.Builder.build_attribute(:owner_type, AshEnterprise.Platform.Types.OwnerType,
        allow_nil?: false,
        default: :user,
        public?: true,
        description: "Discriminates owner_id between a user and a team."
      )
    end)
    |> add_new(fn ->
      Ash.Resource.Builder.build_attribute(:owning_user_id, :uuid,
        allow_nil?: true,
        public?: true,
        description: "Set when owner_type is :user. Denormalized from owner_id."
      )
    end)
    |> add_new(fn ->
      Ash.Resource.Builder.build_attribute(:owning_team_id, :uuid,
        allow_nil?: true,
        public?: true,
        description: "Set when owner_type is :team. Denormalized from owner_id."
      )
    end)
  end

  # Denormalized deliberately. `Local` and `Deep` depth checks compare the
  # record's owning business unit against the actor's subtree, and that must be a
  # column on this row -- resolving it through the owner for every row of every
  # query is exactly the per-row lookup thesis 3 forbids.
  defp add_owning_business_unit(dsl) do
    add_new(dsl, fn ->
      Ash.Resource.Builder.build_attribute(:owning_business_unit_id, :uuid,
        allow_nil?: true,
        public?: true,
        description:
          "Denormalized owning business unit, so Local/Deep depth checks are a column comparison."
      )
    end)
  end

  # --- tenancy ----------------------------------------------------------------
  defp maybe_add_tenancy(dsl, false), do: dsl

  defp maybe_add_tenancy(dsl, true) do
    dsl
    |> add_new(fn ->
      Ash.Resource.Builder.build_attribute(:organization_id, :uuid,
        allow_nil?: false,
        public?: true,
        writable?: false,
        description: "Tenant discriminator. CDM-native: every Dataverse table carries it."
      )
    end)
    |> Transformer.set_option([:multitenancy], :strategy, :attribute)
    |> Transformer.set_option([:multitenancy], :attribute, :organization_id)
    # `global? true` lets genuinely cross-tenant work (platform administration,
    # the tenant provisioning flow itself) run without a tenant set. Without it
    # every such query errors, and the workaround people reach for is disabling
    # multitenancy on the resource -- which is far worse.
    |> Transformer.set_option([:multitenancy], :global?, true)
  end

  # --- helpers ----------------------------------------------------------------

  # Add an attribute only if the resource has not declared one with that name.
  defp add_new(dsl, builder) do
    case builder.() do
      {:ok, entity} ->
        if attribute_exists?(dsl, entity.name) do
          dsl
        else
          Transformer.add_entity(dsl, [:attributes], entity)
        end

      {:error, error} ->
        raise "AddSystemAttributes could not build an attribute: #{inspect(error)}"
    end
  end

  defp attribute_exists?(dsl, name) do
    dsl
    |> Transformer.get_entities([:attributes])
    |> Enum.any?(&(&1.name == name))
  end
end
