defmodule AshEnterprise.Platform.TemporalHistory do
  @moduledoc """
  Every version of a set of temporal records, recovered through ordinary
  as-of reads (ADR 0049).

  Ash has no "all of history" read: a temporal read returns the one version
  of each record valid at its `as_of`. A version's period is a half-open
  range `[lower, upper)`, though, so its neighbours are one read away. The
  version before it is the one valid a microsecond before `lower`; the
  version after it is the one valid at `upper`. `versions/3` walks both ways
  from the versions it is given until a read finds nothing, which is where
  a record's history starts, ends, or has a gap.

  Every step is a plain read of the resource, as the caller's actor and in
  the caller's tenant, so policies decide each version exactly as they
  decide a current read. A reader who cannot read a record cannot recover
  its past.

  The walk costs one read per distinct instant, and is capped per record
  (`:max_versions`, default 50), so it suits a person's identities or a
  subject's facts, not a table scan.
  """

  require Ash.Query
  import Ash.Expr, only: [ref: 1]

  @default_max 50

  @typedoc "A record's versions, oldest first."
  @type history :: [Ash.Resource.record()]

  @doc """
  The versions of `seeds` (records of `resource`, each read at some
  instant), keyed by primary key, oldest first.

  ## Options

    * `:actor`, `:tenant`, `:authorize?` — passed to every read
      (`authorize?` defaults to `true`).
    * `:max_versions` — the most versions walked per record, per direction.
    * `:load` — loads for every version read.
  """
  @spec versions(Ash.Resource.t(), [Ash.Resource.record()], keyword) :: %{term => history}
  def versions(resource, seeds, opts \\ []) do
    period = Ash.Resource.Info.temporal_attribute(resource)
    max = Keyword.get(opts, :max_versions, @default_max)

    seeds
    |> Enum.uniq_by(&{key(&1), lower(&1, period)})
    |> Enum.group_by(&key/1)
    |> Map.new(fn {id, records} ->
      earliest = Enum.min_by(records, &lower(&1, period), DateTime)
      latest = Enum.max_by(records, &lower(&1, period), DateTime)

      before = walk(resource, id, earliest, period, :back, max, opts)
      later = walk(resource, id, latest, period, :forward, max, opts)

      versions =
        (before ++ records ++ later)
        |> Enum.uniq_by(&lower(&1, period))
        |> Enum.sort_by(&lower(&1, period), DateTime)

      {id, versions}
    end)
  end

  @doc "The instant a version starts (its period's lower bound)."
  @spec starts_at(Ash.Resource.record()) :: DateTime.t()
  def starts_at(%resource{} = record),
    do: lower(record, Ash.Resource.Info.temporal_attribute(resource))

  @doc "The instant a version ends (its period's upper bound), or `nil` if it is open."
  @spec ends_at(Ash.Resource.record()) :: DateTime.t() | nil
  def ends_at(%resource{} = record),
    do: upper(record, Ash.Resource.Info.temporal_attribute(resource))

  defp walk(_resource, _id, _from, _period, _direction, 0, _opts), do: []

  defp walk(resource, id, from, period, direction, remaining, opts) do
    with %DateTime{} = instant <- neighbour_instant(from, period, direction),
         %{} = version <- read_at(resource, id, instant, opts) do
      rest = walk(resource, id, version, period, direction, remaining - 1, opts)
      if direction == :back, do: rest ++ [version], else: [version | rest]
    else
      nil -> []
    end
  end

  # The version before starts a microsecond before this one does; the one
  # after starts where this one ends (half-open periods).
  defp neighbour_instant(record, period, :back),
    do: DateTime.add(lower(record, period), -1, :microsecond)

  defp neighbour_instant(record, period, :forward), do: upper(record, period)

  defp read_at(resource, id, instant, opts) do
    [key] = Ash.Resource.Info.primary_key(resource)

    resource
    |> Ash.Query.for_read(
      primary_read(resource),
      %{},
      actor: opts[:actor],
      tenant: opts[:tenant],
      authorize?: Keyword.get(opts, :authorize?, true),
      as_of: instant
    )
    |> Ash.Query.filter(^ref(key) == ^id)
    |> Ash.Query.load(Keyword.get(opts, :load, []))
    |> Ash.read_one!()
  end

  defp primary_read(resource), do: Ash.Resource.Info.primary_action!(resource, :read).name

  defp key(%resource{} = record) do
    [key] = Ash.Resource.Info.primary_key(resource)
    Map.fetch!(record, key)
  end

  defp lower(record, period), do: Map.fetch!(record, period).lower
  defp upper(record, period), do: Map.fetch!(record, period).upper
end
