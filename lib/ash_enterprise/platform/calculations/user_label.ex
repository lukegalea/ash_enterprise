defmodule AshEnterprise.Platform.Calculations.UserLabel do
  @moduledoc """
  The email of the user a uuid column names (`field:`), for display: the
  provenance and decision columns (`created_by_id`, `modified_by_id`,
  `decided_by_id`, ...) are plain uuids by design
  (`AshEnterprise.Platform.Transformers.AddSystemAttributes`), and a person
  reading a row wants a name, not an id.

  One read for the whole batch, **as the reader** (their actor and tenant from
  the calculation context): a user they may not read is shown as nothing, and
  the uuid stays the thing a link carries. Pair it with
  `link {:users, <field>}` on the surface.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Accounts.User

  @impl true
  def init(opts) do
    if is_atom(opts[:field]) and not is_nil(opts[:field]),
      do: {:ok, opts},
      else: {:error, "field is required"}
  end

  @impl true
  def load(_query, opts, _context), do: [opts[:field]]

  @impl true
  def calculate(records, opts, context) do
    ids = records |> Enum.map(&Map.get(&1, opts[:field])) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    emails = emails(ids, context)

    {:ok, Enum.map(records, &Map.get(emails, Map.get(&1, opts[:field])))}
  end

  defp emails([], _context), do: %{}

  defp emails(ids, context) do
    User
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :email])
    |> Ash.read(Keyword.delete(Ash.Context.to_opts(context), :tenant))
    |> case do
      {:ok, users} -> Map.new(users, &{&1.id, to_string(&1.email)})
      {:error, _unreadable} -> %{}
    end
  end
end
