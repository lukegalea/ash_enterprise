defmodule Battery.BusinessEvents.SimulatedVendorState do
  @moduledoc """
  The vendor projection of the simulation twin: one grain per (region, subject,
  simulation run), so two runs of the same subject give two rows.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  postgres do
    table "battery_simulated_vendor_states"
    repo Battery.Repo
  end

  projection_resource do
    grain_fields([:region, :subject, :simulation_run])
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

    attribute :simulation_run, :string do
      allow_nil? false
      public? true
      constraints max_length: 512
    end

    attribute :review_status, :string do
      public? true
    end
  end
end
