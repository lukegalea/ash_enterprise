defmodule AshEnterprise.Surfaces.SavedStatus do
  @moduledoc """
  The two things a saved surface (a pinned app) says about itself, kept apart
  because they fail apart:

    * **validity** — does its stored definition still resolve against the
      resources, actions and fields as they are today, and is it still one the
      composer could have written (`AshEnterprise.Assistant.Composer.reload/2`).
      `:valid`, `:invalid` or `:unknown` (not checked yet).
    * **freshness** — how old the rows it shows are: when they were last read,
      as the viewer. `:fresh`, `:stale` or `:unknown`.

  A valid definition can show old rows, and an invalid one shows none, so one
  badge for both would claim one from the other. Neither state is ever
  inferred: anything that is not a resolved surface is not `:valid`, and a
  read time that is missing, malformed or ahead of the clock is `:unknown`,
  never `:fresh`.
  """

  @typedoc "Whether the saved definition still resolves."
  @type validity :: :valid | :invalid | :unknown

  @typedoc "How old the rows shown are."
  @type freshness :: :fresh | :stale | :unknown

  @fresh_seconds 300

  @doc "How long rows read as the viewer count as fresh, in seconds."
  @spec fresh_seconds() :: pos_integer()
  def fresh_seconds, do: @fresh_seconds

  @doc """
  The validity of a reload result (`Composer.reload/2`): `{:ok, surface}` is
  `:valid`; any `{:error, _}` is `:invalid`, reasons or not; anything else
  (no result yet, a crash's exit) is `:unknown`.
  """
  @spec validity(term()) :: validity()
  def validity({:ok, %AshA2ui.Dynamic.Surface{}}), do: :valid
  def validity({:error, _reasons}), do: :invalid
  def validity(_unknown), do: :unknown

  @doc """
  The freshness of rows read at `read_at`, judged at `now`: `:fresh` within
  `fresh_seconds/0`, `:stale` after. No read time (nothing was read: an
  invalid definition shows no rows), a read time that is not a `DateTime`, or
  one later than `now` is `:unknown`.
  """
  @spec freshness(DateTime.t() | term(), DateTime.t()) :: freshness()
  def freshness(%DateTime{} = read_at, %DateTime{} = now) do
    case DateTime.diff(now, read_at, :second) do
      age when age < 0 -> :unknown
      age when age <= @fresh_seconds -> :fresh
      _older -> :stale
    end
  end

  def freshness(_read_at, _now), do: :unknown
end
