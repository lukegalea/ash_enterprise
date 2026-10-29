defmodule AshEnterprise.Security.AutomationRole do
  @moduledoc """
  Assigns a role to an automation principal, scoped to a business unit (ADR 0043).

  The automation principal's counterpart of `AshEnterprise.Security.UserRole`: the
  same `(principal, role, scoping business unit)` triple, with the principal named from
  the closed list in `AshEnterprise.Platform.AutomationPrincipal` instead of a user.
  `AshEnterprise.Security.ActorContext.build_automation/2` resolves these rows into the
  principal's context exactly as a person's roles are resolved, so what an automation
  may do is data an administrator can read, and revoking it is deleting a row,
  effective at the next claim.

  ## Who may assign one

  Giving a machine authority is a person's decision, made in the open: `assign` is
  `human_only`, so neither a system actor nor an engine bypass reaches it, and a
  person needs a role granting it. Revoking (`destroy`) goes through the grant union
  like any other write.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false,
    human_only: [:assign]

  postgres do
    table "automation_roles"
    repo AshEnterprise.Repo

    references do
      reference :role, on_delete: :delete
      reference :scoping_business_unit, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :principal, :atom do
      allow_nil? false
      public? true
      constraints one_of: AshEnterprise.Platform.AutomationPrincipal.names()
      description "The automation principal holding the role."
    end
  end

  relationships do
    belongs_to :role, AshEnterprise.Security.Role do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :scoping_business_unit, AshEnterprise.Accounts.BusinessUnit do
      allow_nil? false
      public? true
      attribute_writable? true
      description "The business unit the role's local and deep grants are evaluated relative to."
    end
  end

  identities do
    identity :unique_assignment, [:principal, :role_id, :scoping_business_unit_id]
  end

  actions do
    defaults [:read, :destroy]

    create :assign do
      primary? true
      accept [:principal, :role_id, :scoping_business_unit_id]
      upsert? true
      upsert_identity :unique_assignment

      description "Idempotent: assigning a role the principal already holds in that scope is a no-op."
    end
  end

  code_interface do
    define :assign
    define :read
    define :destroy
  end
end
