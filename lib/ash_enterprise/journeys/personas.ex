defmodule AshEnterprise.Journeys.Personas do
  @moduledoc """
  Who a journey's personas are (`AshJourneys.Persona`): persona `name` with role
  `role` is the user the world bound under that same name, and the world must
  have seeded it as that kind (`AshEnterprise.Journeys.World`). `:tenant_admin` is
  the organization's administrator, `:member` a person with no role.
  """

  @behaviour AshJourneys.Persona

  @impl true
  def actor(role, name, bindings) do
    case Map.fetch(bindings, name) do
      {:ok, %{__metadata__: %{journey_role: ^role}} = user} ->
        {:ok, user}

      {:ok, %{__metadata__: metadata}} ->
        {:error,
         "#{name} was seeded as #{inspect(metadata[:journey_role])}, not #{inspect(role)}"}

      :error ->
        {:error, "the world bound no #{name}"}
    end
  end
end
