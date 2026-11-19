defmodule AshEnterprise.Integration.Outbound.Validations.CatalogueTypes do
  @moduledoc "Every event type an endpoint subscribes to is in `Outbound.Catalogue`."

  use Ash.Resource.Validation

  alias AshEnterprise.Integration.Outbound.Catalogue

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :event_types) do
      nil ->
        :ok

      types ->
        case Enum.reject(types, &Catalogue.type?/1) do
          [] ->
            :ok

          [unknown | _] ->
            {:error,
             field: :event_types,
             message: "%{type} is not a subscribable event type",
             vars: [type: unknown]}
        end
    end
  end
end
