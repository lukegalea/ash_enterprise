defmodule Battery.Mdm.Vendor do
  @moduledoc """
  A stand-in golden entity: the vendor master record survivorship folds
  the event-landed candidates into.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "battery_mdm_vendors"
    repo Battery.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :city, :tier, :external_ref, :provenance]
    end

    update :update do
      accept [:name, :city, :tier, :external_ref, :provenance]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true
    attribute :city, :string, public?: true
    attribute :tier, :string, public?: true
    attribute :external_ref, :string, public?: true

    # The survivorship provenance, as data: per-attribute winner source +
    # strategy, exactly what AshMdm.Survivorship.resolve/2 reports.
    attribute :provenance, :map, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
