defmodule Battery.BusinessEvents.SourceRecord do
  @moduledoc """
  The macro-generated SourceRecord on the battery's own base — the raw
  landing layer external source history enters through.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  use AshDiscreteBusinessEvents.Resources, :source_record

  postgres do
    table "source_records"
    repo Battery.Repo
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
