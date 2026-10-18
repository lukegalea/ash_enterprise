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
  def legal_depths(:owner_only), do: [:basic]
  def legal_depths(:business_owned), do: [:local, :deep, :global]
  def legal_depths(:organization_owned), do: [:global]
  def legal_depths(:none), do: [:global]

  # Resources whose rows belong to no tenant yet carry tenants' content, or
  # whose writes reach across tenants: raw provider landings (every tenant's
  # users' mailboxes, calendars and Slack, sealed but decrypted on read) and
  # erasure scopes (a shred is irreversible). A `:global` grant on an
  # untenanted resource is the filter `true`, so a tenant's role holding one
  # reaches every tenant's rows. These are therefore the platform operator's,
  # never a tenant role's: the Administrator auto-grant skips them, and a
  # grant of one can only be made by a system actor
  # (`AshEnterprise.Security.Validations.OperatorPrivilegeNeedsSystemActor`,
  # `AshEnterprise.Platform.Seeder.grant_platform_operator/1`).
  @operator_only [
    "AshEnterprise.Erasure.Key",
    "AshEnterprise.Erasure.Scope",
    "AshEnterprise.Ingestion.SourceObject"
  ]

  @doc """
  Whether privileges on `resource_name` (the module's `inspect/1`) are reserved
  for the platform operator: never auto-granted to a tenant's Administrator,
  and grantable only by a system actor.
  """
  @spec operator_only?(String.t()) :: boolean()
  def operator_only?(resource_name) when is_binary(resource_name),
    do: resource_name in @operator_only

  @doc "The resource names `operator_only?/1` is true for."
  @spec operator_only_resources() :: [String.t()]
  def operator_only_resources, do: @operator_only

  # User-owned rows holding one person's own mail and Slack, projected from
  # the linked accounts they own (ADR 0042, ADR 0024), the business events
  # derived from them (ADR 0051), and the joins derived from them (who takes
  # part in a conversation, who attends an event — who-talks-to-whom, as
  # plainly as the rows they join): readable by that person
  # and nobody else in the tenant. Every privilege on them is grantable at
  # `:basic` only — "I own it" — so no role, an Administrator's included,
  # reaches another user's rows, and hierarchy security does not widen them
  # (`AshEnterprise.Security.Checks.HierarchyGrant`). Sharing a row stays the
  # owner's own act (`SharedWithActor`).
  @owner_only [
    # A person's assistant history, which quotes their mail and Slack.
    "AshEnterprise.Assistant.Thread",
    "AshEnterprise.Assistant.Turn",
    # What the person did with the proposals in it (ids and an outcome).
    "AshEnterprise.Assistant.ProposalSettlement",
    # What the person made in it: their pinned apps and their reply drafts.
    "AshEnterprise.Assistant.PinnedApp",
    "AshEnterprise.Assistant.ReplyDraft",
    "AshEnterprise.BusinessEvents.Ledger",
    "AshEnterprise.BusinessEvents.Ledger.SimulationEvent",
    "AshEnterprise.Canonical.Conversation",
    "AshEnterprise.Canonical.ConversationParticipant",
    "AshEnterprise.Canonical.EventAttendee",
    "AshEnterprise.Canonical.Message",
    "AshEnterprise.Canonical.Person"
  ]

  @doc """
  Whether privileges on `resource_name` (the module's `inspect/1`) are
  owner-only: grantable at `:basic` depth and no wider, whatever the
  resource's ownership model would otherwise allow.
  """
  @spec owner_only?(String.t()) :: boolean()
  def owner_only?(resource_name) when is_binary(resource_name),
    do: resource_name in @owner_only

  @doc "The resource names `owner_only?/1` is true for."
  @spec owner_only_resources() :: [String.t()]
  def owner_only_resources, do: @owner_only

  @doc """
  The legal depths for privileges on `resource` (a module) with the given
  ownership model: `legal_depths/1`, narrowed to `:basic` for an owner-only
  resource.
  """
  @spec legal_depths_for(module(), atom()) :: [atom()]
  def legal_depths_for(resource, ownership) do
    if owner_only?(inspect(resource)),
      do: legal_depths(:owner_only),
      else: legal_depths(ownership)
  end

  @doc """
  The widest depth a privilege can be granted at (`:global` down to
  `:basic`), or nil if none. What an Administrator is auto-granted.
  """
  @spec widest_depth(%{
          can_be_global: boolean(),
          can_be_deep: boolean(),
          can_be_local: boolean(),
          can_be_basic: boolean()
        }) :: atom() | nil
  def widest_depth(privilege) do
    cond do
      privilege.can_be_global -> :global
      privilege.can_be_deep -> :deep
      privilege.can_be_local -> :local
      privilege.can_be_basic -> :basic
      true -> nil
    end
  end
end
