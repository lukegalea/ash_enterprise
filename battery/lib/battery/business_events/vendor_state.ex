defmodule Battery.BusinessEvents.VendorState do
  @moduledoc """
  The canonical vendor projection the ledger's vendor-review events fold
  into — the projection_resource for the battery's BIZEV projector. One
  grain per (region, subject).
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  postgres do
    table "battery_vendor_states"
    repo Battery.Repo
  end

  projection_resource do
    grain_fields([:region, :subject])
  end

  actions do
    read :read do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :region, :atom do
      allow_nil? false
      public? true
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      constraints max_length: 512
    end

    attribute :review_status, :string do
      public? true
    end

    attribute :reviewer, :string do
      public? true
    end
  end
end
