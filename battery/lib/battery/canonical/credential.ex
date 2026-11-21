defmodule Battery.Canonical.Credential do
  @moduledoc """
  The canonical credential: an owned, audited row whose number is
  sensitive. A field policy gives the number only to actors carrying
  the credential grant; every other field follows the row policy.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "battery_canonical_credentials"
    repo Battery.Repo
  end

  events do
    event_log Battery.Events.EventLog
  end

  field_policies do
    field_policy :number do
      authorize_if Battery.Canonical.HasCredentialAccess
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:holder, :number]
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :holder, :string, allow_nil?: false, public?: true

    attribute :number, :string do
      public? true
      sensitive? true
    end
  end
end
