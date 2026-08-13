defmodule AshEnterprise.Security.TeamRole do
  @moduledoc """
  Assigns a role to a team. Members inherit it.

  This is the second half of "effective roles": a principal holds
  `direct roles ∪ roles of every team they belong to`. Team-held roles are how
  real organizations grant access — per-user assignment does not survive
  onboarding at any scale.

  ## Access teams cannot hold roles

  Enforced, not just documented. Dataverse's access teams exist *because* they do
  not own records and do not hold roles — that is what makes them the cheap
  sharing mechanism. Letting one hold a role would quietly turn every
  role-resolution query into a walk over teams that were designed to be skipped,
  and the performance regression would appear far from the cause.

  See `AshEnterprise.Accounts.Types.TeamType`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false

  postgres do
    table "team_roles"
    repo AshEnterprise.Repo

    references do
      reference :team, on_delete: :delete
      reference :role, on_delete: :delete
      reference :scoping_business_unit, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :team, AshEnterprise.Accounts.Team do
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

      description "Defaults to the team's own business unit. See UserRole for why this is a column."
    end
  end

  identities do
    identity :unique_assignment, [:team_id, :role_id, :scoping_business_unit_id]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:team_id, :role_id, :scoping_business_unit_id]

    create :assign do
      primary? true
      upsert? true
      upsert_identity :unique_assignment

      validate AshEnterprise.Security.Validations.TeamCanHoldRoles
      change AshEnterprise.Security.Changes.DefaultTeamScopingBusinessUnit
    end
  end

  code_interface do
    define :assign
    define :read
    define :destroy
  end
end
