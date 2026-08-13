defmodule AshEnterprise.Accounts.Position do
  @moduledoc """
  A node in the *job* hierarchy, as distinct from the organizational one.

  Business units answer "which part of the company does this record belong to".
  Positions answer "who reports to whom", and the two are genuinely different
  shapes: a VP of Sales sits above regional sales managers who may be spread
  across several business units.

  That is the whole reason position hierarchy exists alongside manager hierarchy —
  **it works across business units**, where the manager model is normally confined
  to the same unit or its parent.

  ## The direct ancestor path constraint

  A higher position sees a lower position's data **only along its own direct
  ancestor path**. The VP of Sales sees sales data beneath them; they do not see
  Support data, even though Support sits at the same level under the same CEO.

  This is what stops a job hierarchy from collapsing into "everyone senior sees
  everything", and it is the rule most likely to be got wrong — the naive
  implementation compares levels rather than lineage.

  ## Ownership

  `:organization_owned`, matching Dataverse. A position is reference data
  describing the org chart, not something a user owns.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    api_type: :position,
    ownership: :organization_owned,
    cdm_entity: "Position"

  postgres do
    table "positions"
    repo AshEnterprise.Repo

    references do
      reference :parent_position, on_delete: :restrict
    end
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
      constraints max_length: 100
    end
  end

  relationships do
    belongs_to :parent_position, __MODULE__ do
      public? true
      attribute_writable? true
      description "The position this one reports to. Null for the top of a hierarchy."
    end

    has_many :child_positions, __MODULE__ do
      public? true
      destination_attribute :parent_position_id
    end

    has_many :users, AshEnterprise.Accounts.User do
      public? true
      destination_attribute :position_id

      description """
      A position may be held by several users, but a user holds at most one
      position -- Dataverse states this directly: "A user can be tagged only with
      one position in a given hierarchy, however, a position can be used for
      multiple users."
      """
    end
  end

  identities do
    identity :unique_name, [:name]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name, :description, :parent_position_id]

    create :create do
      primary? true
      validate AshEnterprise.Accounts.Validations.NoPositionCycle
    end

    update :update do
      primary? true
      require_atomic? false
      validate AshEnterprise.Accounts.Validations.NoPositionCycle
    end
  end

  code_interface do
    define :create
    define :read
  end
end
