defmodule Battery.Bpmn.Subject do
  @moduledoc """
  A host subject the process runs against: an order with an amount the
  decision evaluates. Not a BPMN resource itself (`:not_bpmn`).
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  @ash_bpmn_kind :not_bpmn

  def ash_bpmn_kind, do: @ash_bpmn_kind

  postgres do
    table "bpmn_test_subjects"
    repo Battery.Repo
  end

  actions do
    read :read do
      primary? true
    end

    create :create do
      primary? true
      accept [:name, :amount]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :amount, :integer do
      default 0
      public? true
    end

    timestamps()
  end
end
