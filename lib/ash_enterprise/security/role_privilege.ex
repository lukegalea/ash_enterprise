defmodule AshEnterprise.Security.RolePrivilege do
  @moduledoc """
  `(role, privilege, depth)`. **This table is the authorization model.**

  Everything in `docs/manifesto/03-authorization-is-data.md` reduces to rows here,
  unioned over the roles a principal holds and evaluated against a record's owner
  and owning business unit. Dataverse calls the equivalent column
  `privilegedepthmask`; we store the depth as an atom instead of a bitmask
  because the numeric values are unverified (see
  `AshEnterprise.Security.Types.PrivilegeDepth`).

  ## Why depth lives here and not on the privilege

  A privilege says *what* ("read Team"). The role grant says *how far* ("...for my
  whole business unit subtree"). The same privilege appears in many roles at
  different depths — that is the entire point of having roles. Putting depth on
  the privilege would collapse the catalogue into one row per depth per verb per
  resource and make roles pure name tags.

  ## The legality check

  A grant is rejected when the depth is not legal for the privilege's resource —
  `:basic` on an organization-owned resource, for instance. That combination is
  not merely useless: it *reads* to an administrator as "restricted access" while
  granting nothing at all, and it will be reported as a bug against the
  application rather than against the role. Failing at assignment time is the
  only place the mistake is cheap.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false,
    cdm_entity: "RolePrivileges"

  postgres do
    table "role_privileges"
    repo AshEnterprise.Repo

    references do
      # Deleting a role removes its grants -- a grant has no meaning without the
      # role. Deleting a *privilege* is restricted: privileges are seeded from
      # the resource list, and if one disappears we want the failure to be loud
      # rather than a silent, invisible loss of access.
      reference :role, on_delete: :delete
      reference :privilege, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :depth, AshEnterprise.Security.Types.PrivilegeDepth do
      allow_nil? false
      public? true
      description "How far this grant reaches. See PrivilegeDepth -- it is a total order."
    end
  end

  relationships do
    belongs_to :role, AshEnterprise.Security.Role do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :privilege, AshEnterprise.Security.Privilege do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    # One depth per (role, privilege). Two grants of the same privilege at
    # different depths would be redundant -- the wider one already implies the
    # narrower, because depth is a total order -- so the upsert below replaces
    # rather than accumulating.
    identity :unique_grant, [:role_id, :privilege_id]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:role_id, :privilege_id, :depth]

    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_grant

      validate AshEnterprise.Security.Validations.DepthLegalForPrivilege
    end

    update :update do
      primary? true
      accept [:depth]
      validate AshEnterprise.Security.Validations.DepthLegalForPrivilege
    end
  end

  code_interface do
    define :create
    define :read
    define :destroy
  end
end
