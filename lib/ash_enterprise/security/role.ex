defmodule AshEnterprise.Security.Role do
  @moduledoc """
  A named bag of `(privilege, depth)` grants. The thing an administrator actually
  assigns.

  > *"Grouping of security privileges. Users are assigned roles that authorize
  > their access to the Microsoft CRM system."* — the Dataverse `role` table's own
  > description.

  ## A role belongs to a business unit

  `owning_business_unit_id` is `SystemRequired` in Dataverse, and it is not
  decoration. Under the modern ("matrix") business-unit model a user can be
  assigned a role *from a different business unit*, and the grant is then scoped
  to **that** unit rather than the user's own. Which is why
  `AshEnterprise.Security.UserRole` carries its own `scoping_business_unit_id`
  rather than deriving scope from the user.

  That column exists from day one on purpose. Retrofitting it later means
  rewriting every role assignment and every depth check, and there is no
  migration that can recover the intent of assignments made without it.

  ## `is_inherited` is subtler than it looks

  Dataverse's `isinherited` has two values and they change what a *team* role
  means for its members:

    * `:team_privileges_only` — members get the privileges only as team members.
      They can create records **owned by the team**, but get no user-level
      (`:basic`) access of their own.
    * `:direct_user_and_team` (the default) — members additionally get
      user-level access and can create records owned by **themselves**.

  The distinction decides who ends up owning records created by a team member,
  which in turn decides who can see them afterwards. Getting it backwards is the
  kind of bug that shows up months later as "why can't my colleague see the thing
  I made".
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :business_owned,
    cdm_entity: "Role"

  postgres do
    table "roles"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :description, :string do
      public? true
      constraints max_length: 2000
    end

    attribute :is_inherited, AshEnterprise.Security.Types.RoleInheritance do
      allow_nil? false
      default :direct_user_and_team
      public? true
    end

    attribute :is_system_generated, :boolean do
      allow_nil? false
      default false
      public? true
      writable? false

      description """
      Seeded by the platform rather than created by an administrator. System
      roles may be assigned but not edited -- otherwise an upgrade that changes
      a built-in role would silently clobber local modifications.
      """
    end
  end

  relationships do
    has_many :role_privileges, AshEnterprise.Security.RolePrivilege do
      public? true
    end

    many_to_many :privileges, AshEnterprise.Security.Privilege do
      through AshEnterprise.Security.RolePrivilege
      source_attribute_on_join_resource :role_id
      destination_attribute_on_join_resource :privilege_id
      public? true
    end

    has_many :user_roles, AshEnterprise.Security.UserRole do
      public? true
    end

    has_many :team_roles, AshEnterprise.Security.TeamRole do
      public? true
    end
  end

  identities do
    identity :unique_name_per_business_unit, [:owning_business_unit_id, :name]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name, :description, :is_inherited, :owning_business_unit_id]

    create :create do
      primary? true
    end

    update :update do
      primary? true

      validate attribute_equals(:is_system_generated, false),
        message: "system-generated roles cannot be edited"
    end
  end

  code_interface do
    define :create
    define :read
  end
end
