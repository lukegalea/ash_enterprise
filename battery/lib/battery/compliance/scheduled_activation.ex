defmodule Battery.Compliance.ScheduledActivation do
  @moduledoc """
  The subject of the scheduled-activation process: which rule-set revision
  to activate, for which organization, effective from which instant.

  A process instance has no start variables, so the request is a row the
  instance runs against. Append-only: a different date is a new request.
  Not a BPMN resource itself (`:not_bpmn`).
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  @ash_bpmn_kind :not_bpmn

  def ash_bpmn_kind, do: @ash_bpmn_kind

  postgres do
    table "battery_scheduled_activations"
    repo Battery.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:organization_id, :rule_set_name, :revision, :effective_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :organization_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :rule_set_name, :string do
      allow_nil? false
      public? true
    end

    attribute :revision, :string do
      allow_nil? false
      public? true
    end

    attribute :effective_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    timestamps()
  end
end
