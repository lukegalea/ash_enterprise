defmodule AshEnterprise.Zones.TestItem do
  @moduledoc """
  A meaningless item written into a zone, used only to exercise
  `AshEnterprise.Zones.Changes.Admit` on a real create and update action.

  ETS keeps it out of the migration set, as with `AshEnterprise.Conformance.Widget`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Zones.TestDomain,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    data_layer: Ash.DataLayer.Ets,
    audit?: false,
    archival?: false

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string, public?: true
    attribute :data_class, AshEnterprise.Zones.Types.DataClass, public?: true

    attribute :residency, :string,
      public?: true,
      constraints: [match: AshEnterprise.Zones.Residency.pattern()]
  end

  actions do
    defaults [:read]

    create :ingest do
      accept [:label, :data_class, :residency]
      change {AshEnterprise.Zones.Changes.Admit, zone: "test-ontario"}
    end

    update :retag do
      accept [:data_class, :residency]
      require_atomic? false
      change {AshEnterprise.Zones.Changes.Admit, zone: "test-ontario"}
    end

    create :ingest_elsewhere do
      accept [:label, :data_class, :residency]
      change {AshEnterprise.Zones.Changes.Admit, zone: "not-declared"}
    end
  end
end
