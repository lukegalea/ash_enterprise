defmodule AshEnterprise.Security.Privilege do
  @moduledoc """
  One `(resource, verb)` pair that a role can grant. The catalogue of things that
  can be permitted at all.

  Dataverse names these `prvReadAccount`, `prvWriteAccount`, and so on — one row
  per table per verb. We keep that shape: a privilege is not "read" in the
  abstract, it is "read `AshEnterprise.Accounts.Team`".

  ## Seeded, not created

  Privilege rows are **derived from the resource list**, not authored. Every
  platform resource yields up to eight of them, and
  `mix ash_enterprise.seed_privileges` regenerates the catalogue after resources
  are added. Hand-creating privileges would let the catalogue drift from what the
  application can actually do — you would be able to grant a privilege on a
  resource that no longer exists, and worse, *not* be able to grant one on a
  resource that does.

  This is also why the resource is organization-owned and not tenant-scoped: the
  catalogue describes the *software*, which is the same for every tenant. Only the
  grants (`RolePrivilege`) are tenant data.

  ## The can_be_* flags

  These mirror `privilege.canbebasic/canbelocal/canbedeep/canbeglobal` and record
  which depths are *legal* for this privilege, which depends on the resource's
  ownership model:

    * A `:user_owned` resource supports all four.
    * A `:business_owned` resource supports `:local`, `:deep`, `:global` — there
      is no owner, so `:basic` is meaningless.
    * An `:organization_owned` resource supports only `:global`. Dataverse says
      this plainly: for organization-owned tables "the only access level choices
      is either the user can do the operation or can't".

  Enforcing this matters because a role granting `:basic` on an
  organization-owned table looks like a restriction and is actually a grant of
  nothing — a silent misconfiguration that an administrator will read as "they
  have access".
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    cdm_entity: "Privilege"

  postgres do
    table "privileges"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :resource_name, :string do
      allow_nil? false
      public? true
      description ~S(The resource module this applies to, e.g. "AshEnterprise.Accounts.Team".)
    end

    attribute :access_right, AshEnterprise.Security.Types.AccessRightType do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description ~S(Human-readable identifier, Dataverse-style: "prvReadTeam".)
    end

    attribute :can_be_basic, :boolean, allow_nil?: false, default: true, public?: true
    attribute :can_be_local, :boolean, allow_nil?: false, default: true, public?: true
    attribute :can_be_deep, :boolean, allow_nil?: false, default: true, public?: true
    attribute :can_be_global, :boolean, allow_nil?: false, default: true, public?: true
  end

  identities do
    identity :unique_privilege, [:resource_name, :access_right]
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :resource_name,
      :access_right,
      :name,
      :can_be_basic,
      :can_be_local,
      :can_be_deep,
      :can_be_global
    ]

    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_privilege
      description "Idempotent, because the seeder re-runs on every deploy."
    end
  end

  code_interface do
    define :create
    define :read
  end

  @doc """
  Which depths are legal for a resource with the given ownership model.

  Kept as a function rather than data so it stays in one place and the seeder,
  the validations and the tests cannot disagree about it.
  """
  def legal_depths(:user_owned), do: [:basic, :local, :deep, :global]
  def legal_depths(:business_owned), do: [:local, :deep, :global]
  def legal_depths(:organization_owned), do: [:global]
  def legal_depths(:none), do: [:global]
end
