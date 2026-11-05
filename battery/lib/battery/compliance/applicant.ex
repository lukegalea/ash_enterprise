defmodule Battery.Compliance.Applicant do
  @moduledoc """
  A host subject the intake rules answer for: an applicant inside one
  organization, with the two things the rules read (identified, amount).
  The organization is the scope a re-evaluation runs over.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "battery_applicants"
    repo Battery.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:organization_id, :name, :identified, :amount]
    end

    read :in_scope do
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id))
      prepare build(sort: [name: :asc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :organization_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :identified, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :amount, :integer do
      allow_nil? false
      default 0
      public? true
    end

    timestamps()
  end
end
