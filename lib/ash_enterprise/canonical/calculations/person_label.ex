defmodule AshEnterprise.Canonical.Calculations.PersonLabel do
  @moduledoc """
  How a related `AshEnterprise.Canonical.Person` is named on a surface: their
  display name, else their address, else nil. `relationship:` names the
  belongs_to to read through (`:organizer`, `:sender`).

  The person is loaded under the reading actor's policies, so a correspondent
  the reader may not see is simply blank.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.Calculations.RelatedField

  @impl true
  def init(opts) do
    if is_atom(opts[:relationship]) and not is_nil(opts[:relationship]),
      do: {:ok, opts},
      else: {:error, "relationship is required"}
  end

  # The person is loaded in `calculate/3`, as the reader: a relationship
  # named here would be loaded as a calculation dependency, which Ash does
  # without authorization (see `AshEnterprise.Platform.Calculations.RelatedField`).
  @impl true
  def load(query, opts, _context),
    do: RelatedField.source_attribute(query.resource, opts[:relationship])

  @impl true
  def calculate(records, opts, context) do
    with {:ok, loaded} <-
           RelatedField.load_related(records, opts[:relationship], [:name, :email], context) do
      {:ok, Enum.map(loaded, &label(Map.get(&1, opts[:relationship])))}
    end
  end

  @doc false
  def label(%Ash.NotLoaded{}), do: nil
  def label(%{name: name}) when is_binary(name) and name != "", do: name
  def label(%{email: email}) when not is_nil(email), do: to_string(email)
  def label(_person), do: nil
end
