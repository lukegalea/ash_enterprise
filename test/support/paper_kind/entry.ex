defmodule AshEnterprise.Test.Paper.Entry do
  @moduledoc """
  A SYNTHETIC dated, categorised amount owned by one person: the rows
  `AshEnterprise.Test.Paper.ActivitySummary` reads, as the actor, to build its
  source. `:user_owned` on the platform base, so `:mine` reaches only the
  actor's own rows through the same policies a real kind's read goes through;
  ETS, so no table ships (see `AshEnterprise.Conformance.Widget`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Paper,
    ownership: :user_owned,
    data_layer: Ash.DataLayer.Ets,
    audit?: false,
    archival?: false,
    self_service: [:mine]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :on, :date, allow_nil?: false, public?: true
    attribute :amount, :decimal, allow_nil?: false, public?: true
    attribute :currency, :string, allow_nil?: false, public?: true
    attribute :category, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :on,
        :amount,
        :currency,
        :category,
        :owner_id,
        :owner_type,
        :owning_business_unit_id,
        :owning_user_id
      ]
    end

    update :update do
      primary? true
      accept [:amount, :category]
    end

    destroy :destroy do
      primary? true
    end

    read :mine do
      description "Self-service: the actor's own entries."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
    end
  end
end
