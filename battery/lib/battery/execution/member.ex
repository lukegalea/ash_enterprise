defmodule Battery.Execution.Member do
  @moduledoc """
  A person at the battery's reference clinic: who asks for governed work, who approves
  it, and who it runs as. `role` is the one role they hold, which the battery's
  assignment resolver (`Battery.Bpmn.Resolver`) turns a `role` candidate clause into.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "battery_members"
    repo Battery.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :role]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :role, :string, public?: true
  end
end
