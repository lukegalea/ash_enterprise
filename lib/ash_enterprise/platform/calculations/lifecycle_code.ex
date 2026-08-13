defmodule AshEnterprise.Platform.Calculations.LifecycleCode do
  @moduledoc """
  Derives the Dataverse `statecode` / `statuscode` integers from
  `lifecycle_status`.

  ## Why an Elixir calculation rather than an expression

  An expression calculation would push into SQL and stay filterable and
  sortable, which is what you would want. It is not used here because
  `Ash.Resource.Calculation.Expression` takes *built* expression structs, and a
  transformer building them by hand would be coupled to Ash's internal
  representation of `if`/`==` — a version-fragile trade for a convenience field.

  The cost is bounded and worth stating plainly: **`state_code` and
  `status_code` cannot be used in a database filter or sort.** Filter on
  `lifecycle_status` instead, which is a real column, indexed, and is the
  canonical value. These two exist for interop with clients that expect the
  Dataverse column shape, and they are correct on read.

  If they ever need to be filterable — a Dataverse-shaped external API, say —
  the honest fix is to store them as maintained columns with a change keeping
  them in step, accepting the duplication that
  `AshEnterprise.Platform.Lifecycle` currently avoids.
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts) do
    case opts[:pairs] do
      pairs when is_list(pairs) and pairs != [] -> {:ok, opts}
      _ -> {:error, "#{inspect(__MODULE__)} requires a non-empty :pairs option"}
    end
  end

  @impl true
  def load(_query, _opts, _context), do: [:lifecycle_status]

  @impl true
  def calculate(records, opts, _context) do
    lookup = Map.new(opts[:pairs])

    Enum.map(records, fn record ->
      Map.get(lookup, record.lifecycle_status)
    end)
  end
end
