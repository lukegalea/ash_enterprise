defmodule Battery.Canonical.Task do
  @moduledoc """
  The canonical task the work-tracking facades read: an owned,
  audited, TEMPORAL row. One record per fact lives here; the facades
  rename words, never rows.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "battery_canonical_tasks"
    repo Battery.Repo
  end

  events do
    event_log Battery.Events.EventLog
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title, :status, :estimated_minutes, :internal_notes, :legacy_ref]
    end

    update :complete do
      accept []

      validate attribute_equals(:status, :open),
        message: "only an open task can be completed"

      change set_attribute(:status, :done)
    end

    update :set_estimate do
      accept [:estimated_minutes]
    end

    update :retitle do
      accept [:title]
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open

      constraints one_of: [:open, :done, :cancelled]
    end

    attribute :estimated_minutes, :integer, public?: true
    attribute :internal_notes, :string, public?: true
    attribute :legacy_ref, :string, public?: true
  end

  temporal do
    strategy :context
    attribute :valid_at
  end
end
