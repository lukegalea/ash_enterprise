defmodule AshEnterprise.SystemOne.BandTableCertification.StatusOnly do
  @moduledoc """
  The preparation of `AshEnterprise.SystemOne.BandTableCertification`'s
  `:for_definition` read, which crosses tenants: every field of a row it returns,
  except whether it is in force, when it was made and what it certifies, is withheld
  as `%Ash.ForbiddenField{}`. It applies to the rows after they are read, so a
  caller's `select` or `load` cannot widen it.
  """

  use Ash.Resource.Preparation

  @shown [
    :id,
    :status,
    :certified_at,
    :definition_key,
    :definition_version,
    :content_hash,
    :family
  ]

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn query, records ->
      {:ok, Enum.map(records, &withhold(&1, query.resource))}
    end)
  end

  defp withhold(record, resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.name in @shown))
    |> Enum.reduce(record, fn attribute, record ->
      Map.put(record, attribute.name, %Ash.ForbiddenField{
        field: attribute.name,
        type: :attribute
      })
    end)
  end
end
