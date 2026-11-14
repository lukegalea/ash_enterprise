defmodule AshEnterprise.Flags.Targeting do
  @moduledoc """
  Whether one tenant's flag row is on for one person (ADR 0072). Pure: it is handed
  the row and what `AshEnterprise.Security.ActorContext` already resolved about the
  person, and reads nothing else.

  | `state` | On for |
  |---|---|
  | `:off` | nobody |
  | `:on` | everyone in the tenant |
  | `:targeted` | a person named in `user_ids`, a member of a team in `team_ids`, anyone whose business unit is in the subtree of one in `business_unit_ids`, and the `percentage` of people whose bucket for the key falls below it |

  A person's bucket for a key is the first two bytes of `SHA-256(key <> ":" <> user_id)`
  modulo 100: stable for that person and key across requests, nodes and restarts, and
  independent between keys, so the same people are not always first. Raising the
  percentage only adds people; lowering it only removes them.

  A context with no person (a system actor, an empty context) is in no target.
  """

  @typedoc "What targeting needs to know about the person."
  @type person :: %{
          user_id: Ash.UUID.t() | nil,
          team_ids: [Ash.UUID.t()],
          unit_ids: MapSet.t(Ash.UUID.t())
        }

  @doc "Whether `flag` is on for `person`."
  @spec on?(map(), person()) :: boolean()
  def on?(%{state: :on}, _person), do: true
  def on?(%{state: :targeted}, %{user_id: nil}), do: false

  def on?(%{state: :targeted} = flag, person) do
    person.user_id in (flag.user_ids || []) or
      Enum.any?(flag.team_ids || [], &(&1 in person.team_ids)) or
      Enum.any?(flag.business_unit_ids || [], &MapSet.member?(person.unit_ids, &1)) or
      in_percentage?(flag, person.user_id)
  end

  def on?(_flag, _person), do: false

  @doc "Whether the flag's business-unit targets need the person's ancestor path."
  @spec needs_units?(map()) :: boolean()
  def needs_units?(%{state: :targeted, business_unit_ids: [_ | _]}), do: true
  def needs_units?(_flag), do: false

  @doc """
  The person's bucket, 0 to 99, for `key`. Stable for a person and a key; see the
  module doc.
  """
  @spec bucket(String.t(), Ash.UUID.t()) :: 0..99
  def bucket(key, user_id) do
    <<n::unsigned-16, _rest::binary>> = :crypto.hash(:sha256, key <> ":" <> to_string(user_id))
    rem(n, 100)
  end

  @doc """
  The business units whose subtree holds a unit at materialized `path`: the unit
  itself and every ancestor (`"/root-id/child-id/"`).
  """
  @spec units_on_path(String.t() | nil) :: MapSet.t(String.t())
  def units_on_path(nil), do: MapSet.new()
  def units_on_path(path), do: path |> String.split("/", trim: true) |> MapSet.new()

  defp in_percentage?(%{percentage: pct, key: key}, user_id)
       when is_integer(pct) and pct > 0 and not is_nil(user_id),
       do: bucket(key, user_id) < pct

  defp in_percentage?(_flag, _user_id), do: false
end
