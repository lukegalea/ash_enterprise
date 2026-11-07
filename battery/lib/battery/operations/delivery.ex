defmodule Battery.Operations.Delivery do
  @moduledoc """
  One webhook delivery the ingress accepted: the provider, the provider's redelivery-stable
  `dedup_key`, and the activation id it names, and nothing else. Never the payload.
  `receive` is idempotent per provider and key (the identity), and `followed_up` marks that
  `Battery.Operations.FollowUp` has read the provider for it.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "battery_deliveries"
    repo Battery.Repo
  end

  actions do
    defaults [:read]

    create :receive do
      accept [:provider, :dedup_key, :activation_id]
    end

    update :followed_up do
      accept []
      change set_attribute(:status, :followed_up)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :dedup_key, :string, allow_nil?: false, public?: true
    attribute :activation_id, :string, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :received,
      public?: true,
      constraints: [one_of: [:received, :followed_up]]

    create_timestamp :inserted_at
  end

  identities do
    identity :delivery, [:provider, :dedup_key]
  end
end
