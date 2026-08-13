defmodule AshEnterprise.Security.UserRole do
  @moduledoc """
  Assigns a role to a user, **scoped to a business unit**.

  This is the resource the agent console mutates when someone says *"assign the
  admin role to user XYZ"* — see `docs/manifesto/05-agents-are-users.md`.

  ## Why the scoping business unit is a column

  Dataverse's modern ("matrix") business-unit model lets a user hold a role from a
  business unit other than their own, and the grant is then evaluated relative to
  **that** unit. So an assignment is genuinely a triple:

      (user, role, scoping_business_unit)

  A regional manager can hold "Sales Manager" scoped to EMEA and "Sales Reader"
  scoped to APAC, and the `:deep` grants in each resolve against a different
  subtree.

  The column exists from the first commit deliberately. Deriving scope from
  `user.owning_business_unit_id` instead would work until the first customer needs
  cross-unit access, and then there is no migration: the intent of every existing
  assignment is unrecoverable, because "scoped to their own unit" and "scoped to
  the unit they happened to be in when assigned" are indistinguishable after the
  fact.

  Defaulting it to the user's own business unit keeps the simple case simple.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false

  postgres do
    table "user_roles"
    repo AshEnterprise.Repo

    references do
      reference :user, on_delete: :delete
      reference :role, on_delete: :delete
      reference :scoping_business_unit, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :user, AshEnterprise.Accounts.User do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :role, AshEnterprise.Security.Role do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :scoping_business_unit, AshEnterprise.Accounts.BusinessUnit do
      allow_nil? false
      public? true
      attribute_writable? true

      description """
      The business unit this grant is evaluated relative to. Defaults to the
      user's own unit.
      """
    end
  end

  identities do
    # The same role may be held twice by one user if scoped to different units --
    # that is the feature, not a duplicate.
    identity :unique_assignment, [:user_id, :role_id, :scoping_business_unit_id]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:user_id, :role_id, :scoping_business_unit_id]

    create :assign do
      primary? true
      upsert? true
      upsert_identity :unique_assignment

      description """
      Idempotent. Assigning a role someone already holds is the same intent twice,
      not an error -- which matters when an agent or a directory sync is the caller.
      """

      change AshEnterprise.Security.Changes.DefaultScopingBusinessUnit
    end
  end

  code_interface do
    define :assign
    define :read
    define :destroy
  end
end
