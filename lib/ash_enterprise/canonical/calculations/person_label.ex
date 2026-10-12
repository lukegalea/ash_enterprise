defmodule AshEnterprise.Canonical.Calculations.PersonLabel do
  @moduledoc """
  How a related `AshEnterprise.Canonical.Person` is named on a surface: their
  display name, else their address, else nil. `relationship:` names the
  belongs_to to read through (`:organizer`, `:sender`).

  The person is loaded under the reading actor's policies, so a correspondent
  the reader may not see is simply blank.
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts) do
    if is_atom(opts[:relationship]) and not is_nil(opts[:relationship]),
      do: {:ok, opts},
      else: {:error, "relationship is required"}
  end

  @impl true
  def load(_query, opts, _context), do: [{opts[:relationship], [:name, :email]}]

  @impl true
  def calculate(records, opts, _context) do
    {:ok, Enum.map(records, &label(Map.get(&1, opts[:relationship])))}
  end

  @doc false
  def label(%{name: name}) when is_binary(name) and name != "", do: name
  def label(%{email: email}) when not is_nil(email), do: to_string(email)
  def label(_person), do: nil
end
